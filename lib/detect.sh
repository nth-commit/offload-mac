# shellcheck shell=bash
# Working out which machine this is, where it is, and who does the work.

# ---------------------------------------------------------------- identity

# Which configured machine is this? Order: $OFFLOAD_THIS, the identity file
# written by `offload setup`, then a match on the macOS LocalHostName.
this_machine() {
  local id m lhn
  if [ -n "${OFFLOAD_THIS:-}" ]; then printf '%s\n' "$OFFLOAD_THIS"; return 0; fi
  if [ -r "$OFFLOAD_CONFIG_DIR/this" ]; then
    id=$(tr -d '[:space:]' < "$OFFLOAD_CONFIG_DIR/this")
    [ -n "$id" ] && { printf '%s\n' "$id"; return 0; }
  fi
  lhn=$(scutil --get LocalHostName 2>/dev/null)
  if [ -n "$lhn" ]; then
    for m in $(machines); do
      if [ "$(machine_lan_host "$m")" = "$lhn.local" ] || [ "$m" = "$lhn" ]; then
        printf '%s\n' "$m"; return 0
      fi
    done
  fi
  return 1
}

# ---------------------------------------------------------------- network fingerprint

probe_public_ip() {
  local ip
  ip=$(with_timeout 4 dig +short +time=2 +tries=1 myip.opendns.com A @resolver1.opendns.com 2>/dev/null | tail -n 1)
  case "$ip" in *.*.*.*) ;; *) ip=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null) ;; esac
  case "$ip" in
    *[!0-9.]*|'') return 1 ;;
    *.*.*.*) printf '%s\n' "$ip" ;;
    *) return 1 ;;
  esac
}

# MAC address of the default gateway (your router), lower-cased.
probe_router_mac() {
  local gw mac
  gw=$(route -n get default 2>/dev/null | awk '/gateway:/ { print $2; exit }')
  [ -n "$gw" ] || return 1
  mac=$(arp -n "$gw" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-fA-F:]+$/ && split($i, p, ":") == 6) { print tolower($i); exit } }')
  [ -n "$mac" ] || return 1
  printf '%s\n' "$mac"
}

# probe_port <host> <port>
probe_port() { nc -z -G 2 -w 2 "$1" "$2" >/dev/null 2>&1; }

# ---------------------------------------------------------------- mode
#
# The travelling machine's location sets the mode:
#   home  — both machines at home: the home machine is primary, the travel machine works.
#   away  — travel machine is out:  the travel machine is primary, the home machine works.
#   off   — manual override: everything runs locally.
#
# Sets globals: MODE, MODE_REASON, THIS, HOME_M, TRAVEL_M, PRIMARY, WORKER.

detect() {
  local override ip mac want_ip want_mac lan

  THIS=$(this_machine) || die "can't tell which machine this is — run 'offload setup' (or set OFFLOAD_THIS)"
  HOME_M=$(machine_by_role home) || die "no machine with role = \"home\" in $OFFLOAD_CONFIG"
  TRAVEL_M=$(machine_by_role travel) || die "no machine with role = \"travel\" in $OFFLOAD_CONFIG"
  case "$THIS" in "$HOME_M"|"$TRAVEL_M") ;; *) die "'$THIS' isn't a machine in $OFFLOAD_CONFIG" ;; esac

  override="${OFFLOAD_MODE:-}"
  [ -z "$override" ] && [ -r "$OFFLOAD_STATE_DIR/mode" ] && override=$(tr -d '[:space:]' < "$OFFLOAD_STATE_DIR/mode")

  case "$override" in
    home|away|off) MODE="$override"; MODE_REASON="set manually (offload mode auto to undo)" ;;
    *)
      if [ "$THIS" = "$HOME_M" ]; then
        # The home machine never moves; ask whether the travel machine is on the LAN.
        lan=$(machine_lan_host "$TRAVEL_M")
        if probe_port "$lan" 22; then
          MODE=home; MODE_REASON="$TRAVEL_M is on the local network"
        else
          MODE=away; MODE_REASON="$TRAVEL_M isn't on the local network"
        fi
      else
        want_ip=$(cfg home.public_ip)
        want_mac=$(cfg home.router_mac | tr '[:upper:]' '[:lower:]')
        [ -n "$want_ip$want_mac" ] || warn "no home fingerprint recorded — run 'offload setup' while at home"
        ip=$(probe_public_ip)
        if [ -n "$want_ip" ] && [ "$ip" = "$want_ip" ]; then
          MODE=home; MODE_REASON="public IP $ip is home"
        else
          mac=$(probe_router_mac)
          if [ -n "$want_mac" ] && [ "$mac" = "$want_mac" ]; then
            MODE=home; MODE_REASON="on the home router${ip:+ (public IP $ip — VPN?)}"
          elif [ -z "$ip" ] && [ -z "$mac" ]; then
            MODE=away; MODE_REASON="no network"
          else
            MODE=away; MODE_REASON="public IP ${ip:-unknown} isn't home"
          fi
        fi
      fi
      ;;
  esac

  case "$MODE" in
    home) PRIMARY="$HOME_M";   WORKER="$TRAVEL_M" ;;
    away) PRIMARY="$TRAVEL_M"; WORKER="$HOME_M" ;;
    off)  PRIMARY="$THIS";     WORKER="" ;;
  esac
}

# ---------------------------------------------------------------- placement

# workload_module <workload> — module name (defaults to the section name).
workload_module() { cfg "$1.module" "$1"; }

workloads() {
  local w
  for w in $(cfg offload.workloads); do
    [ "$(cfg "$w.enabled" true)" = false ] && continue
    printf '%s\n' "$w"
  done
}

# resolve_placement <workload> — prints the machine it *should* run on, or
# "local". Doesn't check reachability.
#   placement = "worker"     whichever machine is the worker (local if this is it)
#   placement = "local"      always here
#   placement = "<machine>"  always on that machine (local if that's this one)
resolve_placement() {
  local p
  [ "$MODE" = off ] && { echo local; return; }
  p=$(cfg "$1.placement" worker)
  case "$p" in
    local) echo local ;;
    worker)
      if [ "$THIS" = "$PRIMARY" ] && [ -n "$WORKER" ]; then echo "$WORKER"; else echo local; fi ;;
    *)
      if [ "$p" = "$THIS" ]; then echo local
      elif [ -n "$(cfg "machine.$p.role")" ]; then echo "$p"
      else warn "$1: unknown placement '$p', running locally"; echo local
      fi ;;
  esac
}
