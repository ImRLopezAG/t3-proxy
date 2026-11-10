# T3 Proxy: replace Proxy Deck with the native app

Decision (user, 2026-11-06): T3 Proxy becomes the only UI for the local CLIProxyAPI hub.
Proxy Deck (`dev.proxy-deck` launch agent, Bun, 127.0.0.1:8318, source in
`~/.t3/scratch/2026-10-29-search-a-thread-on-t3-6ad5e6d1`) is removed only after every
duty below is native and verified. The UI is native macOS 26+ (Liquid Glass, system controls).

## What Proxy Deck does today (must not regress)

| Duty | Proxy Deck source | Native replacement |
|---|---|---|
| Account admin: nickname, plan/org, routing priority, enable/disable, cooldown reset, refresh | `src/mgmt/registry.ts`, `web/pages/auth-files` | Settings → Accounts (phase 1) |
| Add accounts via OAuth | `web/pages/oauth`, `oauth.*` ops | Settings → Add account (phase 3) |
| Quota per account (recorded headers + live read), 35-day quota history | `src/hub.ts`, `src/history.ts`, `src/pool.ts` | Core quota reader + SQLite (phase 2) |
| Token usage collector (sole `usage-queue` consumer), 365-day history | `src/usage.ts`, `.data/usage.sqlite` | Core collector + import of existing DB (phase 4) |
| T3 Code limits source at `http://127.0.0.1:8318/t3` (per-subscription bars) | `src/t3.ts` | Loopback listener in the app, same contract (phase 4) |
| Config toggles, logs, plugins, quick start, Tailscale serve | other pages | Later phases, as needed |

## Status (2026-11-06)

Done: glass panel, Settings (Connection, Accounts, Add Account/OAuth, Quota, Usage, AI Providers, Config,
Logs, About Proxy), pooled quota from recorded hub data, token activity calendar. The calendar still reads
Proxy Deck's `usage.sqlite` read-only, so Proxy Deck must keep running until phase 4. Not ported yet:
Plugins / Plugin Store, live quota reads, quota history/forecast charts, Tailscale serve setup.

## Phases

1. **Native look + Settings shell + Accounts.** Glass panel with system segmented tabs; Settings
   window (sidebar) with Connection and Accounts; `/v8/management/credentials` reads and the
   nickname/priority/status/cooldown writes, with confirmation on writes.
2. **Quota.** Remaining quota bars in the panel from recorded rate-limit data; history store.
3. **OAuth add-account flow.**
4. **Usage collector + T3 limits source.** Stop Proxy Deck's collector first (only one consumer of
   `usage-queue`), import `usage.sqlite`, serve `/t3` from the app, repoint or keep port 8318.
5. **Retire Proxy Deck** (with user confirmation): unload `dev.proxy-deck`, keep its data as backup.

Every phase: tests, live check against the running hub, code + security review.
