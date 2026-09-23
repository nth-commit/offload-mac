# offload

Use one Mac and have the other do the heavy lifting, then swap roles when you travel.

- **At home:** you work on the **mini**, and the **MacBook** runs Docker (and anything else you offload).
- **Away:** you take the **MacBook**, and it offloads to the **mini** back home over Tailscale.
- **Some things stay put:** e.g. LLMs always run on the mini, wherever you are.

offload works out where you are, decides which Mac should run each workload, and points your tools there. There's nothing to run on the "host" side; both Macs are always ready to be the worker.

```
$ offload
macbook · away · macbook is primary, mini is worker
  public IP 198.51.100.9 isn't home
  docker     → mini               ✓
  llm        → mini               ✓
```

## How it decides

The travelling Mac's location sets the **mode**:

| Mode   | When                          | Primary (you're on it) | Worker          |
|--------|-------------------------------|------------------------|-----------------|
| `home` | the MacBook is at home        | mini                   | MacBook         |
| `away` | the MacBook is somewhere else | MacBook                | mini            |
| `off`  | you said so                   | whichever you're on    | none (all local) |

- **On the MacBook:** it's home if its public IP matches your static home IP. If you're on a VPN, it falls back to matching your router's MAC address.
- **On the mini:** it's `home` if the MacBook answers on the LAN (`macbook.local`), otherwise `away`. That way, if you SSH into the mini while travelling, commands you run there stay on the mini.

Each **workload** then gets a placement:

- `worker`: whichever Mac is the worker. If you're *on* the worker, it runs locally.
- `local`: always the Mac you're on.
- `mini` (or any machine name): always that Mac. If you're on it, that means locally.

If the target Mac can't be reached, `fallback` decides: `local` runs it where you are, `none` switches it off (and unsets its env vars).

## Install

On **both** Macs, run:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/offload/main/install.sh)"
```

This downloads offload to `~/.local/share/offload` (no git needed), puts `offload` on your PATH, and offers to install Homebrew, Tailscale and Docker Desktop if they're missing. Run `offload update` later to get the latest version.

The `bash -c "$(curl …)"` form keeps the installer's prompts interactive. To accept every prompt unattended, use `curl -fsSL <url> | bash -s -- --yes` instead. (This only works while the repo is public. For a private repo, use a clone as below.)

If you're working on offload itself, run it from a clone instead. `offload update` then does a `git pull`.

```sh
git clone https://github.com/YOUR_GITHUB_USER/offload ~/Dev/personal/offload
~/Dev/personal/offload/install.sh
```

Then open a new terminal and run `offload setup` on each Mac. It walks through:

1. Which machine this is
2. Adding Homebrew/Docker to `~/.zshenv`, so `docker` works over SSH (a common gotcha on macOS)
3. Turning on Remote Login
4. SSH keys to the other Mac
5. Recording your home public IP and router MAC. Run it on the mini, or on the MacBook while you're at home, then `offload sync-config`
6. Creating the Docker context for the other Mac
7. Sleep settings. The mini never sleeps and restarts after a power cut; the MacBook is kept awake with `caffeinate` only while it's the worker
8. Autostart: re-applies at login, whenever the network changes, and every 5 minutes

Check everything with `offload doctor`.

Before running setup, **Tailscale must be up on both Macs**, and the machine names in `~/.config/offload/config.toml` must match their Tailscale names.

## Usage

```sh
offload              # detect + apply (autostart does this for you)
offload status       # where each workload is and whether it's healthy
offload mode off     # stop offloading for now (also: home | away | auto)
offload doctor
offload update       # latest version (git pull if installed from a clone)
```

New shells pick up changes automatically: the zsh hook re-reads `~/.local/state/offload/env.sh` whenever it changes. Scripts can use `OFFLOAD_CURRENT_MODE`, `OFFLOAD_PRIMARY` and `OFFLOAD_WORKER`, or `offload resolve` for machine-readable output.

## Config

`~/.config/offload/config.toml`. Keep it the same on both Macs (`offload sync-config`). See [`config.example.toml`](config.example.toml) for every option. The key parts:

```toml
[offload]
workloads = ["docker", "llm"]

[docker]
placement = "worker"
ports     = [3000, 5173]   # forwarded to localhost when Docker is remote

[llm]
placement = "mini"
fallback  = "none"
env       = ["OLLAMA_HOST=http://{host}:{port}", "OPENAI_BASE_URL=http://{host}:{port}/v1"]
start     = "open -g -a Ollama"
```

## Workloads

### docker

This switches `docker context` between the local engine and `offload-<machine>` (Docker over SSH, so nothing is exposed on the network). Everything that respects the current context follows it, including `docker compose`.

If the engine on the target isn't running, offload starts Docker Desktop over SSH.

Things to know:

- **Bind mounts use the worker's filesystem.** `-v ./src:/app` refers to that path *on the worker*, so the code needs to exist there. Keep a clone on both Macs, or edit on the worker directly (VS Code/Cursor Remote-SSH, devcontainers). A sync module (Mutagen) is the obvious next addition.
- **Published ports are on the worker.** List them in `ports` and they're forwarded to `localhost` over SSH. Otherwise, use `http://mini:3000`.
- **Docker Desktop needs a logged-in GUI session.** Turn on automatic login on the mini and "Start Docker Desktop when you sign in".

### llm

This doesn't care which runtime you use. It sets env vars pointing at an HTTP model server (Ollama, LM Studio, llama.cpp's server, …) and checks it's healthy. With `placement = "mini"`, it's `localhost` on the mini and `http://mini:11434` from the MacBook.

The server must listen on more than 127.0.0.1 so the MacBook can reach it over Tailscale. For Ollama, that means setting `OLLAMA_HOST=0.0.0.0` in the *server's* environment. Leave `gui_env` off on the mini, or it will set `OLLAMA_HOST` to the client URL and the server will bind to localhost.

## Adding a workload

Drop a file in `modules/<name>.sh` (or `~/.config/offload/modules/`) and add a `[<name>]` section plus an entry in `workloads`. Every function is optional:

```bash
mod_up()    { ...; }   # make the service ready on $TARGET and point tools at it
mod_down()  { ...; }   # clean up when moving away from $TARGET (tunnels etc.)
mod_check() { ...; }   # healthy? (used by `offload status`)
mod_vars()  { echo MY_URL; }                 # env vars this module manages
mod_env()   { echo "MY_URL=http://$HOST:8080"; }
```

Available inside a module:

- `$WORKLOAD` is the section name.
- `$TARGET` is `local` or a machine name.
- `$HOST` is `localhost` or the machine's Tailscale name.
- Helpers: `wcfg key [default]` (config for this workload), `is_local`, `on_target "cmd"` (runs here or over SSH), `tunnel_open`/`tunnel_close`, `wait_for`, `with_timeout`, `info`/`warn`.

One module can back several workloads with `module = "llm"`. For example, `[llm]` could be pinned to the mini while `[llm-small]` stays local.

## Development

```sh
tests/run.sh                 # scenario tests, all macOS/network commands stubbed
shellcheck -x bin/offload lib/*.sh modules/*.sh install.sh tests/run.sh
```

Everything targets macOS's built-in bash 3.2. CI runs on `macos-latest` to keep it that way.
