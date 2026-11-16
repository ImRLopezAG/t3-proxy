# Changelog

## 0.3.0 — 2026-11-16

T3 Proxy brings account management, quota monitoring, plugins and shared MCP connections into one Settings window, with concurrent T3 Code activity visible in the menu bar.

### Accounts and quotas

- Combine quota and usage views in Dashboard, with statistics, history and account details.
- Keep accounts in a searchable table grouped by provider, with compact quota bars and an inspector. Add accounts from a dialog.
- Group compact menu accounts by provider and use nicknames without redundant subscription codes.
- Show provider quota exhaustion as Limited, keeping authentication and service failures distinct.
- Show Claude's actual reset grants, availability and expiry, including separate weekly and Fable grants. Redeem supported resets in the app with confirmation.
- Keep banked Codex resets accessible for paused accounts without enabling routing or consuming a reset automatically.
- Preserve live usage-history snapshots and rebuild missing cached copies.

### Plugins and MCP connections

- Manage installed hub plugins and browse the plugin store from the native app. Plugin management requires a compatible CLIProxyAPI build.
- Add an existing MCP connection once and share its account binding with Codex Proxy, Claude Proxy, or both. Separate named connections retain separate local identities.
- Offer quick connections for Gmail through Pipedream, GitHub, Linear, Notion, Neon, Vercel, WorkOS and Firecrawl, plus custom HTTP and local servers.
- Keep Connectors inside Plugins. Setup preserves existing tools and inference configuration while creating missing isolated profiles, customization links and T3 Code provider registrations.

### Menu bar and threads

- Choose the classic T3 icon or a layered animated orb with automatic menu-bar contrast and custom state colors.
- Show working, background/waiting and needs-you on separate surfaces. Snoozed work appears as still silver geometry, with no additional symbols.
- Preserve motion through state, speed and color changes. Keep idle and Reduce Motion static.
- Defer completion effects until observed child threads and background work settle; show snoozed threads separately in the thread list.
- Use thin native scrollbars throughout the app and retain side hover cards in the compact menu.

### Requirements and limits

- Requires macOS 26 or later on Apple silicon and a local CLIProxyAPI hub. Shared MCP connections additionally require a compatible installed Codex CLI; transport characterization used Codex 0.169.0.
- Gmail uses Pipedream's existing MCP service and consent flow. Real Gmail search, messages, attachments and multiple upstream OAuth account bindings have not been verified. Fixture transport checks do not establish live service access.
- Activity follows T3 Code thread summaries; real token streaming is not detected.
- Releases remain ad-hoc signed and are not notarized. macOS may ask for Keychain access again after updating.

Earlier releases: [0.2.1](https://github.com/ImRLopezAG/t3-proxy/releases/tag/v0.2.1), [0.2.0](https://github.com/ImRLopezAG/t3-proxy/releases/tag/v0.2.0), [0.1.0](https://github.com/ImRLopezAG/t3-proxy/releases/tag/v0.1.0).
