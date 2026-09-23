# shellcheck shell=bash
# One-time setup, diagnostics, config sync and launchd autostart.

OFFLOAD_LAUNCHD_LABEL="dev.offload.apply"
OFFLOAD_PLIST="$HOME/Library/LaunchAgents/$OFFLOAD_LAUNCHD_LABEL.plist"
ZSHENV_MARKER="# offload: Homebrew + Docker on PATH for non-interactive SSH"

other_machine() {
  local m
  for m in $(machines); do [ "$m" != "$1" ] && { echo "$m"; return 0; }; done
  return 1
}

step() { say ""; say "${_c_bld}$*${_c_off}"; }

cmd_setup() {
  local m choice i peer names ip mac at_home want have

  # 1. Identity -------------------------------------------------------------
  step "1. Which machine is this?"
  names=$(machines | tr '\n' ' ')
  [ -n "$names" ] || die "no [machine.*] sections in $OFFLOAD_CONFIG"
  m=$(this_machine 2>/dev/null)
  if [ -n "$m" ] && confirm "  This is '$m'?" y; then :; else
    i=1; for choice in $names; do say "  $i) $choice ($(cfg "machine.$choice.role"))"; i=$((i + 1)); done
    printf '  Number: ' >&2; read -r i
    m=$(echo "$names" | awk -v n="$i" '{ print $n }')
    [ -n "$m" ] || die "no such machine"
  fi
  mkdir -p "$OFFLOAD_CONFIG_DIR"; echo "$m" > "$OFFLOAD_CONFIG_DIR/this"
  ok "this is $m ($(cfg "machine.$m.role"))"
  peer=$(other_machine "$m")

  # 2. PATH for SSH sessions -----------------------------------------------
  step "2. Make docker & co. visible to SSH sessions from $peer"
  if grep -qF "$ZSHENV_MARKER" "$HOME/.zshenv" 2>/dev/null; then
    ok "~/.zshenv already set up"
  else
    {
      echo ""; echo "$ZSHENV_MARKER"
      # shellcheck disable=SC2016
      echo 'export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin"'
    } >> "$HOME/.zshenv"
    ok "added Homebrew/Docker paths to ~/.zshenv"
  fi

  # 3. Remote Login ------------------------------------------------------------
  step "3. Remote Login (SSH server)"
  if probe_port localhost 22; then ok "Remote Login is on"
  else
    warn "Remote Login is off. Turn it on in System Settings → General → Sharing → Remote Login."
    open "x-apple.systempreferences:com.apple.Sharing-Settings.extension" 2>/dev/null
    confirm "  Done?" y
  fi

  # 4. SSH key + reachability ----------------------------------------------
  step "4. SSH to $peer ($(ssh_dest "$peer"))"
  if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "offload@$m" >/dev/null && ok "created ~/.ssh/id_ed25519"
  fi
  if ssh_ok "$peer"; then ok "passwordless SSH to $peer works"
  elif [ -t 0 ] && confirm "  Copy your SSH key to $peer now (asks for its password)?" y; then
    ssh-copy-id "$(ssh_dest "$peer")" && ssh_ok "$peer" && ok "passwordless SSH to $peer works"
  else
    warn "can't SSH to $peer yet. Is Tailscale up on both, and Remote Login on $peer? Re-run setup after."
  fi

  # 5. Home fingerprint --------------------------------------------------------
  step "5. Home network fingerprint"
  at_home=""
  if [ "$(cfg "machine.$m.role")" = home ]; then at_home=1
  elif confirm "  Are you at home right now?" n; then at_home=1; fi
  if [ -n "$at_home" ]; then
    ip=$(probe_public_ip); mac=$(probe_router_mac)
    [ -n "$ip" ] && cfg_set "$OFFLOAD_CONFIG" home public_ip "$ip" && ok "home public IP: $ip"
    [ -n "$mac" ] && cfg_set "$OFFLOAD_CONFIG" home router_mac "$mac" && ok "home router MAC: $mac"
    [ -n "$ip$mac" ] || warn "couldn't detect the network — are you online?"
    cfg_load
    info "  run 'offload sync-config' to copy this to $peer"
  else
    info "  skipped — run setup again (or on $(machine_by_role home)) while at home"
  fi

  # 6. Docker context --------------------------------------------------------
  step "6. Docker"
  if command -v docker >/dev/null 2>&1; then
    want="ssh://$(ssh_dest "$peer")"
    have=$(docker context inspect "offload-$peer" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    if [ -z "$have" ]; then
      docker context create "offload-$peer" --description "offload → $peer" \
        --docker "host=$want" >/dev/null && ok "created context offload-$peer"
    elif [ "$have" != "$want" ]; then
      docker context update "offload-$peer" --description "offload → $peer" \
        --docker "host=$want" >/dev/null && ok "context offload-$peer repointed at $want"
    else
      ok "context offload-$peer exists"
    fi
    info "  In Docker Desktop, turn on Settings → General → 'Start Docker Desktop when you sign in'."
  else
    warn "docker CLI not found — install Docker Desktop (install.sh can do it)"
  fi

  # 7. Sleep ---------------------------------------------------------------------
  step "7. Sleep"
  if [ "$(cfg "machine.$m.role")" = home ]; then
    say "  The home machine should never sleep, should wake for network access and"
    say "  restart after a power cut. This runs: sudo pmset -a sleep 0 womp 1 autorestart 1"
    if confirm "  Apply?" y; then sudo pmset -a sleep 0 womp 1 autorestart 1 && ok "sleep settings applied"; fi
    info "  Also enable automatic login (System Settings → Users & Groups) so Docker Desktop"
    info "  and your LLM server come back after a reboot. (Not available with FileVault on.)"
  else
    info "  offload keeps $m awake with caffeinate while it's the worker (on AC power)."
    info "  With the lid closed and no display, macOS may still sleep; if you run it that"
    info "  way, 'sudo pmset -a disablesleep 1' prevents it (undo with 0)."
  fi

  # 8. Autostart -------------------------------------------------------------------
  step "8. Autostart"
  if [ -f "$OFFLOAD_PLIST" ]; then ok "autostart is on"
  elif confirm "  Re-run offload automatically at login and when the network changes?" y; then
    cmd_autostart on
  fi

  step "Done. Applying…"
  cmd_apply
}

cmd_doctor() {
  local m peer bad=0 v
  _chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else warn "$1 — ${3:-failed}"; bad=$((bad + 1)); fi; }

  m=$(this_machine 2>/dev/null) || { warn "don't know which machine this is — run 'offload setup'"; return 1; }
  peer=$(other_machine "$m")
  say "${_c_bld}$m${_c_off} (peer: $peer)"
  _chk "config parses, two machines" '[ "$(machines | wc -l | tr -d " ")" = 2 ]' "need exactly one home and one travel machine"
  _chk "home fingerprint recorded" '[ -n "$(cfg home.public_ip)$(cfg home.router_mac)" ]' "run 'offload setup' while at home"
  _chk "Remote Login on" 'probe_port localhost 22' "System Settings → General → Sharing"
  _chk "tailscale installed" 'command -v tailscale || [ -d /Applications/Tailscale.app ]' "install Tailscale (install.sh can do it)"
  _chk "docker CLI" 'command -v docker' "install Docker Desktop"
  _chk "local Docker engine" 'with_timeout 10 docker version --format x' "Docker Desktop not running here (fine if you always offload)"
  _chk "SSH to $peer" "ssh_ok $peer" "check Tailscale and Remote Login on $peer"
  if ssh_ok "$peer"; then
    v=$(ssh_to "$peer" 'command -v docker' 2>/dev/null)
    _chk "docker on PATH over SSH on $peer" '[ -n "$v" ]' "run 'offload setup' on $peer (fixes ~/.zshenv)"
    _chk "Docker engine on $peer" "with_timeout 15 docker --context offload-$peer version --format x" "is Docker Desktop running on $peer?"
  fi
  _chk "autostart" '[ -f "$OFFLOAD_PLIST" ]' "offload autostart on"
  if [ "$bad" -eq 0 ]; then ok "all good"; else say "$bad issue(s)"; fi
}

