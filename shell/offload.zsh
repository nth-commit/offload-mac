# offload shell integration — sourced from ~/.zshrc by install.sh.
#
# Loads the env file written by 'offload apply' and re-loads it before each
# prompt if it has changed (e.g. autostart flipped modes when you left home).

typeset -g _offload_env="${XDG_STATE_HOME:-$HOME/.local/state}/offload/env.sh"
typeset -g _offload_env_mtime=""

_offload_load() {
  [[ -r $_offload_env ]] || return
  zmodload -F zsh/stat b:zstat 2>/dev/null
  local m
  m=$(zstat +mtime "$_offload_env" 2>/dev/null) || m=$(stat -f %m "$_offload_env" 2>/dev/null)
  [[ $m == "$_offload_env_mtime" ]] && return
  _offload_env_mtime=$m
  source "$_offload_env"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _offload_load
_offload_load
