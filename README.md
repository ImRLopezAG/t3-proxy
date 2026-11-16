# T3 Proxy

A native macOS menu-bar app for a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) hub. It shows
how much of your Claude and Codex subscriptions you have left, what your traffic would cost at API prices, and what
your T3 Code threads are doing, all from one icon in the menu bar.

Written in Swift with SwiftUI and AppKit. No dependencies or web views for the UI. Hub management uses
127.0.0.1; optional connector checks run your installed client, which contacts its configured services.

## What you get

- **Overview.** Tokens for today, the last 24 hours or 7 days, with an estimated API cost per provider. It
  also shows the remaining quota pooled per provider and a year of daily history.
- **Accounts.** Each subscription's usage windows (5-hour, weekly, Fable weekly; only the ones that account
  has), with a pace marker that warns before an account runs out. Hover an account for today, the current window
  and 30-day cost and tokens.
- **Threads.** Your T3 Code threads as cards with project icon, branch, PR and provider. Subagents are listed
  under their parent, snoozed threads have their own section, and a click opens the thread in T3 Code.
- **Menu-bar activity.** A layered orb shows working, background/waiting, needs-you and snoozed work together.
  Choose colors that match your menu bar or your own palette, or keep the classic T3 icon. Idle and Reduce Motion stay still.
- **Settings.** Add, rename, enable or disable, prioritize and delete accounts through the hub's own API. Also
  quota, routing, notifications, config, plugins, logs, usage recording and hub updates.
- **Quota resets.** See available Claude reset grants and their expiry, including separate weekly and Fable
  grants, and redeem supported Claude or Codex resets in the app after confirming.
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
curl -fsSL https://raw.githubusercontent.com/ImRLopezAG/t3-proxy/main/install.sh | sh -s -- --version 0.3.0
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
   The shortcut can be changed in Settings → T3 Proxy → General.
3. **Enter the hub's management key** in Settings → CLIProxyAPI → Connection. It is the secret you set under
   `remote-management` → `secret-key` in the hub's `config.yaml`. If the hub doesn't listen on 8317, set its port on the same pane.
4. **Allow Keychain access.** macOS asks once whether T3 Proxy may read the key it stored. Choose **Always Allow**.
5. **Optional:** connect T3 Code (Settings → T3 Code) and turn on usage recording (Settings → T3 Proxy → History) for history
   and cost estimates.

Settings → T3 Proxy → Setup shows this checklist with live check marks.

### Plugins

Settings → **Plugins** manages CLIProxyAPI plugins through the hub’s management API:

- **Installed:** view status, enable or disable, configure declared fields, and uninstall plugins.
- **Browse:** search the hub’s plugin store and install or update a plugin after reviewing its source and version.

Changes require confirmation and affect every client using the hub. Stored plugin secrets stay hidden; leaving
a secret unchanged keeps its existing value. Structured configuration fields are edited in the hub’s config file.
The hub downloads and loads plugin code. If an action requires a restart, T3 Proxy tells you and leaves the
restart to you. An action blocked by a loaded plugin must be reviewed and retried after restarting.

The page requires a hub build with the Plugins and Plugin Store management APIs. Older builds show an
unsupported message. Store authentication, when required, is configured in the hub.

### Shared MCP connections

Settings → **Plugins → Connectors** manages existing MCP servers. Add a connection once, choose **Codex Proxy**,
**Claude Proxy**, or both, then authenticate with that MCP service. Add separate named connections for
each account or workspace, including multiple accounts at the same MCP URL. T3 Proxy does not build
service integrations or import ChatGPT/Claude web connections.

**Add MCP Connection** opens a searchable quick-connect list for Gmail via Pipedream, Linear, Notion, GitHub, Neon, Vercel,
WorkOS and Firecrawl. Choose a service to fill in its official server details, name the connection and
choose its clients. OAuth services use **Sign In** after adding; GitHub uses an access token stored in
Keychain. The Gmail option uses Pipedream's hosted MCP service: sign in to Pipedream, select Gmail,
and authorize the intended Google account. It does not require your own Google Cloud OAuth client.
Pipedream handles the service connection; available tools and account selection depend on its consent flow.
**Custom MCP…** keeps manual remote and local server setup available, including alternative Gmail
servers and project-specific servers. Each addition has its own local connection identity.

