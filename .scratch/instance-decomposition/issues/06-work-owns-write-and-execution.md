# 06 — Let Work own writes and execution

**What to build:** Preserve the normal buffer-edit, prepare, confirm, execute, and reconcile workflow while making Work the owner of write capability, prepared actions, mutation execution, and write results, leaving Instance as the public facade and top-level orchestrator.

**Blocked by:** 03 — Let Lifecycle own readiness and destruction; 05 — Let Sync refresh, reconcile writes, and watch directories

**Status:** resolved

- [x] Work owns write capability, prepared actions, confirmation and progress phase state, active execution, post-write reconciliation, cleanup, and the last write result without receiving or retaining Instance.
- [x] Work exposes semantic operations for caller-controlled prepare and execute plus one complete normal buffer-write workflow; it does not expose each internal phase as Instance forwarding methods or a public transaction protocol.
- [x] Work collaborates explicitly with Tree, Buffer, Sync, mutation adapters, and narrow UI operations only for the complete write and execution workflows it owns.
- [x] The UI dependency displays confirmation and progress and returns decisions, while Work owns phase ordering, capability lifetime, execution startup, terminal handling, reconciliation, Buffer restoration, and result publication.
- [x] `actions.write` collects the documented editor context and dispatches the write request but no longer stores the token, owns write phases, invokes private Instance phases, or records the result.
- [x] Normal `:write`, simple-edit confirmation bypass, explicit confirmation, cancellation, successful mutation, partial mutation failure, startup failure, and post-write reconciliation preserve their documented behavior.
- [x] Work invokes Sync through one semantic write-reconciliation operation and does not depend on Sync candidates, watcher state, request objects, or rollback phases.
- [x] Low-level direct `prepare()` and `execute()` remain caller-controlled. Work does not coordinate them with unsupported simultaneous refresh or incompatible UI operations.
- [x] Instance retains documented public methods and validation, Manager interaction, navigation commands, presentation commands, child composition, and genuine top-level resource orchestration, but no write workflow implementation or child-owned mutable state.
- [x] Obsolete generation fields, write locks in Instance or Actions, guards that only support excluded concurrency, compatibility aliases, generic dispatchers, transaction/lease protocols, and shallow forwarding methods are removed rather than relocated.
- [x] Tests exercise Work's supported workflow through its interface with the existing mutation and UI test adapters; tests do not inspect tokens or recreate internal phase ordering in callers.
- [x] Every remaining Instance field and method has a clear public-facade or top-level-resource-orchestration purpose.
- [x] The full suite passes for supported workflows, Instance is approximately 700 to 900 lines, and any remaining responsibility can be explained without introducing another state-owning child.