cmd_sync_config() {
  local m peer
  m=$(this_machine) || die "run 'offload setup' first"
  peer=$(other_machine "$m")
  ssh_to "$peer" 'mkdir -p ~/.config/offload' || die "can't reach $peer"
  # shellcheck disable=SC2086
  scp -q $OFFLOAD_SSH_OPTS "$OFFLOAD_CONFIG" "$(ssh_dest "$peer"):.config/offload/config.toml" \
    && ok "copied config to $peer"
}

cmd_autostart() {
  local uid; uid=$(id -u)
  case "${1:-}" in
    on)
      mkdir -p "$(dirname "$OFFLOAD_PLIST")" "$OFFLOAD_STATE_DIR"
      cat > "$OFFLOAD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$OFFLOAD_LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$OFFLOAD_ROOT/bin/offload</string><string>apply</string><string>--quiet</string></array>
  <key>RunAtLoad</key><true/>
  <key>WatchPaths</key><array><string>/Library/Preferences/SystemConfiguration</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin</string></dict>
  <key>StandardOutPath</key><string>$OFFLOAD_STATE_DIR/autostart.log</string>
  <key>StandardErrorPath</key><string>$OFFLOAD_STATE_DIR/autostart.log</string>
</dict>
</plist>
EOF
      launchctl bootout "gui/$uid/$OFFLOAD_LAUNCHD_LABEL" 2>/dev/null
      launchctl bootstrap "gui/$uid" "$OFFLOAD_PLIST" && ok "autostart on (log: $OFFLOAD_STATE_DIR/autostart.log)"
      ;;
    off)
      launchctl bootout "gui/$uid/$OFFLOAD_LAUNCHD_LABEL" 2>/dev/null
      rm -f "$OFFLOAD_PLIST"; ok "autostart off"
      ;;
    *) if [ -f "$OFFLOAD_PLIST" ]; then echo on; else echo off; fi ;;
  esac
}
