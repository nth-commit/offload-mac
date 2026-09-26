#!/bin/bash
# Scenario tests for offload. Stubs every macOS/network command, so it runs
# anywhere (CI runs it on macOS with the system bash 3.2).
#
#   tests/run.sh

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/offload-test.XXXXXX")
# Physical, normalised path: install.sh resolves its own ROOT with `cd -P`, so a
# /var/folders (symlink to /private/var) or double-slashed $TMPDIR would never match.
T=$(cd -P "$T" && pwd)
trap 'pkill -f "$T/stubs/caffeinate" 2>/dev/null; rm -rf "$T"' EXIT
STUBS="$T/stubs"; mkdir -p "$STUBS"
PASS=0 FAIL=0

# ---------------------------------------------------------------- stubs
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }

stub dig        'echo "$STUB_IP"'
stub curl       'url="${!#}"
case "$url" in
  *ipify*) [ -n "$STUB_IP" ] && echo "$STUB_IP" || exit 7 ;;
  *) h="${url#http://}"; h="${h%%:*}"; case " $STUB_LLM_UP " in *" $h "*) exit 0 ;; *) exit 7 ;; esac ;;
esac'
stub route      '[ -n "$STUB_MAC" ] && printf "   route to: default\n    gateway: 192.168.1.1\n"'
stub arp        'echo "? ($2) at $STUB_MAC on en0 ifscope [ethernet]"'
stub nc         '[ -n "$STUB_LAN_UP" ]'
stub scutil     'exit 1'
# `ps -o comm=` reports /bin/bash for a script, so offload can't recognise the
# caffeinate stub as its own process. Report the real binary's name for it.
stub ps         'pid=""; prev=""
for a in "$@"; do [ "$prev" = -p ] && pid="$a"; prev="$a"; done
case "$*" in
  *comm=*) if [ -n "$pid" ] && /bin/ps -p "$pid" -o command= 2>/dev/null | grep -q "/stubs/caffeinate"; then
             echo /usr/bin/caffeinate; exit 0
           fi ;;
esac
exec /bin/ps "$@"'
stub launchctl  'echo "launchctl $*" >> "$STUB_LOG"'
stub osascript  'echo "osascript $*" >> "$STUB_LOG"'
stub open       'echo "open $*" >> "$STUB_LOG"'
stub caffeinate 'trap "kill \$c 2>/dev/null; exit 0" TERM; sleep 300 & c=$!; wait'
stub scp        'echo "scp $*" >> "$STUB_LOG"'
stub ssh        'echo "ssh $*" >> "$STUB_LOG"
sock=""; prev=""; master=""
for a in "$@"; do
  [ "$prev" = -S ] && sock="$a"; [ "$a" = -M ] && master=1; prev="$a"
done
if [ -n "$master" ] && [ -n "$sock" ]; then : > "$sock"; exit 0; fi
case "$*" in *"-O exit"*) exit 0 ;; esac
for h in $STUB_SSH_OK; do case "$*" in *"@$h "*|*"@$h") exit 0 ;; esac; done
exit 255'
stub docker     'echo "docker $*" >> "$STUB_LOG"
ctxdir="$STUB_STATE/ctx"; mkdir -p "$ctxdir"; [ -e "$ctxdir/desktop-linux" ] || : > "$ctxdir/desktop-linux"
ctx=desktop-linux; [ "$1" = --context ] && { ctx="$2"; shift 2; }
case "$1 $2" in
  "context inspect") [ -e "$ctxdir/$3" ] ;;
  "context create")  : > "$ctxdir/$3" ;;
  "context use")     echo "$3" > "$STUB_STATE/current-ctx" ;;
  version*) m="${ctx#offload-}"; [ "$ctx" = desktop-linux ] && m=local
            case " $STUB_DOCKER_UP " in *" $m "*) echo 27.0 ;; *) exit 1 ;; esac ;;
esac'

