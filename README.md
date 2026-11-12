# T3 Proxy

A native macOS menu-bar app for a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) hub. It shows
how much of your Claude and Codex subscriptions you have left, what your traffic would cost at API prices, and what
your T3 Code threads are doing, all from one icon in the menu bar.

Written in Swift with SwiftUI and AppKit. No dependencies, no web views for the UI, and no network traffic beyond
127.0.0.1.

## What you get

- **Overview.** Tokens for today, the last 24 hours or 7 days, with an estimated API cost per provider. It
  also shows the remaining quota pooled per provider and a year of daily history.
- **Accounts.** Each subscription's usage windows (5-hour, weekly, Fable weekly; only the ones that account
  has), with a pace marker that warns before an account runs out. Hover an account for today, the current window
  and 30-day cost and tokens.
- **Threads.** Your T3 Code threads as cards with project icon, branch, PR and provider. Subagents are listed
  under their parent, and a click opens the thread in T3 Code.
- **Settings.** Add, rename, enable or disable, prioritize and delete accounts through the hub's own API. Also
  quota, routing, notifications, config, logs, usage recording and hub updates.
- **T3 Code limit bars.** It serves the endpoint T3 Code already uses on 127.0.0.1:8318, so T3 Code needs no
  extra setup.

## Requirements

- macOS 26 (Tahoe) or later on Apple silicon.
- A CLIProxyAPI hub on the same Mac, with your Claude and/or Codex subscriptions signed in:

      brew install cliproxyapi

  T3 Proxy never installs, starts or reconfigures the hub.
- Optional: [T3 Code](https://github.com/pingdotgg/t3code), for the Threads tab.

## Install

### Homebrew (recommended)

The cask lives in this repository, so tap it once:

```sh
brew tap ImRLopezAG/t3-proxy https://github.com/ImRLopezAG/t3-proxy
brew install --cask t3-proxy
```

### Install script

Downloads the latest release and checks its SHA-256 checksum, code signature and bundle id. It then installs to
`/Applications`, or `~/Applications` when `/Applications` isn't writable, and opens the app:

```sh
curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh
```

A specific version:

```sh
curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh -s -- --version 0.2.1
```

### Manual

Download `T3-Proxy.zip` from the [latest release](https://github.com/ImRLopezAG/t3-proxy/releases/latest), check
it against `T3-Proxy.zip.sha256`, unzip it, and move **T3 Proxy.app** to Applications. Releases are not notarized
yet, so clear the download flag before the first launch:

```sh
xattr -dr com.apple.quarantine "/Applications/T3 Proxy.app"
```

Homebrew and the install script do this for you.

## First run

1. **Start the hub** if it isn't running (`brew services start cliproxyapi`, or however you run it).
2. **Open T3 Proxy.** It lives in the menu bar, not the Dock. Click the icon or press **⌃⌥⌘P** to open the panel.
   The shortcut can be changed in Settings → Connection.
3. **Enter the hub's management key** in Settings → Connection. It is the secret you set under
   `remote-management` → `secret-key` in the hub's `config.yaml`. If the hub doesn't listen on 8317, set its port on the same pane.
4. **Allow Keychain access.** macOS asks once whether T3 Proxy may read the key it stored. Choose **Always Allow**.
5. **Optional:** connect T3 Code (Settings → T3 Code) and turn on usage recording (Settings → Usage) for history
   and cost estimates.

Settings → Getting Started shows this checklist with live check marks.

## Update

```sh
brew update && brew upgrade --cask t3-proxy
```

Or run the install script again; it replaces the app in place. Your settings, key and history are kept.

Releases are ad-hoc signed until a notarized build exists. macOS treats each update as a new app, so it asks for
Keychain access once more after an update. Choose **Always Allow** again.

## Uninstall

```sh
brew uninstall --cask t3-proxy           # keeps settings and history
brew uninstall --zap --cask t3-proxy     # also removes them
```

With the script: `curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh -s -- --uninstall`.
It keeps `~/Library/Application Support/T3 Proxy` and the `dev.t3proxy.app` preferences. The management key stays in
your login Keychain until you delete it in Keychain Access.

## Usage history and cost estimates

Turning on recording (Settings → Usage) makes T3 Proxy read the hub's usage queue every 30 seconds. It keeps the
records in `~/Library/Application Support/T3 Proxy/usage.sqlite`.

- Only one app can record a hub. Reading the queue removes the records from it, so recording stays off while
  another recorder (such as Proxy Deck) is active.
- Costs are **API-equivalent estimates**, not what a subscription bills. They use list prices per model, including
  cache reads and writes. The hub doesn't say whether a Claude cache write was kept for 5 minutes or 1 hour, so all
  writes are priced at the 5-minute rate and the estimate is a floor.
- A `+` after an amount means some models have no published price and were left out.

### Moving from Proxy Deck

Settings → Proxy Deck imports Proxy Deck's history and plan labels. Proxy Deck's files are only read, and the import
can be repeated safely. **Retire** then stops Proxy Deck's launch agent and keeps its files. After that, T3 Proxy
takes over the T3 Code limits endpoint and usage recording. **Restore** undoes it.

## Privacy and safety

- The management key is stored in your Keychain (this Mac only) and sent only to 127.0.0.1. Redirects are refused.
- The hub bans a client for 30 minutes after a request with a missing or wrong key, and that would also lock out
  T3 Code. So no request is sent without a key, and a key the hub rejects is never sent again until the app restarts.
- Account changes go through the hub's management API, and each one asks first. Delete re-checks that the account
  hasn't changed since you confirmed and removes only that one credential.
- Hub status text is shown only as a fixed category, because it can quote upstream errors.
- The T3 Code limits endpoint listens on 127.0.0.1 only and refuses browser origins. It answers a wrong key itself,
  so the hub never sees one.

## Build from source

Needs Xcode 26 (Swift 6.2).

```sh
./build.sh                      # tests, release build, ad-hoc signed dist/T3 Proxy.app
open "dist/T3 Proxy.app"
```

Command-line flags on the app binary (`dist/T3 Proxy.app/Contents/MacOS/T3Proxy`):

| Flag | Does |
|---|---|
| `--settings` | Opens with the Settings window |
| `--probe` | Unauthenticated health check of the hub |
| `--render-preview <dir>` | Writes design renders with sample data, marked SAMPLE DATA |

Packaging, releases and notarized builds are covered in [`docs/SHARING.md`](docs/SHARING.md).

## Credits

Provider logos in `Sources/T3ProxyUI/Resources/` are from
[@lobehub/icons-static-svg](https://github.com/lobehub/lobe-icons) (MIT); see `ICONS-LICENSE.txt` there.

## License

MIT. See [`LICENSE`](LICENSE).
