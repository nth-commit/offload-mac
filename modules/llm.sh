# shellcheck shell=bash
# llm — point LLM clients at a model server by setting environment variables.
#
# Runtime-agnostic: anything with an HTTP API (Ollama, LM Studio, llama.cpp's
# llama-server, vLLM, …). The defaults suit Ollama and any OpenAI-compatible
# server on port 11434; change `port`, `env` and `start` for others.
#
# Config ([llm]):
#   placement   = "mini"            pin to a machine, or "worker" / "local"
#   fallback    = "none"            "none" unsets the vars; "local" uses this Mac
#   port        = 11434
#   health_path = "/v1/models"      GET here must succeed for "healthy"
#   env         = ["OLLAMA_HOST=http://{host}:{port}", "OPENAI_BASE_URL=http://{host}:{port}/v1"]
#   start       = ""                shell command run on the target if the
#                                   server isn't answering, e.g. "open -g -a Ollama"
#   start_timeout = 30
#
# The server on a remote machine must listen on its Tailscale address, not
# just 127.0.0.1 (for Ollama: OLLAMA_HOST=0.0.0.0 in the *server's* environment).

_port() { wcfg port 11434; }

_templates() {
  wcfg env "OLLAMA_HOST=http://{host}:{port} OPENAI_BASE_URL=http://{host}:{port}/v1"
}

_url() { printf 'http://%s:%s%s\n' "$HOST" "$(_port)" "${1:-}"; }

mod_vars() {
  local t
  for t in $(_templates); do printf '%s\n' "${t%%=*}"; done
}

mod_env() {
  local t k v port
  port=$(_port)
  for t in $(_templates); do
    k="${t%%=*}"; v="${t#*=}"
    v=$(printf '%s' "$v" | sed -e "s|{host}|$HOST|g" -e "s|{port}|$port|g")
    printf '%s=%s\n' "$k" "$v"
  done
}

mod_check() { curl -fsS --max-time 3 -o /dev/null "$(_url "$(wcfg health_path /v1/models)")"; }

mod_up() {
  local start
  mod_check && return 0
  start=$(wcfg start)
  if [ -z "$start" ]; then
    warn "$WORKLOAD: nothing answering at $(_url) (set 'start' in [$WORKLOAD] to launch it automatically)"
    return 1
  fi
  info "  $WORKLOAD: starting server on $(is_local && echo "this Mac" || echo "$TARGET")…"
  on_target "$start" >/dev/null 2>&1
  wait_for "$(wcfg start_timeout 30)" mod_check || { warn "$WORKLOAD: server didn't come up at $(_url)"; return 1; }
}
