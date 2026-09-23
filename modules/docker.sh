# shellcheck shell=bash
# docker — switch the Docker CLI between the local engine and the other Mac's.
#
# Uses Docker contexts over SSH, so there's nothing to expose on the network:
# `docker context use offload-<machine>` and every docker/compose command
# (and most GUIs) talk to that machine's Docker Desktop.
#
# Config ([docker]):
#   placement     = "worker"         see README
#   fallback      = "local"          if the target is unreachable
#   local_context = "desktop-linux"  Docker Desktop's default context name
#   ports         = [3000, 5173]     forward these to localhost when remote
#   stop_local    = false            quit local Docker Desktop while offloaded
#   start_timeout = 90               seconds to wait for Docker to start
#
# Module interface: mod_up, mod_down, mod_check, mod_env, mod_vars — all
# optional. WORKLOAD, TARGET ("local" or a machine) and HOST are set.

_ctx() {
  if is_local; then wcfg local_context desktop-linux; else echo "offload-$TARGET"; fi
}

# Create the context if it's missing, and repoint it if the machine's host
# changed in the config — a stale endpoint otherwise survives every re-run.
_ensure_ctx() {
  local ctx want have
  ctx=$(_ctx)
  if is_local; then
    docker context inspect "$ctx" >/dev/null 2>&1 && return 0
    warn "docker: no local context '$ctx' (set local_context in [docker])"
    return 1
  fi
  want="ssh://$(ssh_dest "$TARGET")"
  have=$(docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
  if [ -z "$have" ]; then
    docker context create "$ctx" --description "offload → $TARGET" --docker "host=$want" >/dev/null
  elif [ "$have" != "$want" ]; then
    docker context update "$ctx" --description "offload → $TARGET" --docker "host=$want" >/dev/null \
      && info "  docker: context $ctx now points at $want"
  fi
}

_engine_ready() { with_timeout 10 docker --context "$(_ctx)" version --format '{{.Server.Version}}' >/dev/null 2>&1; }

mod_check() { _ensure_ctx && _engine_ready; }

mod_up() {
  local ctx ports
  _ensure_ctx || return 1
  ctx=$(_ctx)

  if ! _engine_ready; then
    info "  docker: starting Docker Desktop on $(is_local && echo "this Mac" || echo "$TARGET")…"
    # Needs a logged-in GUI session on the target (enable automatic login on a headless Mac).
    on_target 'open -g -a Docker' >/dev/null 2>&1
    if ! wait_for "$(wcfg start_timeout 90)" _engine_ready; then
      warn "docker: engine on $(is_local && echo "this Mac" || echo "$TARGET") didn't come up"
      return 1
    fi
  fi

  docker context use "$ctx" >/dev/null || return 1

  if ! is_local; then
    ports=$(wcfg ports)
    if [ -n "$ports" ]; then
      # shellcheck disable=SC2086
      tunnel_open docker "$TARGET" $ports || warn "docker: couldn't forward ports ($ports) — something local already using them?"
    fi
    if [ "$(wcfg stop_local false)" = true ]; then
      osascript -e 'quit app "Docker"' >/dev/null 2>&1
    fi
  fi
}

mod_down() {
  is_local || tunnel_close docker "$TARGET"
}
