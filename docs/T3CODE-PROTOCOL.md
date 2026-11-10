# T3 Code local client protocol

Evidence recorded 2026-11-07 against desktop server `0.1.8-nightly.20261107.4314`.

- **verified-live**: observed against the running loopback server with temporary scoped sessions; no orchestration commands were dispatched.
- **verified-from-source**: inspected in the installed desktop bundle, extracted read-only outside the repository. A source claim does not establish live command behavior.
- **inferred**: a T3 Proxy interpretation or client policy, rather than a server guarantee.

## Connection and authentication

| Fact | Evidence |
| --- | --- |
| Connect to `ws://127.0.0.1:3773/ws?orchestrationProtocol=2`. The `/ws` upgrade succeeds with a scoped session in the HTTP `Authorization` bearer header. No cookie, subprotocol, or token query parameter is needed. | verified-live |
| Runtime discovery is `~/.t3/userdata/server-runtime.json`: `port`, `origin`, `serverVersion`, `pid`, `host`. The current server advertises protocol 2 through `server.getConfig` → `environment.orchestrationProtocolVersion`. | verified-live |
| Missing/wrong `orchestrationProtocol` gets HTTP 426, with `code: orchestration_protocol_incompatible` and `orchestrationProtocolVersion: 2`. | verified-from-source |
| `clientSurface`, `clientAppVersion`, `clientDeviceType`, `clientOs`, and other `client*` parameters are optional analytics metadata. The client omits them. Do not put credentials there. | verified-from-source |
| Upgrade authentication falls back to normal request authentication. `parseBearerToken` reads the header; browser clients can instead use short-lived `wsTicket` query credentials. This Swift client does not use tickets. | verified-from-source |
| The Swift client accepts literal `127.0.0.1` only, uses an ephemeral URLSession with cookies, credential storage, cache and configured proxies disabled, and refuses HTTP redirects. The port can come from runtime discovery; an advertised nonloopback host must not be used. | inferred: security policy implemented in T3 Proxy |

**verified-live:** the installed `~/.t3/bin/t3` CLI successfully issued and revoked sessions despite potentially having a different version from the desktop. Sessions used for these probes were confirmed absent using `t3 auth session list --json`. Output was consumed in memory; no token or local conversation content was recorded.

**verified-from-source:** the token-only CLI form is:

```sh
~/.t3/bin/t3 auth session issue \
  --scope orchestration:read --scope orchestration:operate \
  --label "T3 Proxy" --ttl 30d --token-only
```

**verified-live:** `--json` instead returns `{sessionId, token, method, scopes, subject, client, expiresAt}`. `T3CodeTokenCLI.issue` uses this form to retain the nonsecret session ID for `auth session revoke <session-id>`. It captures stdout in memory and suppresses stderr. It never logs raw CLI errors or passes a token in argv. `issue` is explicit; connection/reconnection never creates a session.

**inferred:** save only the returned token in `T3CodeTokenStore`. Its Keychain service is `dev.t3proxy.t3code-session`, account `t3code`, accessibility `WhenUnlockedThisDeviceOnly`. Reads and denied prompts are cached like `KeychainKeyStore`. Keep the returned session ID in caller-owned nonsecret settings if revocation must survive relaunch. Revoke while the ID is available, disconnect the client, then remove the Keychain copy. Removing a local token alone does not revoke its server session. Keychain calls were not exercised during verification, to avoid prompting the user.

## Wire framing

**verified-from-source; verified-live for Request, Exit, Chunk and Ack:** `/ws` uses Effect 4 RPC `layerJson`, not JSON-RPC 2.0 and not newline-delimited JSON. One WebSocket message is one JSON object or an array of frame objects. Both text and binary WebSocket messages carry JSON. There is no additional handshake after the HTTP upgrade.

```json
{"_tag":"Request","id":"1","tag":"server.getConfig","payload":{},"headers":[]}
{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"environment":{"orchestrationProtocolVersion":2}}}}
{"_tag":"Chunk","requestId":"2","values":[{"kind":"synchronized"}]}
{"_tag":"Ack","requestId":"2"}
{"_tag":"Exit","requestId":"3","exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"EnvironmentAuthorizationError"}}]}}
```

