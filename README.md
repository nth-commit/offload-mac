# offload

Work on one Mac and run the heavy stuff on another.

offload is for people with two Macs: one that stays at home (such as a Mac mini) and one that travels (such as a MacBook). At home, you work on the mini and Docker runs on the MacBook. When you take the MacBook away, it sends Docker back to the mini over Tailscale. Other workloads, such as a local LLM server, can stay on one Mac wherever you are.

offload detects where you are and points your tools at the right Mac. Docker switches contexts, published ports are forwarded to `localhost`, and env vars such as `OLLAMA_HOST` are updated in new shells.

```
$ offload
macbook · away · macbook is primary, mini is worker
  public IP 198.51.100.9 isn't home
  docker     → mini               ✓
  llm        → mini               ✓
```

## Getting started

You need two Macs signed in to the same [Tailscale](https://tailscale.com) network.

**1. Install on both Macs:**

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/nth-commit/offload-mac/main/install.sh)"
```

The installer puts `offload` on your PATH and offers to install Homebrew, Tailscale and Docker Desktop if they're missing.

**2. Check the config.** Open it with `open "$(offload config)"`. The machine `host` names must match the Macs' Tailscale names.

**3. Run setup on both Macs.** Open a new terminal and run:

```sh
offload setup
```

Setup sets up SSH between the Macs, records your home network, creates a Docker context and turns on autostart. Run it on the MacBook while you're at home, then run `offload sync-config` to copy the config to the mini.

**4. Check everything works:**

```sh
offload doctor
offload status
```

After setup, offload runs on its own at login, when the network changes and every 5 minutes.

## Commands

```sh
offload              # detect where you are and route workloads
offload status       # where each workload runs and whether it's healthy
offload ssh [target] # shell on the other Mac (or: primary | worker | <machine>)
offload mode off     # stop offloading (also: home | away | auto)
offload doctor       # check prerequisites on both Macs
offload update       # update to the latest version
offload help         # all commands
```

## Configuration

The config lives at `~/.config/offload/config.toml` and should be the same on both Macs. [`config.example.toml`](config.example.toml) documents every option.

Each workload has a `placement`:

- `worker` runs on the Mac you're not using: the MacBook at home, the mini when away.
- `local` always runs on the Mac you're on.
- A machine name, such as `mini`, always runs on that Mac.

`fallback` sets what happens when the target Mac is unreachable: `local` runs it locally, `none` turns it off.

### Docker notes

- Bind mounts refer to paths on the worker, so your code needs to exist there too.
- Add published ports to `ports` to have them forwarded to `localhost`.
- Docker Desktop needs a logged-in session. Turn on automatic login on the mini.

### LLM notes

The `llm` workload works with any HTTP model server, such as Ollama or LM Studio. The server must listen on all interfaces so the other Mac can reach it. For Ollama, set `OLLAMA_HOST=0.0.0.0` in the server's environment.

## Development

```sh
git clone https://github.com/nth-commit/offload-mac
cd offload-mac && ./install.sh
tests/run.sh
```

When installed from a clone, `offload update` runs `git pull`. New workloads go in `modules/<name>.sh`. See [`modules/llm.sh`](modules/llm.sh) for an example.
