# 05 — Implement Exact Select and View Ownership Transfer

**What to build:** Make source-window selection install files and directory children into exact destinations, transfer or detach managed View ownership correctly, and hide the source only after destination commit.

**Blocked by:** 02 — Establish Tab-Local Active Views; 04 — Decouple Instance Lifecycle and GC from View Visibility.

**Status:** ready-for-human

- [x] The default destination is the exact source window captured by the action, and an explicit target is validated before file-buffer or child-Instance mutation.
- [x] Source hiding defaults to false and affects only the source Instance's View in the captured source tab after a successful destination commit.
- [x] Installing a file into a managed target removes stale Fre ownership, while installing into an ordinary target leaves an ordinary file window.
- [x] Installing a directory child into a managed target transfers its requested layout, origin, and close-or-restore behavior from the previous owner.
- [x] Installing a directory child into an ordinary target creates one restoring child View whose loading state appears immediately.
- [x] A child load failure remains installed and visibly reports failure rather than restoring the parent.
- [x] Pre-commit failures clean action-created resources and preserve the source; post-commit focus or source-hide failures do not trigger editor-wide rollback.

**Internal View APIs added (view.lua):** `owner`, `detach`, `transfer`, `adopt` — ownership-only; no visibility/GC/global-index leakage.

**Production changes:** `lua/fre/view.lua`, `lua/fre/actions.lua`.

**Tests:** 13 new focused select cases in `tests/actions_mappings_spec.lua`; actions 32/32, window-layout 20/20, destroy/GC 29/29, full 24-spec suite exit 0.
