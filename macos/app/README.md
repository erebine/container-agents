# Xerotier XIM Agent — macOS app

A native SwiftUI app — the macOS deployment of the Xerotier agent: a one-window
**installer + environment-prep + control surface** that wraps the downloaded
`xerotier-xim-agent` release binary. It presents both a **menu bar
item** (status + quick start/stop) and a **full window**. Everything runs as
the logged-in user — no admin password.

> **Status: real engine.** The install pipeline, service control, preflight,
> release download, and log streaming are implemented natively (see the
> `Sources/XerotierAgent/Engine/` layer). On launch the app inspects the host
> and reflects any existing install.

## Install (recommended)

Download the latest **`Xerotier-<version>.dmg`** from the
[Releases page](https://github.com/cloudnull/xerotier-public/releases/latest),
then:

1. Open the DMG and **drag `Xerotier.app` into Applications**.
2. Launch **Xerotier** from Applications (or Spotlight).
3. Go to **Setup**, paste your join key, and click **Install & Start**.

That's it — no toolchain or `git` checkout required. The app downloads and
configures everything else itself, all as your user (no admin password).

> If macOS Gatekeeper blocks a non‑notarized build, right‑click the app →
> **Open** the first time (or run `xattr -dr com.apple.quarantine
> /Applications/Xerotier.app`). Notarized releases open with no prompt.

## Build from source (optional)

For development, or to run an unreleased build, you need the Xcode/Swift
toolchain (built and verified with Swift 6.2; minimum deployment target macOS
14). From this directory (`macos/app`):

```bash
swift run                    # build + launch
```

or open `Package.swift` in Xcode and press Run. To produce your own signed
`.app` + DMG, see [Packaging](#packaging) below.

## What it does

1. **Setup** — live host preflight (arm64 / macOS 15+ / curl / uv), then paste a
   join key and **Install & Start**. The pipeline runs for real: provision
   Python 3.12 via uv → install vllm-metal → download
   `xerotier-xim-agent-Darwin-arm64` from releases → install the HF shim →
   render the wrapper/entrypoint/plist → `launchctl bootstrap`.
2. **Dashboard** — live service tiles plus Start / Stop / Restart / Uninstall
   (driven by `launchctl`).
3. **Logs** — `tail -F` of `~/Library/Logs/xerotier/xim-agent.{out,err}.log`,
   with stream filter, auto-scroll, and clear.
4. **Settings** — the full `XEROTIER_AGENT_*` surface; **Apply & Restart**
   re-renders the plist and reloads the agent.
5. **Menu bar** — the bolt icon shows status; the popover gives quick controls
   and an **Open Xerotier…** action.

## Layout

```
Sources/XerotierAgent/
  XerotierAgentApp.swift     @main — Window + MenuBarExtra scenes
  Model/
    Types.swift              enums/structs (state, steps, logs, settings)
    AppModel.swift           @Observable state; drives the engine
  Engine/                    install + service control engine
    Paths.swift              install locations + uname helpers
    Shell.swift              async Process runner (line-streamed + capture)
    Preflight.swift          host checks (arch/macOS/curl/uv)
    Templates.swift          embedded entrypoint / vLLM wrapper / HF shim
    ReleaseFetcher.swift     GitHub releases API + URLSession download
    Installer.swift          per-step install pipeline
    ServiceController.swift  launchctl bootstrap/bootout + plist + status
    LogTailer.swift          tail -F the agent logs
  Views/
    RootView.swift           sidebar + detail; runs bootstrap() on appear
    MenuBarContent.swift      menu bar popover
    OnboardingView.swift     Setup pane (preflight + join key + pipeline)
    DashboardView.swift      status tiles + service controls
    SettingsView.swift       XEROTIER_AGENT_* form
    LogsView.swift           streamed log viewer
    Components.swift         Card, StatusPill, StepRow, InfoTile, EmptyState
```

## Packaging

For maintainers: this is how the release `Xerotier-<version>.dmg` (the
[recommended install](#install-recommended)) is produced. Build a distributable
`.app` and DMG from `packaging/`:

```bash
# Ad-hoc signed (local/dev) — no Apple Developer ID needed:
./packaging/build-app.sh            # → dist/Xerotier.app
./packaging/make-dmg.sh             # → dist/Xerotier-<version>.dmg

# Signed + notarized (for distribution):
CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
  VERSION=0.0.0 ./packaging/build-app.sh
NOTARY_PROFILE=xerotier-notary VERSION=0.0.0 ./packaging/make-dmg.sh
```

- `build-app.sh` builds the release binary, assembles the bundle from
  `packaging/Info.plist` (bundle id `com.xerotier.agent`, min macOS 14), and
  signs (hardened runtime + timestamp when a real identity is given).
- The **app icon** is rasterized crisply from `packaging/xerotier-favicon.svg`
  (the official mark) via `make-icon.sh` → `make-icon.swift`, with the
  background themed to the Xerotier warm cream `#FFF5EE` (override with
  `ICON_BG`).
- `make-dmg.sh` builds a drag-to-Applications DMG and, when `NOTARY_PROFILE`
  (a stored `notarytool store-credentials` profile) is set, notarizes + staples.
- `.github/workflows/macos-app.yml` runs the same scripts in CI (ad-hoc by
  default; uncomment the signing block + add secrets for notarized releases).
- `dist/` is git-ignored.

## Notes

- **LaunchAgent** is managed via `launchctl` against a plist written to
  `~/Library/LaunchAgents`, because the plist is rendered dynamically with the
  join key and absolute paths. `SMAppService` is the App-Store-friendly
  alternative once the plist can be bundled.
- **Templates** (`entrypoint`, vLLM wrapper, HF shim) are embedded in
  `Templates.swift` so the app is self-contained and is the source of truth for
  the rendered artifacts.
- **Accelerator readout** is live from Metal (`MTLCreateSystemDefaultDevice`,
  `recommendedMaxWorkingSetSize`).
