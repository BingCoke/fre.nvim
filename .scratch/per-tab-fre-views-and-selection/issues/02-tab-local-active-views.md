# 02 — Establish Tab-Local Active Views

**What to build:** Replace ambient same-tab window selection with one active managed View per Instance per tab, with deterministic open, hide, toggle, inspection, and directory takeover behavior.

**Blocked by:** 01 — Extract Pure Layout Resolution and Exact Window Mechanics.

**Status:** ready-for-human

- [x] Repeated opens produce at most one managed View for an Instance in a tab while allowing independent Views in other tabs.
- [x] Opening a visible View without an override focuses it; the same explicit layout preserves window identity, cursor, and scroll; a different explicit layout performs one local relayout without leaving a duplicate.
- [x] Tab-local hide and binary toggle affect only the target tab, while the explicit global hide operation removes every active View.
- [x] Reopening a hidden View without an override uses the immutable Instance default rather than remembered per-tab layout history.
- [x] Current-position Views restore their prior buffer; Fre-created destinations close; an uncloseable final ordinary window receives a safe empty buffer.
- [x] Read-only View inspection returns a copied active window, requested layout, and origin snapshot, prunes stale ownership, and returns nil when no active View exists.
- [x] Native resizing changes live geometry without rewriting the requested layout reported by inspection.
- [x] Default directory takeover enters the same managed ownership model and preserves its existing public success and failure behavior.
