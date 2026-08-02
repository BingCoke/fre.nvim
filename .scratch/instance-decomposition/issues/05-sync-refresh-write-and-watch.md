# 05 — Let Sync refresh, reconcile writes, and watch directories

**What to build:** Make normal manual refresh, forced refresh, write reconciliation, and watcher-driven updates share one Sync-owned filesystem-to-Tree-to-Buffer synchronization implementation.

**Blocked by:** 04 — Let Sync load and rescan directories

**Status:** resolved

- [x] Sync owns refresh and watcher request state, filesystem result, real root, dirty state, candidate scanning, Buffer commit coordination, Tree adoption, and watcher follow-up state.
- [x] Manual refresh, forced refresh, write reconciliation, presentation refresh, and watcher refresh reuse the same private synchronization implementation with only their supported target and completion differences.
- [x] Sync keeps candidates and prepared projections behind its interface: Buffer commits and internally restores on failure, then Tree adopts the successful candidate through a trusted non-throwing operation.
- [x] Watch is constructed and owned only by Sync and reports narrow `{ path, node_id }` events and errors to Sync without receiving, retaining, or calling Instance, Tree, Buffer, Lifecycle, or Work.
- [x] Watcher debounce and active-directory refresh reuse Sync's synchronization operations rather than adding a parallel filesystem-to-projection workflow.
- [x] Instance retains public refresh validation, the existing write orchestration, and presentation decisions during this phase, but does not retain scan queues, candidate state, adoption, rollback, watcher generations, filesystem result, real root, dirty state, or follow-up scheduling.
- [x] The existing write workflow invokes one semantic Sync write-reconciliation operation without receiving Sync's request objects, candidates, watcher state, or internal phases; Issue 06 later moves that complete caller workflow into Work.
- [x] Ordinary filesystem, projection, watch, and write-reconciliation failures preserve the documented Buffer and Tree behavior and leave Sync dirty when a supported follow-up is required.
- [x] Keep only request identity, changed-buffer checks, watcher debounce identity, destruction guards, and follow-up state required by normal asynchronous Neovim and filesystem callbacks.
- [x] Simultaneous direct execute and refresh, overlapping refreshes, incompatible UI-state calls, duplicate adapter completion, and hostile scheduler behavior remain unsupported and do not gain an admission, cancellation, transaction, or state-machine framework.
- [x] Old refresh, reconcile, and watcher implementations are deleted rather than wrapped; the pre-Work write caller may remain only as a temporary caller of Sync's semantic reconciliation operation, with no new Work forwarding module.
- [x] Focused refresh, write, watcher, and presentation tests use the existing adapters and the full suite passes.