Settings → T3 Proxy → **Setup** → **Set Up T3 Proxy** creates missing isolated profiles and customization links, registers the two proxy
providers in T3 Code, and synchronizes managed MCP entries. Existing inference configuration, MCP servers,
accounts and original profiles are preserved. Changed files receive private backups. Setup never starts
or restarts CLIProxyAPI. New launchers need a hub API key saved separately in Keychain; existing launchers
keep their authentication. Start fresh client sessions after setup.

Remote connections support Streamable HTTP with OAuth, a bearer token, or no authentication. Local
connections use an executable and a JSON array of arguments; credential environment variables go in
Keychain. Use a provider's documented endpoint or executable. Gmail, GitHub, Linear, Notion and other
services are supplied by the MCP server you choose, with that server's permissions and capabilities.

T3 Proxy uses the installed Codex CLI as an MCP transport/OAuth engine for both clients, in a private home
for each connection. It never starts model turns in that engine. An internal per-connection relay forwards
the upstream server's actual tools and resource reads; there is no aggregate T3 tool catalog. Each connection
has a unique server identity, so credentials do not follow rotating inference subscriptions. OAuth is stored
by Codex in Keychain; bearer tokens and credential variables use T3 Proxy's separate Keychain items.
This requires a compatible Codex app-server API (verified with 0.169.0). OAuth endpoints that require an
unavailable client registration report an authorization failure. Prompts, subscriptions and interactive
server elicitation are not forwarded in this first version.

**Check** verifies discovery, not successful service tool calls. **Client Diagnostics** checks profile tool
catalogs separately. Real Gmail search/read/attachment access still requires an existing Gmail MCP server,
its account consent, and verification through fresh proxy sessions. [Implementation and evidence](docs/connectors.md).

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

## Dashboard and Settings

The window has four sections: Dashboard, Accounts, Plugins, and Settings. Dashboard combines live limits, usage statistics, the activity calendar, and account/model history. Accounts groups subscriptions by provider, with search, status filters, compact quota bars, and an inspector. Use **Add Account** (⌘N) to open sign-in or import in a dialog. Plugins contains Installed, Browse, and Connectors tabs.

Settings groups app preferences, T3 Code, CLIProxyAPI administration, and routing into tabs. Deck Migration appears when legacy Deck state is present. In Dashboard, hover an account for limits and reset details, or click to pin its inspector. The compact menu-bar panel keeps its side cards.

Settings → T3 Proxy → General lets you choose the animated orb or classic T3 icon. Orb surfaces show concurrent work, background activity and requests; snoozed work uses still silver geometry. Choose **Match menu bar** for automatic contrast or **Custom** for independent Active, Background, Needs you and Error colors. Activity comes from T3 Code thread summaries; token-level streaming is not detected.

See [the changelog](CHANGELOG.md) for release details.

## Usage history and cost estimates

Turning on recording (Settings → T3 Proxy → History) makes T3 Proxy read the hub's usage queue every 30 seconds. It keeps the
records in `~/Library/Application Support/T3 Proxy/usage.sqlite`.

- Only one app can record a hub. Reading the queue removes the records from it, so recording stays off while
  another recorder (such as Proxy Deck) is active.
- Costs are **API-equivalent estimates**, not what a subscription bills. They use list prices per model, including
  cache reads and writes. The hub doesn't say whether a Claude cache write was kept for 5 minutes or 1 hour, so all
  writes are priced at the 5-minute rate and the estimate is a floor.
- A `+` after an amount means some models have no published price and were left out.

### Moving from Proxy Deck

Settings → Deck Migration imports Proxy Deck's history and plan labels. Proxy Deck's files are only read, and the import
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