**verified-from-source:** request IDs are correlated through `requestId` in replies. The Swift client generates unique string IDs, sends `headers: []` (HTTP authentication already established the session), and does not set `discard`. Unary requests complete with `Exit`; subscriptions deliver repeated `Chunk` frames, each containing a `values` array, until an `Exit` or disconnect.

**verified-from-source; verified-live for acknowledgements:** acknowledge each processed `Chunk` with one `Ack` naming its request ID, not one acknowledgement per value. `withOutputWindow` maintains an eight-chunk window for shell/thread subscriptions. Without acknowledgement a subscription can stall.

**verified-from-source:** RPC heartbeat frames are `{"_tag":"Ping"}` and `{"_tag":"Pong"}`, with no request ID. These are separate from WebSocket control ping/pong frames. `Interrupt` with a `requestId` cancels an RPC; closing the socket also disposes subscriptions. `Defect` is a connection-level failure. The Swift client sends RPC Ping every 15 seconds, responds to Ping, and reconnects if the next heartbeat finds a missing Pong. Heartbeat handling is synthetic-tested for incoming Ping; its timer was not held open against the live server.

**inferred:** compatibility is determined by orchestration protocol 2 and shell `schemaVersion: 2`, rather than pinning a daily `serverVersion` string. HTTP 426, another advertised protocol, another shell schema, or an unknown frame/item kind becomes `T3CodeError.unsupportedServerVersion` (`Unsupported server version`). Unknown object fields are ignored; unknown status strings become `.unknown`. Malformed required data becomes `.invalidResponse`. Raw server error text is never surfaced because it can contain private content.

## RPCs used

| Method | Required scope | Request payload | Response | Evidence |
| --- | --- | --- | --- | --- |
| `server.getConfig` | `orchestration:read` | `{}` | Unary config object. Read `environment.serverVersion` (string), `environment.orchestrationProtocolVersion` (integer). Other fields include `providers`, `settings` and optional shell capability flags; ignored by this client. | verified-live for success/shape; verified-from-source for scope |
| `orchestration.subscribeShell` | `orchestration:read` | `{}` for a fresh full snapshot. Optional `afterSequence`, `requestCompletionMarker`, `omitIdleSubagents`, `omitOlderSettled`. Omit the last two unless advertised capability flags support them. | Stream of shell items described below. | verified-live for default subscription; verified-from-source for optional flags/scope |
| `orchestration.getThreadProjection` | `orchestration:read` | `{threadId: string}` | Unary `{thread, runs, attempts, nodes, subagents, providerSessions, providerThreads, providerTurns, runtimeRequests, messages, plans, turnItems, checkpointScopes, checkpoints, contextHandoffs, contextTransfers, visibleTurnItems, updatedAt}`. Used by the read-only verification probe, not required for list updates. | verified-live for success/shape; verified-from-source for scope and nested contracts |
| `orchestration.dispatchCommand` | `orchestration:operate` | Command object directly, without a `command` wrapper. Stop/manual continuation shapes below. | Unary `{sequence: nonnegative integer}` accepting the command. This does not guarantee provider work has completed. | verified-from-source; synthetic-tested only |

**verified-from-source:** these two scopes suffice for the implemented calls. `server.getUsageSummary` requires `diagnostics:read`; `provider.consumeResetCredit` requires `providers:manage`. Neither is called or granted. Reset-credit consumption is unrelated to the manual continuation implemented here. `orchestration.stopWorkflow` is also an operate-scoped RPC, but is not the per-thread Stop mechanism used here.

## Shell stream and thread fields

