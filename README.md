# T3 Proxy

Native macOS 26+ menu-bar app (Swift, SwiftUI/AppKit, Liquid Glass, no dependencies) for an existing local CLIProxyAPI.
It is replacing the Proxy Deck web dashboard; see `docs/PLAN.md` for the phases.

## Install

Needs macOS 26 on Apple silicon and a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) hub
(`brew install cliproxyapi`). T3 Proxy never installs or starts the hub.

    # Script: downloads the latest release, verifies its SHA-256 and signature, installs to /Applications
    curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh

    # Homebrew (the cask lives in this repo)
    brew tap ImRLopezAG/t3-proxy https://github.com/ImRLopezAG/t3-proxy
    brew install --cask t3-proxy

Then enter the hub's management key in Settings → Connection; Settings → Getting Started lists what's left.
Uninstall with `sh install.sh --uninstall` or `brew uninstall --cask t3-proxy`. Releases are ad-hoc signed until a
notarized build exists (see `docs/SHARING.md`).

## Build from source
It never starts, stops or replaces the proxy and never reads its config or credential files. Account changes
(Settings → Accounts) go through the hub's own management API, each after a confirmation.

    ./build.sh                     # tests, release build, ad-hoc signed dist/T3 Proxy.app
    open "dist/T3 Proxy.app"       # one menu bar icon; reopening from Finder opens the panel
    "<binary>" --settings          # open with the Settings window
    "<binary>" --probe             # unauthenticated health check
    "<binary>" --render-preview d  # design renders, marked SAMPLE DATA

## Data sources

| UI | Source | Status |
|---|---|---|
| Live/offline | `GET /` (no key) | Verified live against 8.0.55 |
| Accounts, held reasons, request sparklines | `GET /v0/management/auth-files` | Tested with stubs; shape read from 8.0.35 source. Not yet run against live 8.0.55 |
| Settings → Accounts: nickname, plan, priority, status; rename, priority, enable/disable, reset cooldown, refresh | `/v8/management/credentials`, `credentials/fields`, `credentials/status`, `credentials/refresh`, `routing/cooldown/reset` | List verified live against 8.0.55; writes tested with stubs only |
| Remaining quota (pooled per provider) | `quota`/`model_quotas` in `GET /v0/management/auth-files` (rate-limit headers the hub recorded) | Verified live |
| Daily token history (calendar) | Proxy Deck's `.data/usage.sqlite`, opened read-only (never the hub's usage queue) | Verified live; temporary until phase 4 |
| Settings: Add Account, Config, AI Providers, Logs, About | `/v8/management/oauth/*`, `config`, `routing/model-definitions`, `observability/logs*`, `server/latest-version` | Reads verified live; writes (OAuth, config toggles, clear logs) stub-tested only | Shown as "Not measured" / empty, never estimated |

## Safety rules

- A management request without a key, or with a wrong one, counts toward a 30-minute ban on 127.0.0.1,
  which would also lock out T3. So no request is sent without a key, and every management request (polling, Settings, each step of a write) is checked against one in-memory lock: after a 401/403 that key is never sent again, even if re-entered, until the app restarts.
- Hub status text is shown only as a fixed category (it can quote upstream errors).
- `usage-queue` is read only by the opt-in usage recorder (Settings → Usage), because reading it removes records:
  it is off by default and refuses to run while Proxy Deck's database exists.
- The key goes only to loopback, redirects are refused, and it is stored in the Keychain (this device only).

Provider logos in `Sources/T3ProxyUI/Resources/` are from @lobehub/icons-static-svg (MIT); see `ICONS-LICENSE.txt` there.
