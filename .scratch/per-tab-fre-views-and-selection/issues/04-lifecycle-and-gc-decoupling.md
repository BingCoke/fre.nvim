# 04 — Decouple Instance Lifecycle and GC from View Visibility

**What to build:** Represent Instance readiness independently from presentation visibility, prune stale managed Views with a small per-Instance path, and preserve actual-buffer visibility as the final destruction guard.

**Blocked by:** 02 — Establish Tab-Local Active Views.

**Status:** ready-for-human

- [x] Ready Instances expose one readiness state regardless of whether zero, one, or several tab-local Views are active.
- [x] Managed window close, buffer replacement, or tab removal schedules a prune that removes only stale entries from the affected Instance.
- [x] Final managed hide or prune starts the normal hidden interval, and opening any managed View clears it.
- [x] TTL and capacity GC defer destruction whenever any real Neovim window still displays the Fre buffer, including unsupported native duplicates.
- [x] Explicit destruction cleans every active View and lifecycle resource without retaining View, layout-history, or pending-cursor state.
- [x] Existing unrelated load, refresh, watcher, write-lock, execution, and external-buffer-deletion synchronization generations remain intact.
- [x] Public lifecycle integration tests pass without visibility-specific ready state names.

**GC capacity correction (2026-07-30):**

- [x] Capacity enforcement compares total live registered group occupancy, not eligible-candidate count.
- [x] `creating` and `load-failed` instances consume group capacity but are never eligible for TTL/capacity destruction (`is_eligible` requires `state == "ready"`).
- [x] Hidden `creating` Instance triggers deferred GC reconsideration after transitioning to `ready`, converging over-capacity groups.
- [x] Asymmetric capacity regression: capacity=1 with one visible Instance and one hidden eligible Instance destroys only the hidden one.
- [x] Unsupported native duplicate close path: real `nvim_win_close()` on a duplicate window triggers eventual reconsideration and destruction of the now-hidden eligible Instance while a visible protected Instance remains.