| Stream item | Shape and meaning | Evidence |
| --- | --- | --- |
| `snapshot` | `{kind, snapshot:{schemaVersion:2, snapshotSequence, projects:[], threads:[], archivedThreads:[]}}`. Unmarked snapshot replaces the entire list. | verified-live |
| Enrichment snapshot | Same kind, with `resolvedRepositoryIdentityRoots: string[]`. Contains project metadata and empty thread arrays. Merge project metadata; **preserve threads**, even when arrays are empty. An empty unmarked snapshot remains authoritative and clears the list. | verified-live for occurrence/shape; verified-from-source for merge semantics |
| `thread.updated` | `{kind, sequence, location:"active" or "archive", thread: ThreadShell}`. Full replacement of one row; remove it from the opposite location. | verified-from-source |
| `thread.removed` | `{kind, sequence, location, threadId}`. Remove from the specified location. | verified-from-source |
| `project.updated` / `project.removed` | `{kind, sequence, project}` / `{kind, sequence, projectId}`. Project shells use `id`, **`title`**, `workspaceRoot`, plus ignored metadata. | verified-from-source; project title verified by live Swift decoding |
| `synchronized` | `{kind:"synchronized"}` when a completion marker was requested. | verified-from-source |

**inferred:** the client requests a fresh subscription on every reconnect instead of maintaining replay cursors. It publishes complete `T3CodeSnapshot` values through `updates()`, keeping only the latest events for slow consumers. A disconnect retains the last snapshot; consumers must observe connection state to label stale data. A marked enrichment snapshot does not advance the authoritative thread sequence. The initial snapshot has a 30-second watchdog. Transient failures reconnect with exponential backoff (approximately 1–30 seconds, with jitter); protocol/scope/upgrade-authentication errors stop retries. An established socket invalidated by session revocation can close without a distinct authentication error and enter ordinary backoff.

| ThreadShell field | Type / interpretation | Evidence |
| --- | --- | --- |
| `id`, `title`, `projectId` | Strings. Join project ID to project shell `id` / `title`. | verified-live |
| `status` | `idle`, `preparing`, `queued`, `starting`, `running`, `waiting`, `completed`, `interrupted`, `failed`, `cancelled`, `rolled_back`. | verified-from-source for complete set; subset observed live |
| `providerInstanceId`, `modelSelection` | String and `{instanceId:string, model:string, options?:object}`. A legacy selection can name `provider` instead of `instanceId`; Swift accepts either. | verified-live for current shape; verified-from-source for legacy form |
| `lineage` | `{parentThreadId:string or null, relationshipToParent:"fork" or "subagent" or null, rootThreadId:string, sideChat?:boolean}`. `isListed` excludes subagents and side chats without removing them from raw snapshots. | verified-from-source; field present live |
| `latestRunId`, `activeRunId`, `activityRunStatus` | Run IDs are nullable. Optional activity status can report preparing/starting/running/waiting independently of the latest run. | verified-from-source; fields present live |
| `updatedAt`, `archivedAt`, `deletedAt` | ISO-8601 timestamp strings, nullable lifecycle timestamps. Swift parses fractional and whole seconds. | verified-live |
| `settledOverride`, `settledAt` | `"settled"`, `"active"`, or null; timestamp or null. There is no wire `settled` boolean in this version. `isSettled` checks the explicit override. | verified-from-source; fields present live |
| `snoozedUntil`, `snoozedAt` | Optional nullable timestamps. There is no wire `snoozed` boolean in this version. `isSnoozed(at:)` compares the deadline to the current time. | verified-from-source; fields present live |
| `lastErrorClass`, `usageLimitResetAt` | Optional nullable class and reset timestamp. Failed status plus exact `usage_limit` class identifies a limited run; arbitrary error text is not parsed. | verified-from-source; fields present live |
| `limitRecovery` | Optional nullable `{requestId?:string, runId:string, resetAt:timestamp, autoResume:boolean, snooze?:boolean}`. | verified-from-source; field present live |
| `pendingRuntimeRequest` | Null or `{id, kind, createdAt, blocking?:boolean}`. Missing `blocking` means blocking; false permits an async question while work continues. | verified-from-source; field present live |
| `hasActionableProposedPlan`, `pendingGuestMessageCount` | Boolean and optional count; additional actionable user attention signals. | verified-from-source; fields present live |
| `pendingBackgroundTasks` | Optional task roster. Items use `taskId`, `kind`, optional `description`, `parentTaskId`, `awaited`; subagent items may carry `providerInstanceId` and `childThreadId`. Swift also accepts optional `id`, `label`, and `status`, and unknown kind/status strings. | verified-live for nonempty subagent items with taskId/description/kind/providerInstanceId/childThreadId; remaining fields and kind variants verified-from-source; id/label/status are lenient client compatibility fields, not observed live |
| `blockedOnThreadWait` | Optional boolean. Combined with a running runtime/activity status, indicates a thread waiting on other threads. | verified-from-source for meaning; present live (false on observed waiting parents) |
| `runtime` | Optional `{status}` accepted by the client. Sidebar view models use this; the observed shell instead carries top-level status/activityRunStatus and has no runtime object. | verified-from-source for sidebar; runtime object not verified live |

