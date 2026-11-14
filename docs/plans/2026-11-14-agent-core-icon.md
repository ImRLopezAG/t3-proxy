# Animated agent core menu bar icon

## Goal and decisions
Replace the single menu bar glyph with an 18pt native holographic sphere: circuit arcs, tilted rings and a bright core. Preserve clicks, attention, quota titles and menu geometry. Idle uses a template image. Active uses blue/cyan/ice-white, gentle breathing and rotation. Waiting uses an orange orb without a dot; bounded errors use red with streaming-like energy. Subagents add a sweeping highlight; reports pulse for 1.6s; observed turn completion expands/fades/reassembles. Reduce Motion uses static colors only, with no dot. No idle animation timer.

The existing orchestration.subscribeShell contract supplies thread summaries, not text deltas. Working, subagent, approval/question and terminal transitions are supported. Streaming artwork can be previewed but must never be inferred from running. No new server subscription, authentication or proxy routing changes.

## Implementation units
1. Pure activity reducer: aggregate visible thread families, strongest current activity, attention, and run-bound one-shot overlays. Seed initial/reconnected snapshots quietly; ignore stale sequence, snoozed/settled/archived/deleted work. Characterize with failing tests first.
2. Native AppKit/Core Animation renderer and status-button integration. Static template idle, active layer animations only, dynamic Reduce Motion and appearance, accessibility status. Preserve existing title modes and click targets. Native layer tests and offscreen diagnostic previews replace browser testing for this macOS surface.
3. Verify complete suite and release package; capture synthetic labeled state stills or a short native animation recording. Inspect live menu bar without altering agent work or restarting the hub. Review correctness, implementation and security; resolve findings; commit only owned files locally.

## Verification and completion
Tests cover concurrency, child completion, run deduplication, reconnect, visibility and waiting/error handling. Native checks cover no idle animations, Reduce Motion, active states, click geometry and accessibility. Preview captures demonstrate every visual state but are not live event proof. Document supported event evidence separately from runtime observations. Preserve existing accounts, connected tools, isolated profiles and the live CLIProxyAPI process.

## Reference
Motion and palette: /Users/angel/.t3/scratch/2026-11-14-https-x-com-theo-status-0e4beb91/holo/index.html. Simplify the provided gold circuit sphere at menu bar scale. Local commit only, no push or release publishing.

## User-requested addition: reset access while routing is paused
The reported account has weekly quota exhausted and 5-hour capacity remaining, but Team guard has disabled its routing. Existing reset controls, credit reads and manual reset confirmation reject disabled accounts. Keep banked reset access independent from routing: read Codex quota/credits for paused accounts, show explicit unavailable/zero states, and allow a deliberate confirmed reset bound to the account's routing state. Never enable routing as a side effect. A changed routing state invalidates the confirmation. Existing default disabled-read/confirmation guards and automatic reset-and-resume exclusions remain. Actual provider credit availability determines eligibility; four days remaining alone is not sufficient proof. No live credit will be consumed during QA.

## Review corrections
The first source review found completed background rosters could keep a finished parent animated, and a routing toggle could strand an uncertain reset retry. The reducer now uses active status and filtered roster entries. A fresh deliberate confirmation can bind an uncertain reset to the current routing state while preserving its original credential, credit and request ID. Regressions cover both cases; source re-review is separate from native acceptance.

## Artwork revision
Opus 5.5 through Claude Proxy produced the accepted layered hologram structure. Native perspective projections of broken translucent shells use blue as the main palette, red error energy, and an orange Needs you orb without a dot. Report draws energy inward into a core bloom; finish opens the shells and reassembles them. Core Animation plays cached frames with no app-side frame timer. Synthetic previews demonstrate the artwork separately from live event behavior.