# ---------------------------------------------------------------- harness
reset() {
  rm -rf "${T:?}/home"; mkdir -p "$T/home/.config/offload"
  export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state"
  unset OFFLOAD_CONFIG_DIR OFFLOAD_STATE_DIR OFFLOAD_CONFIG OFFLOAD_MODE
  export STUB_LOG="$T/log" STUB_STATE="$T/stubstate" USER=michael NO_COLOR=1
  rm -rf "$STUB_STATE"; mkdir -p "$STUB_STATE"; : > "$STUB_LOG"
  sed -e 's/^public_ip *=.*/public_ip = "203.0.113.7"/' -e 's/^router_mac *=.*/router_mac = "a4:2b:b0:1:2:3"/' \
    "$ROOT/config.example.toml" > "$HOME/.config/offload/config.toml"
  export STUB_IP="" STUB_MAC="" STUB_LAN_UP="" STUB_SSH_OK="mini macbook" STUB_DOCKER_UP="local mini macbook" STUB_LLM_UP="localhost mini"
  export OFFLOAD_THIS=""
}

run() { PATH="$STUBS:$PATH" "$ROOT/bin/offload" "$@" 2>"$T/stderr"; }

check() { # check <description> <condition...>
  local d="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$d"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$d"; sed 's/^/         | /' "$T/stderr" 2>/dev/null | head -20; fi
}
has()     { grep -qF -- "$2" "$1"; }
hasnt()   { ! grep -qF -- "$2" "$1"; }
resolved(){ run resolve > "$T/out"; }
envfile() { printf '%s\n' "$XDG_STATE_HOME/offload/env.sh"; }
ctx_now() { cat "$STUB_STATE/current-ctx" 2>/dev/null; }
caff_running() { pgrep -f "$STUBS/caffeinate" >/dev/null; }
caff_stopped() { wait_gone 20; }
wait_gone() { local i=0; while [ "$i" -lt "$1" ]; do caff_running || return 0; sleep 0.1; i=$((i + 1)); done; return 1; }

# ---------------------------------------------------------------- config parser
echo "config parser"
reset
cat > "$T/c.toml" <<'EOF'
# comment
top = 1
[a]
s = "hello # not a comment"   # trailing
b = true
n = 42    # num
arr = [ "x", 'y', 3 ]
empty = []
[machine.box]
host = 'box.tail'
EOF
(
  . "$ROOT/lib/common.sh"; cfg_load "$T/c.toml"
  [ "$(cfg top)" = 1 ] && [ "$(cfg a.s)" = "hello # not a comment" ] && [ "$(cfg a.b)" = true ] \
    && [ "$(cfg a.n)" = 42 ] && [ "$(cfg a.arr)" = "x y 3" ] && [ "$(cfg a.empty dflt)" = dflt ] \
    && [ "$(cfg machine.box.host)" = box.tail ] && [ "$(cfg a.missing zz)" = zz ]
) ; check "parses strings, comments, bools, arrays, dotted sections" [ $? -eq 0 ]
(
  . "$ROOT/lib/common.sh"
  cfg_set "$T/c.toml" a n 7 && cfg_set "$T/c.toml" home public_ip 1.2.3.4 && cfg_load "$T/c.toml"
  [ "$(cfg a.n)" = 7 ] && [ "$(cfg home.public_ip)" = 1.2.3.4 ] && [ "$(cfg a.s)" = "hello # not a comment" ]
) ; check "cfg_set replaces and appends" [ $? -eq 0 ]

# ---------------------------------------------------------------- mini
echo "on the mini"
reset; export OFFLOAD_THIS=mini STUB_LAN_UP=1
resolved
check "macbook on LAN → home mode" has "$T/out" "mode home"
check "docker → macbook" has "$T/out" "docker macbook"
check "llm pinned to mini → local" has "$T/out" "llm local"
run apply
check "docker context switched to offload-macbook" [ "$(ctx_now)" = offload-macbook ]
check "OLLAMA_HOST points at localhost" has "$(envfile)" "export OLLAMA_HOST='http://localhost:11434'"
check "OPENAI_BASE_URL set" has "$(envfile)" "export OPENAI_BASE_URL='http://localhost:11434/v1'"
check "mini (primary) not caffeinated" caff_stopped

