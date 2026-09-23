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

# ---------------------------------------------------------------- tunnels
#
# Port forwards over a single SSH master connection per name.

tunnel_sock() { printf '%s/tunnels/%s.sock\n' "$OFFLOAD_STATE_DIR" "$1"; }

# tunnel_open <name> <machine> <port...>
tunnel_open() {
  local name="$1" m="$2" sock p args=""; shift 2
  [ $# -gt 0 ] || return 0
  sock=$(tunnel_sock "$name")
  mkdir -p "$(dirname "$sock")"
  tunnel_close "$name" "$m"
  for p in "$@"; do args="$args -L $p:localhost:$p"; done
  # shellcheck disable=SC2086
  ssh $OFFLOAD_SSH_OPTS -f -N -M -S "$sock" -o ExitOnForwardFailure=yes $args "$(ssh_dest "$m")"
}

tunnel_close() {
  local sock
  sock=$(tunnel_sock "$1")
  [ -S "$sock" ] || [ -e "$sock" ] || return 0
  # shellcheck disable=SC2086
  ssh $OFFLOAD_SSH_OPTS -S "$sock" -O exit "$(ssh_dest "$2")" >/dev/null 2>&1
  rm -f "$sock"
}
