# Settings audit and proposed redesign

Date: 2026-11-14. Based on the seven supplied screenshots and current SwiftUI/AppKit source.
This is a design recommendation, not an implemented redesign or a measurement of feature use.
The small Gmail catalog addition is separate from the proposed navigation changes.

## Main finding

The sidebar has 15 possible destinations. It puts daily monitoring, account actions, installation
instructions, app preferences, hub administration and migration recovery at the same level.
The main improvement is to give frequent tasks dedicated screens and move configuration into one
Settings destination. A feature being infrequent is a reason to relocate it, not evidence it can be deleted.

## Proposed navigation

Keep five main destinations: **Dashboard, Accounts, Connectors, Plugins, Settings**.
Dashboard is the normal landing page. The existing compact menu-bar panel stays compact and keeps
its existing progress bars and side details; the larger dashboard belongs in the resizable window.

| Current destination | Proposed location | Change |
| --- | --- | --- |
| Getting Started | First-run checklist; Settings → T3 Proxy → Setup | Once configured, replace the long installation page with compact connection status and a help link. Keep setup accessible. |
| Connection | Settings → T3 Proxy and CLIProxyAPI | Put menu-bar appearance, login, shortcut and refresh preferences with the app; put hub port and management key with the hub. |
| Accounts | Accounts | Searchable provider-grouped list with useful quota bars and a redesigned details inspector. |
| Add Account | Accounts → floating Add Account button → sheet | An action inside Accounts, with a visible label, keyboard access and an empty-state entry point. |
| Quota | Dashboard → Live limits | Compact provider summaries and per-account limits alongside usage history. |
| Usage | Dashboard → Activity and API-equivalent value | Move recorder preferences out of analytics; keep history, dates, account breakdowns and price qualifications. |
| Routing | Settings → Routing | Consolidate strategy, priorities, Team guard, aliases, exclusions and client keys. |
| Notifications | Settings → T3 Proxy → Notifications | App preferences rather than a separate navigation destination. |
| T3 Code | Settings → T3 Code | Connection, profile setup, thread session and diagnostics together. |
| Config | Settings → CLIProxyAPI; routing fields → Routing | Keep allowlisted editing and change confirmation, with one owner for each setting. |
| Plugins | Plugins | Retain browsing, installation and configuration. These are hub plugins and have different behavior from MCP connections. |
| Connectors | Connectors | Keep account-specific MCP connections and quick connections easy to reach. |
| Logs | Settings → CLIProxyAPI → Diagnostics | Show a compact status and expandable log console with existing filtering and request-log access. |
| Proxy Deck | Settings → Deck Migration, only where relevant | Remove it from the main sidebar; retain import, ownership status and recovery actions. |
| About Proxy | App version → T3 Proxy; hub version/update → CLIProxyAPI; snippets → Setup help | Separate app information from hub operations and repeated setup instructions. |

Settings uses native tabs: **T3 Proxy, T3 Code, CLIProxyAPI, Routing**, plus **Deck Migration** when
legacy Deck state exists. The Deck tab describes migration and recovery, not a second active product.
Use short summaries and expandable advanced sections instead of another long stack of forms.
Existing menu-bar links and first-run links must route to the new destination and selected tab.

## Dashboard: combine quota and usage

- A compact header shows last successful quota read, usage history freshness and refresh controls.
  Quota is live; the selected history range does not imply historical quota readings.
- A row of stats shows recorded tokens, requests, API-equivalent value and routable accounts.
  Use one history range control for the history cards, chart and per-account history breakdown.
  Keep any all-time or last-12-months calendar scope explicit.
- On a wide window, place **Live limits** and **Usage activity** side by side. Stack them at narrow widths.
  Size the breakpoint from the actual minimum usable content widths, including the inspector.
- Live limits has compact Claude and Codex summaries followed by one row per account, instead of
  repeating the same account across several full-width quota lanes. Preserve the familiar thin
  progress bars, pacing marks, percentages and reset times. Fable and extra usage appear when reported;
  unavailable readings remain identifiable without dominating the screen.
- Usage activity contains the daily chart and calendar with day selection. Show day/model details
  only after selection. Put the sortable account breakdown below, with tokens, requests and value.
- API-equivalent value must remain labelled as an estimate, not subscription spending or a bill.
  Keep unknown model prices and partial totals visible. Provider averages must remain labelled as
  equally weighted measured accounts; they are not a shared pool of interchangeable subscription capacity.
- Usage and live quota must retain independent loading, stale, error and unknown states. A history
  error must not blank working quota data, and unavailable quota must not look like zero remaining.

## Accounts: management without spreadsheet filler

