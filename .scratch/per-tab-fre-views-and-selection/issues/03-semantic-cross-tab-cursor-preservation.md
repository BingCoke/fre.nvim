# 03 — Preserve Semantic Cursors Across Shared Projection Changes

**What to build:** Keep every managed active View on the same semantic Entry and approximately the same viewport position when another View expands, collapses, sorts, filters, reveals, or refreshes the shared projection.

**Blocked by:** 02 — Establish Tab-Local Active Views.

**Status:** ready-for-human

- [x] Projection updates capture transient snapshots only for valid managed active Views and never retain cursor snapshots in View state.
- [x] Surviving Entries are restored by full path at their new rows rather than by old row number.
- [x] Each View's topline follows the cursor row delta within valid Neovim bounds so its relative viewport position is approximately preserved.
- [x] A missing Entry falls back to the nearest surviving ancestor and then to the root or first valid Entry.
- [x] Restoration works in non-current tabs without changing the current tab or stealing focus.
- [x] Snapshot decoding, path resolution, fallback, invalid-window, or cursor/view API failures silently skip only the affected View, leave its natural post-update position untouched, continue restoring other Views, and do not roll back the projection.
- [x] Reveal expands shared tree state but moves a cursor only in an active target-tab View; revealing while hidden creates no later cursor jump.
- [x] Manually duplicated unsupported Fre-buffer windows receive no managed cursor-preservation guarantee.
