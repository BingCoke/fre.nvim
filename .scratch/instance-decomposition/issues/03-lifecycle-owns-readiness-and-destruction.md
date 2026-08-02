# 03 — Let Lifecycle own readiness and destruction

**What to build:** Preserve normal loading, ready notification, load failure, retry, and destruction behavior while making Lifecycle the sole owner of an Instance's lifetime state.

**Blocked by:** None — can start immediately

**Status:** resolved

- [x] Lifecycle owns creating, ready, load-failed, destroying, and destroyed state together with the associated error and ready observers.
- [x] Lifecycle exposes named semantic operations for beginning and completing load, observing readiness, beginning destruction, and finishing destruction; it does not receive or retain Instance.
- [x] Lifecycle hides observer ordering, already-resolved callback scheduling, retry transitions, callback error handling decisions, and pending-observer completion.
- [x] Instance performs Neovim, Manager, Buffer, Sync, Work, and other resource effects in top-level order, while Lifecycle performs only state transitions and observer dispatch decisions.
- [x] `when_ready` observers preserve their ordering relative to the `FreReady` autocmd and preserve the documented synchronous-versus-scheduled behavior.
- [x] Normal initial success, ordinary load failure, refresh-based retry, `when_ready`, constructor cleanup, external buffer deletion, and explicit destruction preserve their documented behavior.
- [x] The interface does not expose load tickets, destruction tickets, a generic transition dispatcher, or a general admission, cancellation, concurrency, or generation framework.
- [x] Instance contains no lifecycle field mirrors or private compatibility aliases after migration.
- [x] Tests exercise documented lifetime outcomes and observer ordering through Lifecycle or Instance rather than inspecting old state fields; the full suite passes independently of the Tree and Buffer tickets.
