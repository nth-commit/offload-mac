# shellcheck shell=bash
# Shared helpers for offload. Sourced by bin/offload and by every module.
#
# Written for the bash that ships with macOS (3.2): no associative arrays,
# no mapfile, no ${var,,}, no `set -u` with empty arrays.

OFFLOAD_CONFIG_DIR="${OFFLOAD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/offload}"
OFFLOAD_STATE_DIR="${OFFLOAD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/offload}"
OFFLOAD_CONFIG="${OFFLOAD_CONFIG:-$OFFLOAD_CONFIG_DIR/config.toml}"
OFFLOAD_ENV_FILE="$OFFLOAD_STATE_DIR/env.sh"

# ---------------------------------------------------------------- output

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_dim=$'\033[2m' _c_red=$'\033[31m' _c_grn=$'\033[32m' _c_yel=$'\033[33m' _c_bld=$'\033[1m' _c_off=$'\033[0m'
else
  _c_dim='' _c_red='' _c_grn='' _c_yel='' _c_bld='' _c_off=''
fi

OFFLOAD_QUIET="${OFFLOAD_QUIET:-}"

say()  { [ -n "$OFFLOAD_QUIET" ] || printf '%s\n' "$*" >&2; }
info() { [ -n "$OFFLOAD_QUIET" ] || printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
ok()   { [ -n "$OFFLOAD_QUIET" ] || printf '%s✓%s %s\n' "$_c_grn" "$_c_off" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# Ask a yes/no question. Default answer is $2 (y|n). Non-interactive → default.
confirm() {
  local prompt="$1" def="${2:-n}" ans hint="[y/N]"
  [ "$def" = y ] && hint="[Y/n]"
  if [ -n "${OFFLOAD_YES:-}" ]; then return 0; fi
  if [ ! -t 0 ]; then [ "$def" = y ]; return; fi
  printf '%s %s ' "$prompt" "$hint" >&2
  read -r ans
  [ -z "$ans" ] && ans="$def"
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- config
#
# A small TOML subset: [section] / [dotted.section], key = value, where value
# is a "string", 'string', bare word/number/bool, or a one-line array
# [ "a", "b", 3 ] (flattened to a space-separated string). Comments with #.
# Parsed once into OFFLOAD_CFG_FLAT as lines of `section.key=value`.

OFFLOAD_CFG_FLAT=""

cfg_load() {
  local file="${1:-$OFFLOAD_CONFIG}"
  [ -r "$file" ] || { OFFLOAD_CFG_FLAT=""; return 1; }
  OFFLOAD_CFG_FLAT=$(awk -v q="'" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function unquote(s,   c, i) {
      c = substr(s, 1, 1)
      if (c == "\"" || c == q) { s = substr(s, 2); i = index(s, c); if (i) s = substr(s, 1, i - 1); return s }
      sub(/[ \t]*#.*$/, "", s); return trim(s)
    }
    /^[ \t]*(#|$)/ { next }
    /^[ \t]*\[[^]]+\][ \t]*(#.*)?$/ { sec = $0; sub(/^[ \t]*\[/, "", sec); sub(/\].*$/, "", sec); sec = trim(sec); next }
    index($0, "=") {
      key = trim(substr($0, 1, index($0, "=") - 1))
      val = trim(substr($0, index($0, "=") + 1))
      if (substr(val, 1, 1) == "[") {
        sub(/^\[/, "", val); sub(/\][ \t]*(#.*)?$/, "", val)
        n = split(val, parts, ","); out = ""
        for (i = 1; i <= n; i++) { p = unquote(trim(parts[i])); if (p != "") out = out (out == "" ? "" : " ") p }
        val = out
      } else {
        val = unquote(val)
      }
      print (sec == "" ? "" : sec ".") key "=" val
    }
  ' "$file")
}

# cfg <dotted.key> [default]  — prints the value, or the default if unset/empty.
cfg() {
  local v
  v=$(printf '%s\n' "$OFFLOAD_CFG_FLAT" | awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }')
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "${2:-}"; fi
}

# cfg_set <file> <section> <key> <value> — set (or add) a string value in a TOML file.
cfg_set() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/offload.XXXXXX") || return 1
  awk -v sec="$section" -v key="$key" -v val="$value" '
    function emit() { print key " = \"" val "\""; done = 1 }
    /^[ \t]*\[[^]]+\]/ {
      s = $0; sub(/^[ \t]*\[/, "", s); sub(/\].*$/, "", s); gsub(/[ \t]/, "", s)
      if (insec && !done) emit()
      insec = (s == sec); if (insec) seen = 1
      print; next
    }
    insec && !done {
      k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
      if (k == key && index($0, "=")) { emit(); next }
    }
    { print }
    END {
      if (insec && !done) emit()
      else if (!seen) { print ""; print "[" sec "]"; emit() }
    }
  ' "$file" > "$tmp" && cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Machines ----------------------------------------------------------------

# All machine names declared as [machine.<name>].
machines() {
  printf '%s\n' "$OFFLOAD_CFG_FLAT" | awk -F= '/^machine\.[^.]+\./ { split($1, p, "."); if (!seen[p[2]]++) print p[2] }'
}

# machine_by_role home|travel
machine_by_role() {
  local m
  for m in $(machines); do
    [ "$(cfg "machine.$m.role")" = "$1" ] && { printf '%s\n' "$m"; return 0; }
  done
  return 1
}

# The SSH/Tailscale hostname for a machine (defaults to its name).
machine_host() { cfg "machine.$1.host" "$1"; }
machine_lan_host() { cfg "machine.$1.lan_host" "$1.local"; }

ssh_dest() {
  local user
  user=$(cfg offload.ssh_user "${USER:-}")
  if [ -n "$user" ]; then printf '%s@%s\n' "$user" "$(machine_host "$1")"; else machine_host "$1"; fi
}

# ---------------------------------------------------------------- process helpers

# with_timeout <seconds> <cmd...>  (macOS has no coreutils `timeout`)
with_timeout() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

OFFLOAD_SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=4 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"

# For sessions you sit in front of. BatchMode is off, so a first connection can
# still prompt for a password or a key passphrase.
OFFLOAD_SSH_INTERACTIVE_OPTS="-o ConnectTimeout=4 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

# ssh_to <machine> <cmd...>
ssh_to() {
  local m="$1"; shift
  # shellcheck disable=SC2086
  ssh $OFFLOAD_SSH_OPTS "$(ssh_dest "$m")" "$@"
}

# shellcheck disable=SC2086
ssh_ok() { with_timeout 8 ssh $OFFLOAD_SSH_OPTS "$(ssh_dest "$1")" true >/dev/null 2>&1; }

# Wait up to N seconds for a command to succeed.
wait_for() {
  local secs="$1" i=0; shift
  while [ "$i" -lt "$secs" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# Quote a value for safe use in a POSIX shell file.
shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---------------------------------------------------------------- docker's SSH master
#
# Docker reaches a remote engine with `ssh <host> docker system dial-stdio`, one
# SSH session per connection, and some commands open several at once. When the
# host has a ControlMaster in ~/.ssh/config, those sessions share the user's own
# master, and sshd refuses the 11th session on one connection (MaxSessions 10)
# with "Session open refused by peer". offload writes a host alias per machine
# with its own ControlPath, so docker gets a master of its own. ~/.ssh/config
# has to Include the file; `offload setup` adds that line.

OFFLOAD_SSH_CONFIG="$OFFLOAD_STATE_DIR/ssh_config"

docker_ssh_alias() { printf 'offload-docker-%s\n' "$1"; }

ssh_include_present() {
  grep -qiE '^[[:space:]]*Include[[:space:]].*offload/ssh_config' "$HOME/.ssh/config" 2>/dev/null
}

# Adds the Include at the top of ~/.ssh/config: an Include after a Host line
# would only apply inside that Host block.
ssh_include_add() {
  local f="$HOME/.ssh/config" tmp
  ssh_include_present && return 0
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  tmp=$(mktemp "${TMPDIR:-/tmp}/offload.XXXXXX") || return 1
  {
    echo "# offload: docker's own SSH master to each machine (offload-docker-<machine>)"
    echo "Include \"$OFFLOAD_SSH_CONFIG\""
    echo ""
    cat "$f" 2>/dev/null
  } > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
  chmod 600 "$f"
}

# Writes the alias file. Leaves it untouched when nothing changed.
ssh_config_write() {
  local m user tmp
  user=$(cfg offload.ssh_user "${USER:-}")
  mkdir -p "$OFFLOAD_STATE_DIR"
  tmp="$OFFLOAD_SSH_CONFIG.tmp"
  {
    echo "# Generated by offload — don't edit. Included from ~/.ssh/config."
    echo "# Docker's SSH sessions to each machine get their own master, apart from"
    echo "# any ControlMaster you use for interactive ssh."
    for m in $(machines); do
      echo ""
      echo "Host $(docker_ssh_alias "$m")"
      echo "  HostName $(machine_host "$m")"
      [ -n "$user" ] && echo "  User $user"
      echo "  ControlMaster auto"
      echo "  ControlPath ~/.ssh/cm-offload-docker-%C"
      echo "  ControlPersist 10m"
      echo "  ServerAliveInterval 15"
      echo "  ServerAliveCountMax 2"
    done
  } > "$tmp" || return 1
  if cmp -s "$tmp" "$OFFLOAD_SSH_CONFIG"; then rm -f "$tmp"; else mv "$tmp" "$OFFLOAD_SSH_CONFIG"; fi
}

# docker_ssh_dest <machine> [own_master]: the user@host docker contexts use.
# The alias only when own_master (default: [docker] own_ssh_master) is true
# and ~/.ssh/config includes the alias file; otherwise the plain host.
docker_ssh_dest() {
  local m="$1" own="${2:-$(cfg docker.own_ssh_master true)}" user
  if [ "$own" = true ] && ssh_include_present; then
    user=$(cfg offload.ssh_user "${USER:-}")
    if [ -n "$user" ]; then printf '%s@%s\n' "$user" "$(docker_ssh_alias "$m")"; else docker_ssh_alias "$m"; fi
  else
    ssh_dest "$m"
  fi
}

# ---------------------------------------------------------------- tunnels
#
# Port forwards over a single SSH master connection per name. Next to the
# control socket, <name>.spec records the destination and ports the master was
# opened with, and <name>.pid its process ID.

tunnel_sock() { printf '%s/tunnels/%s.sock\n' "$OFFLOAD_STATE_DIR" "$1"; }

# _tunnel_pid <sock> <dest> — prints the master's PID if it answers on <sock>.
_tunnel_pid() {
  local out
  [ -e "$1" ] || return 1
  # shellcheck disable=SC2086
  out=$(with_timeout 5 ssh $OFFLOAD_SSH_OPTS -S "$1" -O check "$2" 2>&1) || return 1
  printf '%s\n' "$out" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
}

# tunnel_open <name> <machine> <port...>
# Reuses a live master with the same destination and ports; otherwise closes it
# and opens a new one.
tunnel_open() {
  local name="$1" m="$2" sock dest spec pid p args=""; shift 2
  [ $# -gt 0 ] || return 0
  sock=$(tunnel_sock "$name")
  dest=$(ssh_dest "$m")
  spec="$dest $*"
  mkdir -p "$(dirname "$sock")"
  if [ "$(cat "${sock%.sock}.spec" 2>/dev/null)" = "$spec" ] && _tunnel_pid "$sock" "$dest" >/dev/null; then
    return 0
  fi
  tunnel_close "$name" "$m"
  for p in "$@"; do args="$args -L $p:localhost:$p"; done
  # shellcheck disable=SC2086
  ssh $OFFLOAD_SSH_OPTS -f -N -M -S "$sock" -o ExitOnForwardFailure=yes $args "$dest" || return 1
  printf '%s\n' "$spec" > "${sock%.sock}.spec"
  pid=$(_tunnel_pid "$sock" "$dest") && [ -n "$pid" ] && printf '%s\n' "$pid" > "${sock%.sock}.pid"
  return 0
}

# tunnel_close <name> <machine> — stops the master and waits for it to exit, so
# its forwarded ports are free when this returns.
tunnel_close() {
  local sock base dest pid i=0
  sock=$(tunnel_sock "$1"); base="${sock%.sock}"
  dest=$(ssh_dest "$2")
  pid=$(_tunnel_pid "$sock" "$dest") || pid=""
  # No answer on the socket: fall back to the recorded PID, if it's still our master.
  if [ -z "$pid" ] && [ -r "$base.pid" ]; then
    pid=$(cat "$base.pid")
    ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "$sock" || pid=""
  fi
  if [ -e "$sock" ]; then
    # shellcheck disable=SC2086
    ssh $OFFLOAD_SSH_OPTS -S "$sock" -O exit "$dest" >/dev/null 2>&1
  fi
  if [ -n "$pid" ]; then
    # `-O exit` returns before the master has released its listeners.
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
  fi
  rm -f "$sock" "$base.spec" "$base.pid"
}
