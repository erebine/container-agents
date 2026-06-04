# Xerotier XIM on Apple Silicon

The Apple Silicon deployment of the Xerotier inference agent is a native macOS
**application** — [`Xerotier Agent`](app/) — that installs, configures, and
runs `xerotier-xim-agent` with Metal-accelerated vLLM via
[vllm-metal](https://github.com/vllm-project/vllm-metal). It is the installer,
environment-prep, and control surface in one window, and everything runs as the
logged-in user (no admin password).

There is intentionally **no container image** for this backend. vllm-metal
requires native macOS Metal access (MLX + Metal kernels, arm64 Python 3.12), and
Apple's `container` binary runs Linux guests with no GPU/Metal passthrough.

## Requirements

- Apple Silicon Mac (arm64) running macOS 15 (Sequoia) or newer.
- A join key from the dashboard: **Infrastructure → Agents → Generate Join Key**.

(`curl`, `uv`, and Python 3.12 are provisioned automatically — `uv` and a pinned
3.12 are installed on first run if missing.)

## Install

1. Download the latest **`Xerotier-<version>.dmg`** from the
   [Releases page](https://github.com/cloudnull/xerotier-public/releases/latest)
   and drag **Xerotier.app** into Applications.
2. Open **Xerotier** and go to **Setup**.
3. Confirm the host preflight passes, paste your join key, and click
   **Install & Start**.

(Prefer to build from source? See [`app/README.md`](app/README.md).)

The app then, for real:

1. Preflights the host (arm64, macOS, curl, uv).
2. Provisions Python 3.12 via `uv` and installs vllm-metal into
   `~/.venv-vllm-metal` (builds vLLM core from source).
3. Downloads the prebuilt `xerotier-xim-agent` (asset
   `xerotier-xim-agent-Darwin-arm64`) from the newest stable
   [`cloudnull/xerotier-public`](https://github.com/cloudnull/xerotier-public/releases)
   release into `~/.local/bin` (a toggle allows prereleases).
4. Installs the HuggingFace compat shim into the venv.
5. Renders the vLLM wrapper, entrypoint, and a per-user LaunchAgent.
6. Enrolls with the join key and starts the agent under `launchd`.

## Use

- **Dashboard** — live status, the Apple Metal accelerator + unified-memory
  budget (read from Metal), and Start / Stop / Restart / Uninstall.
- **Settings** — the full agent configuration surface (max concurrent jobs, log
  level, metrics port, insecure transport, extra vLLM args/env). **Apply &
  Restart** re-renders the LaunchAgent and reloads the agent.
- **Logs** — the agent's `stdout`/`stderr`, tailed live.
- **Menu bar** — status at a glance with quick start/stop.

The agent reports Apple Silicon as a single `appleMetal` accelerator using the
unified-memory budget (tensor parallelism stays 1).

## Logs & service (manual)

```bash
launchctl print "gui/$(id -u)/com.xerotier.xim-agent" | head -20
tail -f ~/Library/Logs/xerotier/xim-agent.out.log
tail -f ~/Library/Logs/xerotier/xim-agent.err.log
```

## Build & package

The app is a SwiftPM package — run it with `swift run` or open `app/Package.swift`
in Xcode. To produce a signed/notarized `.app` + DMG, see the build and
packaging instructions in [`app/README.md`](app/README.md).
