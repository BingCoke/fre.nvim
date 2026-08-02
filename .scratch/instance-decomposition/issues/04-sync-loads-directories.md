# 04 — Let Sync load and rescan directories

**What to build:** Make new Instance loading, configured initial expansion, manual directory expansion, and directory rescanning run end to end through one Sync child from filesystem input to committed Tree and Buffer state.

**Blocked by:** 01 — Let Tree own filesystem topology; 02 — Let Buffer own projection state; 03 — Let Lifecycle own readiness and destruction

**Status:** resolved

- [x] Sync is created from explicit Tree, Buffer, filesystem adapter, scheduling, configuration, and narrow completion/reporting dependencies and never receives or retains Instance or a generic context bag.
- [x] Sync exposes named workflow operations for initial load, expansion, collapse, and rescan; filesystem callbacks, same-directory waiters, reconcile loops, candidate state, projection preparation, commit, and completion remain behind that interface.
- [x] Initial root loading and configured expansion complete before Lifecycle is marked ready through top-level Instance orchestration.
- [x] Initial load, manual expansion, and rescan use one Sync-owned filesystem-to-Tree-to-Buffer synchronization implementation rather than separate callback pipelines.
- [x] Sync prepares Buffer against the candidate topology, commits Buffer with Buffer-owned rollback on failure, and only then adopts the candidate through Tree's trusted non-throwing operation.
- [x] Tree candidates, Buffer prepared values, directory checkpoints, and request identity remain private to Sync's implementation and are not relayed through Instance forwarding methods.
- [x] Manual expansion and rescan preserve normal loaded, expanded, cached, projected, and stable-node behavior.
- [x] Ordinary filesystem, comparator, and projection failures follow the existing supported error paths without adopting failed candidates or adding machinery for malformed adapters or duplicate completions.
- [x] Instance initiates public workflows, coordinates Lifecycle completion, and handles documented public results but no longer implements filesystem callbacks, directory reconcile loops, candidate adoption, or projection rollback.
- [x] Old initial-load and directory-load implementations are deleted in the same change; no dual request state, compatibility mirror, generic request dispatcher, or forwarding wrappers remain.
- [x] Focused tests exercise complete loading and expansion outcomes through Sync or Instance with the existing filesystem test adapter; the full suite passes and Instance is materially smaller.