**inferred:** T3 Proxy's attention mapping is `.needsYou` if a pending runtime request exists (including nonblocking async questions), an actionable plan exists, guest messages await action, or a work child needs attention. Otherwise a nonempty task roster, a running status blocked on thread wait, or active child work yields `.waiting`. Waiting rows remain under RUNNING, contribute a separate footer count, and do not raise the orange attention dot. Preparing/queued/starting/running/plain waiting map to `.running`; completed/interrupted/failed/cancelled/rolled_back map to `.finished`; idle remains `.idle`; unknown remains `.unknown`. A plain `waiting` status does not prove that user input is required. Finished/failed notifications use the same family-aware mapping, so they wait until background work ends.

**verified-live:** a read-only shell subscription observed completed parents with null activityRunStatus, false blockedOnThreadWait, and nonempty subagent pendingBackgroundTasks. Delegated child threads used `lineage.relationshipToParent: "subagent"` and a nonempty `lineage.parentThreadId`. No real thread titles or identifiers were retained. The temporary session had exactly `orchestration:read`, was revoked after the probe, and was confirmed absent with `t3 auth session list --json`; no orchestration commands were dispatched.

**inferred:** explicit settlement (`settledOverride: "settled"`) excludes a thread before grouping, child-attention propagation, footer counts, orange-dot evaluation, and notifications. Stale child approvals or background summaries must not revive a settled thread. Settled children are excluded from the displayed family and its attention calculation; `settledOverride: "active"` remains eligible. This visibility policy is covered by synthetic tests.

**verified-from-source:** `ManagedEndpointRuntime-*.mjs` derives delegated child IDs with `joinId("thread", "delegated-task", commandId)`. `runtimeLayer-*.mjs` creates delegated children through `makeSubagentChildThread`, whose lineage carries parentThreadId, relationshipToParent `subagent`, and the parent's rootThreadId. The background roster schema supports subagent, command, monitor, and background_task kinds, with unknown kinds decoded compatibly. `backgroundWorkHoldsCompletion` holds completion for subagent/background_task or awaited work; unawaited command/monitor work does not hold server completion. T3 Proxy conservatively displays Waiting for any nonempty roster. Work children join by subagent lineage or roster childThreadId; ordinary forks and side chats are independent. Child deep links accept colon-separated IDs. Expansion shows one child level, summarizes deeper children, and reuses the existing confirmed Stop intent and revalidation.

**verified-from-source:** pending runtime request kinds include `command`, `file-read`, `file-change`, `mcp-elicitation`, `permission`, `dynamic_tool_call`, `user_input`, `auth_refresh`. The shell supplies only a summary; the projection's `runtimeRequests` contain `id`, `nodeId`, `kind`, `status` (`pending`, `resolved`, `expired`, `cancelled`), `responseCapability` (`live`, `message`, `not_resumable`), timestamps, optional decisions/answers/feedback. Turn items and `visibleTurnItems` carry approval/question presentation content. A shell client should use the summary for attention rather than expect question text there. This implementation does not render or answer approvals.

**inferred:** `isSnoozedByUsageLimit(at:)` conservatively requires a failed `usage_limit` run, future snooze, recovery `snooze: true`, matching latest run ID, and matching recovery/reset/snooze timestamps. A manual snooze on a limited thread does not prove that the usage-limit recovery setting created it. Older servers lacking recovery metadata cannot establish that origin; `isUsageLimited` and `isSnoozed` remain separately available.