Retain a scalable, selectable list. Use provider group headers, search and status filtering.
Rows show provider mark, nickname, plan/team, routing status and compact 5-hour/weekly bars.
Keep Fable information discoverable through details. A nickname is the main label; move credential
filenames to a technical-details disclosure, with copy available there. Do not lose a stable way to
distinguish two accounts with the same nickname.

The screenshot's repeated blank stripes come from a native Table filling a large empty region.
Use content-aware list presentation so empty space remains quiet. Keep the row height and type readable
without turning every account into an oversized card. Search, selection and scrolling must work with
dozens of accounts, not only the six in the screenshots.

The floating **Add Account** button opens the existing provider sign-in/import flow in a sheet.
Inset it above the bottom edge and reserve space so it never covers the last row, scrollbar or error.
Keep the button available to keyboard and VoiceOver users. Closing/cancelling a sheet must not falsely
report a cancelled upstream login as completed; show the actual session state when reopened.

The inspector starts with identity, provider and plan, then live limits/reset details and recent usage.
Put nickname, enabled state and priority in a concise management section. Put refresh-token and
cooldown actions under Troubleshooting; isolate Delete Account with its existing confirmation.
Keep rate limits distinct from credential errors. Resetting a cooldown is not redeeming a usage reset.
Preserve quota redemption confirmation, account binding and pending/uncertain retry state.

## Fix the quota hover interaction

`HoverCardController.positionPanel` currently chooses a horizontal position from the parent
window's frame and only uses the row for vertical alignment. The quota dashboard uses this same
controller as the compact menu panel. For a wide Settings window, clamping a window-side card to
the visible screen can place it over distant content, as the screenshot illustrates.

Use a context-specific presentation:

- Menu-bar panel: keep the existing child window beside the compact panel.
- Settings: anchor a small native popover to the hovered account row/tile, choosing an available edge.
  Click or the accessible Show Details action opens/pins a persistent account inspector for interaction.
- Share the details content and account identity, not necessarily the presentation controller.
  Show weekly, Fable and full-reset grants separately, with titles, availability and expiry intact.
- Moving into the interactive card must keep it open. Close or reposition it when its row scrolls away,
  selection changes, tabs change, the window resizes or the display changes.
- Verify screen-edge placement, multiple monitors, scroll, click-to-pin, Escape, keyboard access,
  reset confirmation cancellation and switching accounts while a read is in flight.

This is a source diagnosis and proposed fix; the redesigned interaction has not been implemented
or exercised in the native app during this audit.

## Gmail quick connection

The quick list now includes **Gmail via Pipedream** first. Pipedream's own Gmail page and end-user
MCP documentation specify `https://mcp.pipedream.net/v2`, browser sign-in and app selection.
The user authorizes Gmail through this existing hosted MCP service, without creating a Google Cloud
OAuth client for T3 Proxy. This is an external service and remains explicitly named in the UI.

The endpoint is shared across apps. Selecting the Gmail preset does not filter tools or prove which
Google account is bound upstream. The browser consent, discovered tools and actual returned account
must establish that. Do not claim multi-account Gmail isolation from separate local UUIDs alone.

Remaining runtime acceptance: sign in, discover Gmail tools, perform an authorized search/read and
retrieve an attachment in fresh Codex Proxy and Claude Proxy sessions while inference uses the hub.
Then verify two intended Google identities separately if multiple-account support is being claimed.
Neither the documented endpoint nor a green catalog test proves those operations work.

Sources: [Pipedream Gmail](https://mcp.pipedream.com/app/gmail) and
[Pipedream MCP setup](https://pipedream.com/docs/connect/mcp/users), checked 2026-11-14.

## Cleanup that should preserve behavior

Remove duplicate navigation and repeated introductory text as screens move. Keep one setup flow
with contextual links, one owner per setting, shared account details and shared quota visual components.
Do not remove the Deck migration engine, legacy usage import or usage-source support just because its
sidebar entry goes away: they protect existing history and prevent competing usage queue consumers.
Keep service ownership, limits-endpoint ownership, live inference, accounts and existing T3 profiles intact.

Before changing navigation, map every `SettingsRouter` caller to its new screen/tab and preserve startup
arguments. Before changing account views, preserve management-key gating, busy state, destructive
confirmations and mutation ownership. Before combining dashboards, reuse the existing live and history
models so the redesign does not introduce competing pollers or recorders.

## Suggested implementation order

1. Consolidate navigation and introduce Settings tabs, keeping existing pane bodies and router links working.
2. Merge Accounts and Add Account; redesign rows and inspector with the existing account actions.
3. Compose quota and usage into the responsive dashboard without rewriting their data models.
4. Separate Settings details presentation from menu-panel hover, then verify both native surfaces.

Check each step before proceeding: source review, relevant existing tests, release build, and native
interaction at minimum and wide window sizes. Treat design screenshots as visual references;
only actual provider responses and stored usage history may be presented as live data.