reset; export OFFLOAD_THIS=mini STUB_LAN_UP=""
resolved
check "macbook not on LAN → away mode" has "$T/out" "mode away"
check "mini is the worker, docker local" has "$T/out" "docker local"
run apply
check "docker context → desktop-linux" [ "$(ctx_now)" = desktop-linux ]
check "mini (worker) is caffeinated" caff_running
pkill -f "$STUBS/caffeinate"

# ---------------------------------------------------------------- macbook
echo "on the macbook"
reset; export OFFLOAD_THIS=macbook STUB_IP=203.0.113.7
resolved
check "home IP → home mode" has "$T/out" "mode home"
check "macbook is worker, docker local" has "$T/out" "docker local"
check "llm → mini" has "$T/out" "llm mini"
run apply
check "OLLAMA_HOST → mini" has "$(envfile)" "export OLLAMA_HOST='http://mini:11434'"
check "macbook (worker) caffeinated" caff_running

STUB_IP=198.51.100.9 run apply
check "different IP → away" has "$T/stderr" "away"
check "docker → offload-mini" [ "$(ctx_now)" = offload-mini ]
check "context offload-mini created over ssh" has "$STUB_LOG" "host=ssh://michael@mini"
check "caffeinate stopped when primary" caff_stopped

reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9 STUB_MAC="a4:2b:b0:1:2:3"
resolved
check "VPN IP but home router MAC → home" has "$T/out" "mode home"

reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9 STUB_SSH_OK=""
run apply
check "mini unreachable: docker falls back to local" [ "$(ctx_now)" = desktop-linux ]
check "mini unreachable: llm vars unset (fallback none)" has "$(envfile)" "unset OLLAMA_HOST"
check "status line says unreachable" has "$T/stderr" "mini unreachable"

# ---------------------------------------------------------------- ports + switching
echo "tunnels and switching"
reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9
sed -i.bak 's/^ports *=.*/ports = [3000, 5173]/' "$HOME/.config/offload/config.toml"
run apply
check "ports forwarded over ssh" has "$STUB_LOG" "-L 3000:localhost:3000 -L 5173:localhost:5173"
check "tunnel socket exists" [ -e "$XDG_STATE_HOME/offload/tunnels/docker.sock" ]
STUB_IP=203.0.113.7 run apply
check "coming home closes the tunnel" has "$STUB_LOG" "-O exit"
check "tunnel socket removed" [ ! -e "$XDG_STATE_HOME/offload/tunnels/docker.sock" ]
pkill -f "$STUBS/caffeinate"

# ---------------------------------------------------------------- overrides
echo "overrides"
reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9
run mode off >/dev/null
resolved
check "mode off → everything local" sh -c "grep -q 'docker local' '$T/out' && grep -q 'llm local' '$T/out'"
run mode auto >/dev/null
resolved
check "mode auto → back to away" has "$T/out" "mode away"

reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9 STUB_DOCKER_UP="local"
perl -pi -e 's/^(stop_local *=.*)$/$1\nstart_timeout = 1/' "$HOME/.config/offload/config.toml"
run apply
check "remote engine down → tries to start Docker over ssh" has "$STUB_LOG" "open -g -a Docker"

# ---------------------------------------------------------------- llm-small (second instance)
echo "module reuse"
reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9
cfgf="$HOME/.config/offload/config.toml"
sed -i.bak 's/^workloads *=.*/workloads = ["docker", "llm", "llm-small"]/' "$cfgf"
printf '\n[llm-small]\nmodule = "llm"\nplacement = "local"\nport = 1234\nenv = ["SMALL_LLM_URL=http://{host}:{port}/v1"]\n' >> "$cfgf"
run apply
check "second llm instance on its own port" has "$(envfile)" "export SMALL_LLM_URL='http://localhost:1234/v1'"
pkill -f "$STUBS/caffeinate" 2>/dev/null

# ---------------------------------------------------------------- ssh
echo "ssh"
reset; export OFFLOAD_THIS=macbook STUB_IP=203.0.113.7   # home: mini is primary
run ssh
check "bare 'ssh' targets the other machine" has "$STUB_LOG" "michael@mini"
check "interactive opts, no BatchMode" hasnt "$STUB_LOG" "BatchMode=yes -o ConnectTimeout=4 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

