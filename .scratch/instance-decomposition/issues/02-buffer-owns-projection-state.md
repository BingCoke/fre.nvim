# 02 — Let Buffer own projection state

**What to build:** Preserve normal tree rendering, cursor placement, marker identity, highlights, and buffer cleanup while making the existing Buffer module the owner of one Instance's Neovim projection and editor resources.

**Blocked by:** 01 — Let Tree own filesystem topology

**Status:** resolved

- [x] Buffer is a state-owning child created from explicit identity, buffer, configuration, editor dependencies, and narrow named operation callbacks; it never receives or retains Instance or a generic handler/context table.
- [x] Buffer owns the committed projection, hidden-file presentation policy, semantic cursor intent, marker and extmark state, highlights, mapping bookkeeping, and buffer-scoped resources.
- [x] Extmarks, visible ranges, baseline rows, marker data, and other projection metadata are held in Buffer-owned state keyed by stable Tree node identity rather than written onto Tree nodes.
- [x] Buffer consumes Tree nodes and Tree identity through the Tree interface without duplicating or mutating topology state.
- [x] Buffer exposes semantic presentation and navigation operations. Projection prepare and commit may use an opaque prepared value, but snapshots and rollback phases remain hidden inside Buffer.
- [x] A failed commit restores Buffer's own Neovim lines, options, extmarks, highlights, cursor state, and committed projection before returning the operational error.
- [x] External buffer deletion requests top-level destruction through one narrow operation callback. Buffer does not call Instance methods or recover Instance through a closure or handler map.
- [x] Mapping setup and teardown, highlight attachment, cursor intent, and buffer autocmd resources become Buffer implementation or internal modules rather than separate Instance-owned workflows.
- [x] Normal render, projection prepare/commit/restore, cursor restoration, sorting, hidden-file toggling, marker-width changes, undo behavior, and external buffer cleanup remain unchanged.
- [x] Existing Actions, View, mapping, row rendering, and mutation preparation use Buffer's interface rather than reading projection state from Instance.
- [x] No separate Projection module, editor port for single-implementation Neovim primitives, compatibility mirror, or one-method forwarding layer is introduced.
- [x] Tests exercise supported projection and cleanup outcomes through Buffer or documented Instance behavior instead of private Instance fields; the full suite passes without Instance growing.