## Sidebar elapsed clocks and child navigation (2026-11-07 source verification)

**verified-from-source, not verified live in this change:** `main-B_TH3rWH.js` sidebar row `tV` renders `FB({startedAt: od(w)})` for Working/Setting up and `FB({startedAt: w.latestRun?.completedAt ?? null})` for Waiting. `od` is `Sidebar.logic-BgQygiCz.js` export `Da`, which calls `utils-UzfXcrVu.js` `i0e`:

- If `runtime.activityStartedAt` is defined, use its valid timestamp (explicit null suppresses legacy fallback).
- Otherwise, only when `latestRun.completedAt === null` and `latestRun.runId === runtime.activeRunId`, use `latestRun.startedAt ?? latestRun.requestedAt` (valid dates only).
- Waiting uses latest-run completion, not the time work or the menu-bar app started. `latestUserMessageAt` participates in other sidebar logic, not this elapsed clock.
- `utils` shell adapter `n0e` maps `latestRunRequestedAt`, `latestRunStartedAt`, `latestRunCompletedAt` to the run view model. Adapter `e0e` maps `activityRunStartedAt` to `runtime.activityStartedAt` and passes `activeRunId`. Pending work can give the runtime an idle/waiting presentation. Old shells missing `latestRunCompletedAt` synthesize completion from `updatedAt` for idle/terminal runs.
- `FB` parses the timestamp; `IB` subtracts it from the live clock. Formatter `utils.a0e` floors seconds, clamps negative durations to zero, and produces `42s`, `17m`, `1h 5m` (hours remain hours even beyond a day).

**inferred client policy:** T3 Proxy decodes all four timestamp fields as optional and tolerates malformed new timestamp values. Parent and child rows use the Working/Waiting clock appropriate to their row status. When no usable shell clock exists, use the persisted first-seen fallback, including on older shells, rather than treating mutable `updatedAt` as a run clock. Explicit null activity start does not revive a stale latest-run start.

**verified-from-source:** desktop `main.cjs` `promptLinkAppPath` accepts `t3code://threads/<environmentId>/<threadId>` (optional trailing slash) and returns `/<environmentId>/<threadId>` with `url.search` preserved. The `open-url` handler passes accepted links through `openAppLink`. The web alias `/threads/$environmentId/$threadId` redirects to `/$environmentId/$threadId` with search preserved. The canonical thread route has no subagent-selector search validator. `_chat`'s related-thread handler navigates to that canonical route; the special local panel opening in `useTimelineFollow` `Dc` is for `lineage.sideChat`, not subagents. Native workflow member `PB` disables opening when `childThreadId` is null; materialized child IDs can navigate as threads. No supported deep-link query selecting a native member within its parent was found.

**inferred client policy:** app-owned delegated children open their own thread URL. Native child shells are identified by `creationSource: "provider"` plus subagent lineage (`runtimeLayer.makeSubagentChildThread` sets this source for provider-native work); T3 Proxy opens their immediate parent to expose its native subagent content, without inventing a query parameter. This is a parent fallback, not an exact member-selection deep link. Roster-only work opens `childThreadId` when available or its displayed parent otherwise. Every destination still passes the existing identifier validation. No URL was opened in the running app, and no temporary session was issued for this change.

## Stop and immediate limited-thread resume

**verified-from-source; synthetic-tested, never dispatched live:** Stop uses `orchestration.dispatchCommand` with:

```json
{"type":"thread.stop","commandId":"sample-command","threadId":"sample-thread"}
```

**verified-from-source:** optional `reason` is a string. Optional `stopDelegatedTasks` defaults to cascading Stop to delegated tasks; this client leaves the default. Stop can hold queued work and disarm automatic limit recovery. It does not settle/archive a thread. Acceptance comes back as `{sequence}`; observe the shell for actual lifecycle changes.

**verified-from-source; synthetic-tested, never dispatched live:** immediate manual resume uses the latest failed limited run as a server-validated continuation source:

```json
{
  "type":"message.dispatch",
  "commandId":"sample-command",
  "threadId":"sample-thread",
  "messageId":"sample-message",
  "manualContinuationOfRunId":"sample-run",
  "text":"Continue where you left off.",
  "attachments":[],
  "dispatchMode":{"type":"start_immediately"},
  "createdBy":"user",
  "creationSource":"web"
}
```

**verified-from-source:** `web` is the existing first-party client creation source; this contract has no `native`/`client` source literal. The server checks that the source is the latest executed run, interrupted or failed with a usage-limit error, and that the thread is not archived/deleted and has no pending runtime request. T3 Proxy further restricts its `resumeLimited` helper to failed usage-limit rows without active work. The dispatch automatically clears snooze and unsettles the thread. This is one command, with fresh command/message IDs; there is no separate unsnooze race. It does not bypass the provider's actual quota and can fail at the limit again. The reset time need not have arrived for this explicit manual continuation.

**verified-from-source:** `thread.unsnooze` alone accepts `{type:"thread.unsnooze", commandId, threadId, reason:"user"}` and clears snooze metadata; it does **not** itself start a run. Automatic recovery uses different `message.dispatch` fields: `usageLimitContinuationOfRunId`, optional `usageLimitRecoveryRequestId`, `createdBy:"agent"`, `creationSource:"server"`. The recovery worker requires a matching armed recovery, `autoResume`, a reached reset deadline and no future snooze. `snoozeLimitedThreads` and `autoResumeLimitedThreads` settings govern arming. T3 Proxy does not change those settings or imitate automatic recovery for a resume-now action.

**inferred:** command calls return a sequence after acceptance, or a fixed typed error. Disconnect/cancellation/timeout can leave acceptance unknown; the client never retries a command on reconnect. Refresh and inspect the thread before a new user action. Local command guards are advisory; the server remains authoritative if state changes between snapshot and dispatch.

## Source anchors and verification boundaries

**verified-from-source:** extracted bundle source anchors (dist filenames change between releases):

- `apps/server/dist/server-B1M5L35A.mjs`: `src/ws.ts`, `src/auth/RpcAuthorization.ts`, shell snapshot/enrichment constructors, `withOutputWindow` wiring.
- `apps/server/dist/ManagedEndpointRuntime-DSAP4viz.mjs`: `packages/contracts/src/rpc.ts`, `orchestrationV2.ts`, `orchestrationProject.ts`, `modelSelection.ts`, `auth.ts`, `clientRpcPermissions.ts`.
- `apps/server/dist/runtimeLayer-CnRxiGLu.mjs`: Effect `RpcSerialization` / RPC server control framing, `src/terminal/OutputProtocol.ts`, manual-continuation validation and snooze clearing in `Orchestrator.dispatchMessage`, `src/orchestration-v2/UsageLimitRecoveryWorker.ts`.
- `apps/server/dist/relayTracing-BT_Sdm7u.mjs`: `parseBearerToken`, `selectRequestCredential`, `EnvironmentAuth.authenticateWebSocketUpgrade`.
- `apps/server/dist/binCli-2542kNaw.mjs`: `formatIssuedSession`, CLI scopes and revoke arguments.
- `apps/server/dist/client/assets/_chat-DgRjbjWK.js`: existing manual resume action using `manualContinuationOfRunId` and continuation text.

**verified-live:** independent read-only wire probe authenticated, subscribed, acknowledged the shell, read server configuration and one projection. A standalone Swift probe compiled only the new client/model/wire sources and decoded the real full list. It did not launch T3 Proxy, touch Keychain, dispatch a command, change settings, restart either app, or call the CLIProxyAPI management API. Every temporary session was revoked and its absence checked through the CLI. No live payloads were saved as fixtures.

**inferred:** automated coverage uses synthetic JSON and an in-memory socket: status/unknown-field decoding, attention, limit-snooze origin, schema/protocol rejection, enrichment merge, archive/removal, frame batches, ping/ack handling, command receipts/rejection, and fresh subscription without replay after a lost command reply. Keychain access, stop/resume provider execution, redirect refusal on a real upgrade, heartbeat timeout timing, and long-running production reconnection remain unverified live.