reset; export OFFLOAD_THIS=macbook STUB_IP=203.0.113.7
run ssh primary uptime
check "'ssh primary' at home → mini" has "$STUB_LOG" "michael@mini uptime"

reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9  # away: macbook is primary
run ssh worker df -h
check "'ssh worker' away → mini" has "$STUB_LOG" "michael@mini df -h"
check "flags after the target reach the remote command" has "$STUB_LOG" " -h"

reset; export OFFLOAD_THIS=macbook STUB_IP=198.51.100.9
run ssh primary -- true
check "target is this machine → runs locally, no ssh" hasnt "$STUB_LOG" "ssh "
check "local fallback says so" has "$T/stderr" "(here)"

reset; export OFFLOAD_THIS=macbook STUB_IP=203.0.113.7
run ssh nosuchmac
check "unknown target is an error" [ $? -ne 0 ]
check "error names the valid targets" has "$T/stderr" "primary, worker"

# ---------------------------------------------------------------- config path
echo "config path"
reset
run config > "$T/out"
check "prints the config path on stdout" has "$T/out" "$HOME/.config/offload/config.toml"
check "nothing else on stdout" [ "$(wc -l < "$T/out")" -eq 1 ]

reset; rm -f "$HOME/.config/offload/config.toml"
run config > "$T/out"
check "still prints the path when there is no config" has "$T/out" "$HOME/.config/offload/config.toml"
check "missing config warns on stderr" has "$T/stderr" "no config at"

# ---------------------------------------------------------------- curl install
echo "curl install"
reset
tarball="$T/offload-main.tar.gz"
# GitHub tarballs have a single top-level "<repo>-<ref>/" directory.
mkdir -p "$T/src" && cp -R "$ROOT" "$T/src/offload-main" && rm -rf "$T/src/offload-main/.git"
( cd "$T/src" && tar -czf "$tarball" offload-main )
mkdir -p "$T/istubs"
cat > "$T/istubs/curl" <<STUB
#!/bin/bash
out=""; url=""; prev=""
for a in "\$@"; do [ "\$prev" = -o ] && out="\$a"; case "\$a" in http*) url="\$a" ;; esac; prev="\$a"; done
echo "curl \$url" >> "$STUB_LOG"
case "\$url" in
  */archive/refs/heads/main.tar.gz) src="$tarball" ;;
  */main/install.sh) src="$ROOT/install.sh" ;;
  *) exit 22 ;;
esac
if [ -n "\$out" ]; then cat "\$src" > "\$out"; else cat "\$src"; fi
STUB
printf '#!/bin/bash\necho Darwin\n' > "$T/istubs/uname"
printf '#!/bin/bash\nexit 0\n' > "$T/istubs/brew"
cp "$T/istubs/brew" "$T/istubs/tailscale"; cp "$T/istubs/brew" "$T/istubs/docker"
chmod +x "$T/istubs/"*
ipath="$T/istubs:$PATH"
( cd "$T" && PATH="$ipath" OFFLOAD_REPO=me/offload /bin/bash -c "$(cat "$ROOT/install.sh")" </dev/null >"$T/stderr" 2>&1 )
inst="$HOME/.local/share/offload"
check "curl install downloads the repo" [ -r "$inst/lib/common.sh" ]
check "records where it came from" has "$inst/.source" "me/offload main"
check "links offload onto PATH" [ "$(readlink "$HOME/.local/bin/offload")" = "$inst/bin/offload" ]
check "hooks .zshrc" has "$HOME/.zshrc" "$inst/shell/offload.zsh"
check "writes a config" [ -r "$HOME/.config/offload/config.toml" ]
echo stale > "$inst/STALE"
PATH="$ipath" "$HOME/.local/bin/offload" update </dev/null >"$T/stderr" 2>&1
check "offload update re-downloads from the recorded repo" has "$STUB_LOG" "raw.githubusercontent.com/me/offload/main/install.sh"
check "update replaces the old snapshot" [ ! -e "$inst/STALE" ]
check "update leaves a working install" [ -x "$inst/bin/offload" ]
check "zshrc hook not duplicated" [ "$(grep -c "offload shell integration" "$HOME/.zshrc")" = 1 ]

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
