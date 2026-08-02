# Separate Instance From Process-Wide Runtime Ownership

Status: ready-for-agent

## Problem Statement

Fre currently makes Manager both the process-wide owner of Instances and a dependency retained by every Instance. Manager constructs and indexes Instances, allocates global marker identity, supplies shared adapters, owns GC groups, and coordinates destruction. Instance then calls back into that same Manager for registration cleanup, cross-Instance lookup, marker widths, group migration, presentation-driven GC, adapter access, and child Instance creation. This produces a bidirectional dependency between Manager and Instance and spreads process-wide ownership across both modules.

The same ownership is also split across View and GC. GC stores some timers and policy, while group, TTL, modified-buffer policy, timer generations, and hidden-interval state are copied into Instance configuration, Instance fields, or Instance-owned buffer metadata. View reads those fields and calls through Instance to Manager. Actions creates a directory Instance through the source Instance's retained Manager, which suggests an ownership or lifecycle relationship between otherwise independent Instances. Buffer and Tree reach process-wide marker behavior through callbacks assembled by Instance rather than through the owner of marker identity.

For maintainers, the result is difficult to explain and change locally. Construction rollback, normal destruction, external buffer cleanup, Registry removal, GC removal, presentation, and group migration must all preserve several implicit reverse calls. Replacing those calls with Manager-specific injected closures would retain the same dependency under different syntax and would not solve the architectural problem.

## Solution

Instance is Fre's public core module, not a child or implementation detail of Manager. It can construct, load, present, edit, refresh, write, and destroy one filesystem Instance without any Manager or GC. Direct core users may use the built-in concrete adapters and default Registry, or supply the same explicit dependencies to build their own management layer. The absence of a Manager means only that process-wide conveniences such as managed lookup, GC groups, capacity, TTL, takeover, and `fre.set_group` are not applied.

Fre's top-level `fre.new(options)` remains the managed convenience path. Its user-facing options may contain both core filesystem-editor configuration and managed GC policy. The default Manager partitions those inputs before construction: only core configuration and explicit core dependencies reach the core Instance constructor, while GC receives the selected group and per-Instance policy directly. Manager records the returned Instance in its own managed indexes, enrolls it in GC, and observes later core facts through Neovim's `User` event API. Manager is one consumer of the core event contract, not a dependency, creator-only capability, or privileged callback target inside Instance.

The core constructor does not retain its incoming options table wholesale. It distributes durable core values to the child or facade that consumes them and discards construction-only values after they are applied. Caller-layer business metadata is kept by the caller in its own records keyed by stable Instance identity; it is not stored on Instance merely because it accompanied creation.

Registry is independent of Manager and supplies stable cross-Instance marker identity. It owns permanent Instance ID allocation, live marker sources, global marker widths, and foreign-marker source resolution, but it does not own or call Instance. A standalone Instance uses the default Registry unless an explicit Registry is supplied; custom managers may share another Registry across their Instances.

GC is an optional process-wide owner used by Manager. It owns group definitions, membership, capacities, per-Instance policy snapshots, TTL state, timers, generations, hidden intervals, deferred reconsideration, and eligibility in its own records keyed by Instance identity. GC may retain a managed Instance as a destruction subject and call its public `destroy()` operation. Instance has no Manager or GC reference, group field, GC policy field, GC runtime field, or GC metadata in its buffer, and remains fully usable when GC is absent.

External Instance side effects are published as named Neovim `User` events. The recommended starting vocabulary for the currently known integration facts is `FreInstanceCreated`, the existing `FreReady`, `FreInstancePresentationChanged`, `FreInstanceActivityChanged`, `FreInstanceDestroying`, and `FreInstanceDestroyed`. Implementation may add, split, or consolidate named events when a complete supported workflow demonstrates that a different fact boundary is needed. The final vocabulary and payloads must remain finite, explicit, serializable, and documented; observers never receive Manager commands or determine whether the core transition commits. Event dispatch is protected so an autocmd failure is reported without rolling back committed Instance state.

The complete target graph is:

```text
Public plugin integration
  fre/init.lua ───────────────> Manager.default
  fre/actions.lua ────────────> fre.new / public Instance methods / Window
  fre/view.lua ───────────────> Instance.inspect_view
  fre/takeover.lua ───────────> Manager
  fre/mapping.lua ────────────> managed lookup / public Instance methods

Optional process management
  Manager ────────────────────> Instance core
  Manager ────────────────────> Registry
  Manager ────────────────────> GC ─────────────> Instance.destroy
  Manager ────────────────────> Takeover
  Manager ──nvim User autocmds───────────────────┐
                                                 │
Standalone core                                  │
  Instance ──────────────────> Events ──User events┘
  Instance ├─────────────────> Lifecycle
           ├─────────────────> Tree ─────────────> Path
           ├─────────────────> Buffer ───────────> Row / Columns / Path / Window
           ├─────────────────> Sync ─────────────> Watch / filesystem adapter
           ├─────────────────> Work ─────────────> mutation / write-UI adapters
           └─────────────────> View ─────────────> Window / Layout
  Tree and Buffer ───────────> Registry marker identity
  Registry ──FreRegistryMarkerWidthsChanged─────> matching live Buffers

Extension boundary
  custom manager/plugin ──nvim User autocmds──> Instance identity/state facts
  custom manager/plugin ───────────────────────> public Instance methods
```

The Neovim event channel is an integration boundary and does not create a retained module reference from Instance back to Manager or third-party consumers. The public creation paths are `fre.new(options)` for default managed behavior and the core Instance constructor for standalone or custom-managed behavior. Actions always calls `fre.new(options)` with explicit caller overrides plus only the action-owned or current core values it must derive; it never copies GC policy, Manager affinity, Registry affinity, or arbitrary metadata from the source Instance. Group migration moves to `fre.set_group(instance, group)` and its Manager-owned implementation. The previous `instance:setGroup(group)` form is removed.

## User Stories

1. As a Fre maintainer, I want Manager to depend on Instance without Instance depending on Manager, so that the runtime ownership graph is one-way.
2. As a core user, I want to construct and use an Instance without Manager, so that I can embed Fre's filesystem editor in my own integration.
3. As a plugin author, I want to manage core Instances with my own policy, so that the default Manager and GC are conveniences rather than mandatory infrastructure.
4. As a core user, I want a standalone Instance to support loading, presentation, editing, refresh, writing, and destruction, so that core behavior is not degraded outside the default Manager.
5. As a core user, I want the absence of Manager to disable only managed lookup, default-explorer takeover, GC groups, capacity, TTL, and group migration, so that the boundary is explicit.
6. As a Fre maintainer, I want Instance to retain only its identity, durable effective core values needed by its facade, child references, and top-level orchestration, so that caller business metadata and child-owned configuration do not accumulate on the core object.
7. As a Fre maintainer, I want GC state to have one owner, so that eligibility and timer transitions can be understood in one module.
8. As a Fre maintainer, I want global marker identity to have one owner independent of Manager, so that standalone and managed Instances can share copied rows safely.
9. As a Fre maintainer, I want core construction to finish its local composition before a Manager registers it, so that rollback has a clear boundary.
10. As a Fre maintainer, I want a Manager to register the returned core Instance before asynchronous load completion can run, so that managed events cannot escape ownership.
11. As a Fre maintainer, I want constructor failure to clean only core resources acquired by that Instance, so that unrelated managed Instances remain unchanged.
12. As a Fre maintainer, I want allocated Instance IDs to remain permanently consumed after failed construction, so that stable markers are never reinterpreted.
13. As a Fre user, I want ordinary `fre.new` creation behavior to remain asynchronous and independent, so that the ownership refactor does not change normal use.
14. As a Fre user, I want `fre.get_instance` and ID lookup to return only currently live Instances registered with the default Manager, so that standalone or stale buffers are not silently claimed.
15. As a Fre user, I want destroying a managed Instance to remove it from every Manager index and GC group, so that no stale ownership remains.
16. As a core user, I want destroying a standalone Instance to release all of its local resources without requiring process-wide registration, so that standalone use does not leak.
17. As a Fre user, I want external buffer deletion or wipeout to complete the same terminal core cleanup as explicit destruction, so that editor actions do not leak runtime state.
18. As a Fre user, I want a failed buffer deletion during destruction to remain retryable, so that the Instance is not reported destroyed while its owned buffer remains.
19. As a plugin author, I want Instance creation, readiness, presentation, activity, and destruction published through Neovim `User` events, so that I can integrate without private callbacks.
20. As a plugin author, I want event payloads to contain stable serializable identity and state, so that my autocmd can resolve an Instance through my own manager or bookkeeping.
21. As a Fre maintainer, I want event observers isolated from committed core transitions, so that an external autocmd error cannot leave child resources half-transitioned.
22. As a Fre maintainer, I want the event vocabulary and payloads finite and documented, so that the event boundary does not become a generic command bus.
23. As a Fre user, I want visible managed Instances protected from TTL and capacity destruction, so that GC never destroys a buffer displayed in an actual Neovim window.
24. As a Fre user, I want the final presentation leave to begin one hidden interval, so that TTL behavior remains predictable across tabs and windows.
25. As a Fre user, I want repeated presentation synchronization to be idempotent, so that duplicate visibility observations do not reset TTL incorrectly.
26. As a Fre user, I want hidden managed Instances reconsidered when loading, refresh, writing, or execution activity changes, so that a newly eligible Instance does not remain indefinitely.
27. As a Fre user, I want GC group capacity enforcement to remain deterministic, so that the same eligible victims are selected under the same state.
28. As a Fre user, I want zero TTL and zero capacity to remain independently disabled, so that configuration semantics do not change.
29. As a Fre user, I want modified buffers protected according to the GC-owned policy snapshot associated with each managed Instance, so that later setup changes do not mutate existing policy.
30. As a Fre user, I want `fre.set_group(instance, group)` to validate default-Manager ownership and migrate the authoritative GC membership atomically, so that group ownership has one source of truth.
31. As a Fre user, I want group migration to preserve the current hidden interval and TTL timer, so that migration does not extend an Instance's lifetime.
32. As a Fre user, I want migration into an over-capacity group to protect the moved Instance during immediate enforcement, so that a successful move does not immediately destroy its subject.
33. As a Fre user, I want migration failures to restore the previous GC-owned membership and policy record, so that the operation is atomic without mutating core configuration or buffer metadata.
34. As a Fre maintainer, I want group definitions, live membership, and per-Instance GC policy owned by GC maps keyed by Instance identity, so that Manager and Instance do not duplicate group state.
35. As a Fre user, I want a foreign marker to resolve only while its source marker record is live and its referenced node still exists, so that copied rows cannot silently change meaning.
36. As a Fre user, I want a destroyed or unregistered foreign source rejected with the target row identified, so that invalid copied content produces an actionable error.
37. As a Fre user, I want marker widths to expand globally within a shared Registry when Instance or node IDs require more digits, so that identity remains lossless across its live buffers.
38. As a Fre user, I want marker-width expansion published to every affected live Buffer without changing semantic content, so that existing edits remain valid.
39. As a Fre maintainer, I want Tree and Buffer to collaborate with the concrete Registry identity interface, so that Instance does not forward process-wide operations.
40. As a Fre maintainer, I want Sync to receive concrete filesystem and watch adapters at construction, so that it does not query Manager dynamically.
41. As a Fre maintainer, I want Work to receive concrete mutation and write-UI adapters at construction, so that its complete workflow remains local.
42. As a core user, I want built-in production adapters to work by default and explicit adapters to remain available, so that standalone use is practical and deterministic tests remain possible.
43. As a Fre user, I want selecting a directory to create an independent Instance through `fre.new`, so that source and destination Instances have no implied parent-child lifecycle.
44. As a Fre user, I want directory selection to derive its root and expanded paths plus the source's current sort and hidden-file behavior when not explicitly overridden, so that navigation behavior remains unchanged without inheriting source management policy.
45. As a Fre maintainer, I want Actions to use the same managed creation path as plugin users, so that there is no Actions-only constructor or hidden affinity contract.
46. As a Fre user, I want pre-commit selection failures to destroy a prepared directory Instance through its normal public lifecycle, so that cleanup follows one path.
47. As a Fre user, I want a committed directory child to survive independent of its source Instance, so that hiding or destroying the source does not destroy the destination.
48. As a Fre maintainer, I want takeover creation and lookup to remain default-Manager integration, so that standalone core does not acquire editor-wide policy.
49. As a Fre maintainer, I want every Instance-private module located under the Instance directory, so that the core boundary is visible from the filesystem.
50. As a Fre maintainer, I want View to own per-tab mutable View records as an Instance child, so that Instance does not retain presentation state that belongs to View.
51. As a Fre maintainer, I want external Actions, mapping, takeover, the public View facade, shared Window mechanics, Manager, Registry, and GC modules outside the Instance directory, so that core and integration ownership remain distinguishable.
52. As a Fre maintainer, I want child modules to retain their existing complete responsibilities, so that this refactor does not pull Tree, Buffer, Sync, Work, or View workflows back into Instance.
53. As a Fre maintainer, I want private tests coupled to old Manager, Instance, and GC fields replaced by interface, event, or workflow assertions, so that ownership can change without compatibility mirrors.
54. As a Fre maintainer, I want no private-field aliases, callback bags, or transitional dual state, so that the finished architecture contains one ownership model.
55. As a Fre user, I want existing creation, navigation, editing, writing, refresh, watcher, presentation, selection, and destruction workflows to remain supported, so that the refactor is behavior-preserving apart from the documented group API change.
56. As a custom manager author, I want to associate my own policy and business metadata with an Instance in my own identity-keyed records, so that the core object does not become a storage bag for integration concerns.
57. As a Fre maintainer, I want managed creation to resolve core configuration separately from GC enrollment policy, so that each owner receives only the data it uses.
58. As a Fre maintainer, I want construction-only options discarded after their owning component applies them, so that Instance does not retain data solely because it appeared in the creation call.
59. As a core user, I want passing data through my own management layer to remain that layer's responsibility, so that standalone Instance does not need speculative validation for fields that have no core meaning.

## Implementation Decisions

- Instance is a public standalone core module. Manager may require and retain Instances; Instance must not require, retain, call, or receive a command callback into Manager or GC, and it must not retain process-management policy on their behalf.
- The top-level Fre facade uses the default Manager for managed creation and lookup. Direct core construction bypasses Manager and therefore does not participate in default managed lookup, takeover, GC, or group migration.
- The core constructor accepts only core filesystem-editor configuration plus explicit named Registry and adapter dependencies. Omitted dependencies use built-in production defaults. It selects and distributes the values required by Instance and its children rather than copying the whole caller options table. GC-shaped or otherwise unrelated caller fields have no core ownership meaning; this boundary does not require the constructor to reject them or require negative tests for passing them.
- Core configuration is retained only where it has durable runtime meaning. Values needed only to initialize buffer options, buffer variables, mappings, or another child are applied or handed to that owner and are not retained on Instance after construction. Mutable configuration whose lifetime follows a child belongs to that child.
- Core construction resolves identity, creates the Buffer and private children, registers the marker source with the selected Registry, starts asynchronous initial loading, publishes `FreInstanceCreated`, and returns the Instance. A failure before return cleans core-owned resources and never triggers Manager or GC rollback.
- Managed creation resolves two products from the public options: effective core configuration and a GC enrollment policy. GC resolves and validates its policy, including the selected group, before core construction. Manager calls the same core constructor as standalone users, atomically adds the returned Instance to its ID and buffer indexes, and registers the Instance plus the resolved policy with GC before control returns to Neovim's event loop.
- GC registration records membership and its complete per-Instance policy/runtime entry without destructive capacity enforcement. Successful Manager registration is the managed creation commit boundary. Capacity enforcement then runs protected after commit; it cannot reject `fre.new` or hide the committed return value. Enforcement failure preserves the registered Instance and any retryable victim state, reports asynchronously, and never rolls managed creation back.
- Manager owns only the live Instance indexes needed by its convenience lookup API, core and integration setup defaults, selected adapters, lifecycle autocmd registrations, and top-level composition. GC owns effective GC defaults, group definitions, capacities, membership, policy snapshots, and runtime state. Neither duplicates the other's records; Manager does not own marker identity or Instance child state.
- Registry is independent of Manager. It owns a stable process-local `registry_id`, permanent Instance ID allocation, consumed IDs, marker-source liveness, Instance and node marker widths, and marker-width generation. It stores the narrow marker-source contract required for foreign-marker resolution, not an Instance reference or Instance workflow capability.
- A default Registry makes standalone construction immediately usable. A custom manager may provide another shared Registry; Instances can exchange foreign markers only when they share that Registry.
- Tree reports allocated node identity through the Registry contract. Buffer registers and removes its marker source, reads current widths, resolves foreign sources, and reacts to Registry marker-width events. Instance does not forward these operations.
- A foreign marker is valid only while Registry contains its live source record and the source marker contract still resolves the referenced node. Destruction removes the source record before `FreInstanceDestroyed` is published.
- Registry publishes `FreRegistryMarkerWidthsChanged` after committed marker widths increase. Its serializable data contains `registry_id`, `instance_width`, `node_width`, and `generation`. Emission is scheduled and coalesced to at most one event per Registry per Neovim loop turn; the payload contains the latest committed widths when it runs.
- Every Buffer retains the serializable `registry_id` and last applied marker-width generation for its selected Registry. It ignores width events for other Registries and stale generations, then reads or applies only the matching committed widths. Registry never calls Buffer or retains a Buffer workflow capability merely to fan out width changes.
- GC owns group definitions, capacity configuration, membership indexes, and one per-Instance entry keyed by stable Instance identity. The entry contains the managed Instance reference and buffer identity needed for eligibility and destruction, current group, snapshotted TTL and modified-buffer policy, hidden timestamp, timer state, generations, deferred reconsideration, and other GC-only runtime state.
- GC retains only managed Instances as membership subjects and may call public `Instance.destroy()` for an eligible victim. GC does not retain or call Manager; Instance does not know whether GC exists. GC reads core facts through public Instance state and Neovim buffer/window APIs, not through policy fields injected into Instance.
- Actual Neovim buffer visibility remains the final GC eligibility guard immediately before destruction. Presentation events optimize hidden-interval tracking but do not override editor truth.
- Ticket 04 finalizes six finite Instance `User` events: `FreInstanceCreated`, `FreReady`, `FreInstancePresentationChanged`, `FreInstanceActivityChanged`, `FreInstanceDestroying`, and `FreInstanceDestroyed`. No other Instance event names or generic event dispatcher are part of this contract.
- `FreInstanceCreated` is emitted synchronously after core composition, marker-source registration, and successful initial-load invocation, before the creation call returns. Its data is exactly `{ instance_id, bufnr }`; both values are positive numeric identities, and a managed consumer can resolve the returned Instance through its own bookkeeping.
- `FreReady` is emitted once for each completed initial-load attempt after Lifecycle commits `ready` or `load-failed`, before the creation/refresh completion returns to its caller, and after queued `when_ready` observers have run. Its data is exactly `{ instance_id, bufnr, error, result }`, where `error` is nil or a serializable error value and `result` is nil or the serializable load result.
- `FreInstancePresentationChanged` is emitted only when actual presentation changes between no displayed Instance window and at least one displayed Instance window. Its data is exactly `{ instance_id, bufnr, visible }`, with `visible` a boolean. Repeated synchronization at the same visibility is idempotent and emits nothing.
- `FreInstanceActivityChanged` is emitted when one of the supported activity kinds changes between inactive and active, or active and inactive. Its data is exactly `{ instance_id, bufnr, activity, active }`, with `activity` one of `refresh`, `write`, or `execution`, and `active` a boolean. Full refresh, write lock, and execution boundaries are reported; watcher-only refreshes are not a new activity kind.
- `FreInstanceDestroying` is emitted after Lifecycle commits `destroying` and before local resource cleanup. Its data is exactly `{ instance_id, bufnr }`, and the buffer identity remains valid at this boundary.
- `FreInstanceDestroyed` is emitted after local resources, buffer teardown, Manager indexes, and Registry marker-source registration reach their terminal state. Its data is exactly `{ instance_id, bufnr }`; the buffer may no longer be valid and the Instance is no longer discoverable through managed lookup.
- Every event uses protected `nvim_exec_autocmds("User", { pattern = ..., modeline = false, data = ... })` dispatch. Autocmd observer failures are detected from the protected call and Neovim's `v:errmsg`, reported asynchronously, and never reject or roll back the committed transition.
- Event data contains only stable numeric, boolean, string, nil, and recursively serializable result values. It never contains Manager, GC, callbacks, command names, an Instance table, or a Buffer table; consumers resolve identity through their own bookkeeping. `FreRegistryMarkerWidthsChanged` remains a separate Registry-owned fact.
- `fre.set_group(instance, group)` is the public default-Manager migration command. Manager validates that the Instance is in its indexes and delegates the complete atomic membership workflow to GC.
- The documented `instance:setGroup(group)` interface is removed without a compatibility alias. A standalone or custom-managed Instance has no intrinsic group operation or group field.
- GC group migration atomically updates only the GC-owned per-Instance entry and source/target membership indexes. It preserves the entry's policy snapshot, hidden interval, timer, and generations; enforces target capacity with the moved Instance protected; and restores the previous GC-owned membership state on ordinary failure. Instance configuration and buffer metadata are never part of the transaction because they contain no GC data.
- Actions starts from a defensive copy of explicit caller-provided child options, owns and replaces root and expanded paths, and derives current sort and hidden-file behavior only when those values were not overridden. It calls `fre.new(options)` and must not call a source Instance's Manager, invoke an Actions-specific creator, or derive the source's GC policy, Registry, Manager affinity, or arbitrary metadata. Explicit managed options supplied by the action caller continue to flow to `fre.new`, where the default Manager and GC resolve them.
- Actions may use the shared policy-free Window module to create exact tab and split destinations and install buffers. Window remains outside Instance because both Actions and private View use it; it owns mechanics and never owns View or action policy.
- The public Instance presentation operations used by Actions are `inspect_view(tabpage?)`, `release_view(winid)`, `take_view(source_instance, winid)`, `adopt_view(winid, presentation)`, and `place_initial_cursor(winid)`. They delegate complete ownership changes or cursor behavior to private View/Buffer children rather than exposing child tables.
- `release_view` detaches a committed target from its previous Instance for file installation. `take_view` transfers an existing managed View from source to child. `adopt_view` records an ordinary or newly created destination using explicit presentation policy. These operations preserve the commit and rollback semantics of the per-tab View spec.
- The top-level `fre.view.inspect(instance, tabpage?)` contract remains public. Its facade calls `instance:inspect_view(tabpage)` and never imports or returns private View state.
- Two Instances involved in directory selection are independent peers. The derived root, expanded paths, comparator, and hidden-file value do not create parent-child ownership, lifecycle propagation, shared private runtime identity, or inherited management policy.
- Selection rollback destroys a prepared child through the normal public Instance lifecycle. Post-commit source hide or destruction has no automatic effect on the committed child.
- Default-explorer takeover remains outside core and is coordinated by the default Manager. It creates through `fre.new`/Manager composition and resolves only Manager-registered ownership.
- View is an Instance child and solely owns active per-tab View records, previous presentation state, opening, hiding, toggling, inspection, transfer, and pruning. This explicitly supersedes the per-tab View spec statement that active records live in `Instance._views`; all accepted per-tab behavior remains unchanged.
- Instance retains documented identity, only the durable effective core values required by its own facade, private child references, and top-level orchestration state that cannot belong to a child. It does not retain an omnibus creation-options or effective-config copy. Child-specific durable values live with the child that consumes them; construction-only values are discarded after application. Instance retains no active View map, Manager affinity, group, GC policy or runtime field, adapter getter, caller business metadata, or external observer.
- Sync receives concrete filesystem and watch adapters at construction. Work receives concrete mutation and write-UI adapters at construction. Existing production and deterministic test implementations remain the reason these seams exist.
- External Actions and mappings use the named public Instance operations, shared Window mechanics, or public Fre lookup. They do not require Instance-private child modules merely to reach private state.
- The implementation removes superseded fields, forwarding methods, callback bags, and tests in the same migration. No compatibility mirrors or old/new ownership paths are allowed.
- This spec supersedes the prior Instance decomposition decisions that Instance retains Manager and that child files remain at the top-level module directory. It also supersedes only the per-tab View storage location noted above. The earlier specs' deep responsibilities, supported behavior, and rejection of shallow forwarding modules otherwise remain authoritative.

## Module And File Layout

- `lua/fre/instance.lua` is the public standalone core constructor and facade.
- `lua/fre/instance/events.lua` owns the finite Neovim `User` event contract and protected emission.
- `lua/fre/instance/lifecycle.lua` owns creating, ready, load-failed, destroying, and destroyed transitions plus `when_ready`.
- `lua/fre/instance/tree.lua` owns filesystem topology, node identity, expansion, sorting, and candidates.
- `lua/fre/instance/buffer.lua` owns the Fre buffer, projection, marker source, extmarks, core identity and projection metadata, cursor intent, and buffer-local resources. Its metadata contains no GC group, TTL, capacity, modified-buffer policy, Manager affinity, or other process-management data.
- `lua/fre/instance/row.lua` owns row encoding, decoding, ranges, and marker representation used by Buffer.
- `lua/fre/instance/sync.lua` owns initial load, directory load, refresh, reconciliation, dirty state, and synchronization candidates.
- `lua/fre/instance/watch.lua` is Sync's private watcher owner.
- `lua/fre/instance/work.lua` owns preparation, write confirmation, execution, write locking, and reconciliation.
- `lua/fre/instance/view.lua` owns active per-tab View records and complete presentation workflows.
- `lua/fre/window.lua` remains the shared exact policy-free Neovim window mechanics used by private View, private Buffer, and external Actions.
- `lua/fre/view.lua` remains the public `fre.view.inspect` facade and delegates only through `Instance:inspect_view`.
- Shared core dependencies remain outside the private directory: core configuration resolution, layout normalization, columns, paths, Window mechanics, filesystem adapters, mutation implementations, write UI, and Registry. Managed GC policy resolution belongs with GC rather than being folded into a core effective-configuration record.
- Plugin integration remains outside the private directory: Manager, GC, Actions, mappings, takeover, the public View facade, and the top-level Fre facade.
## Testing Decisions

- Good tests assert supported Fre behavior, the core Instance interface, named Neovim events, and owner interfaces. They do not assert private table layout, callback assembly, exact cleanup helper order, or unsupported interleavings. Ownership is proved through the public core/managed boundary and owner queries, not by preserving old fields as assertions.
- The primary seam is the public workflow exercised through both standalone core construction and default-managed Fre creation, lookup, group migration, Instance methods, exported Actions, and default-explorer takeover with real Neovim buffers, windows, tabs, autocmds, and filesystem fixtures.
- Standalone core workflow tests cover creation without Manager, readiness, presentation, editing, refresh, write, explicit and external destruction, built-in adapter defaults, explicit deterministic adapters, and absence from default managed lookup and GC. They do not require the core constructor to reject GC-shaped, unknown, or caller-owned fields solely to demonstrate the ownership boundary.
- Managed Instance workflow tests cover asynchronous creation, independent Instances, public lookup, registration after core construction, constructor cleanup, permanent ID consumption, GC enrollment with a separately resolved policy, and explicit destruction without an Instance Manager or GC field.
- Destruction and GC workflow tests cover lifecycle events, retryable deletion failure, visible-buffer protection, hidden intervals, TTL, capacity, modified-buffer policy, group migration, migration rollback, and cleanup through public outcomes.
- GC tests assert destroyed or surviving Instances, valid or deleted buffers, public lookup results, documented group-owner query results, policy behavior across later setup changes, and migration outcomes. They stop asserting `instance.config.gc`, `vim.b.fre.gc_group`, `hidden_since`, timer generations, Manager group tables, or other old/private state locations. Core metadata tests assert only the documented core identity and Registry facts.
- Event contract tests register real Neovim `User` autocmds and assert the final documented Instance event vocabulary, serializable payload fields, transition timing, idempotent presentation facts, activity facts, and protected observer-error reporting. They do not require the proposed six-event grouping when a ticket documents and tests a clearer finite grouping for the same supported workflows.
- Registry event tests assert the `FreRegistryMarkerWidthsChanged` name, Registry isolation by `registry_id`, committed width and generation payload, per-turn coalescing, stale-generation filtering, and protected observer-error reporting.
- A throwing event autocmd is the supported error-isolation case: the core or Registry transition must remain committed and the error must be surfaced asynchronously. Tests do not need malformed payload injection, recursive event mutation, or adversarial reentrant event choreography.
- Actions and mappings workflow tests cover directory creation through `fre.new`, shared Window destination creation, named Instance View ownership operations, action-owned root and expansion, fallback derivation of current sort and hidden-file behavior, explicit caller-managed overrides, absence of source GC-policy inheritance, preparation cleanup, destination commit, source independence, and the absence of leaked default-Manager registrations after pre-commit failure.
- Managed creation tests inject a capacity-enforcement destruction failure and assert that `fre.new` still returns the committed registered Instance, preserves retryable victim state, and reports the enforcement error asynchronously.
- Default-explorer workflow tests cover default-Manager takeover creation, managed lookup, constructor failure cleanup, and independent children without inspecting Manager index tables.
- Cross-Instance copy and Buffer identity tests remain the primary behavioral seam for shared-Registry foreign marker resolution, destroyed or unregistered marker sources, missing source nodes, marker widths, and semantic validation.
- A narrow direct Registry interface spec covers monotonic non-reused IDs, marker-source registration and removal, source resolution, Registry isolation, and marker-width generation where public UI behavior cannot prove the owner invariant precisely.
- A narrow direct Lifecycle interface spec covers readiness and destruction transition timing. Neovim event vocabulary belongs to the public core event seam rather than a second callback-observer interface.
- No new low-level GC test seam is introduced. GC policy remains verifiable through public managed workflows and the existing deterministic timer and Neovim seams.
- View behavior specs stop asserting `Instance._views` and verify View-owned presentation through public open, hide, toggle, inspect, transfer, and pruning outcomes.
- Tree, Buffer, Sync, Work, Watch, View, and mutation interface specs remain focused on their existing responsibilities. They are updated only for their new private module paths, Registry identity contract, concrete adapters, and event collaborator.
- Manager interface tests focus on default composition, managed indexes, separation of core configuration from managed policy, event filtering, GC delegation, and top-level commands. Registry identity rules and GC policy/group rules move to their owner or public workflow tests.
- Existing deterministic filesystem, watch, mutation, write-UI, and timer adapters remain valid test seams because each has a real production implementation and a deterministic test implementation.
- The full existing headless Plenary suite is the regression gate. Focused core, event, owner, and workflow specs run during migration, followed by the full suite before completion.
- Tests for malformed private records, duplicate asynchronous completions, direct concurrent execute and refresh, overlapping GC workflows, incompatible UI states, or core-constructor rejection of unrelated caller fields are not required unless a supported workflow reproduces a user-facing failure.

## Out of Scope

- Changing documented creation, navigation, expansion, editing, write, refresh, watcher, presentation, selection, or destruction behavior beyond adding standalone core use and replacing `instance:setGroup` with `fre.set_group`.
- Making Manager, GC, default-explorer takeover, managed lookup, or group migration mandatory for core Instance use.
- Providing a second bundled Manager implementation. Custom managers consume the public core and event contracts without requiring a framework inside Fre.
- Reworking reveal ownership or extracting a new reveal module unless the ownership migration proves a direct requirement.
- Replacing the existing deep Tree, Buffer, Sync, Work, Lifecycle, Watch, View, or mutation responsibilities with new abstractions.
- Introducing a generic runtime container, context object, service locator, dependency-injection framework, callback event bus, command dispatcher, or capability registry.
- Preserving private Manager, Instance, View, or GC fields for test or plugin compatibility.
- Preserving an Actions-only child creator or source-Instance Manager affinity.
- Supporting foreign markers whose Registry source record is removed or whose referenced source node no longer exists.
- Making standalone Instances visible through the default Manager's lookup API without explicit Manager registration.
- Adding process-wide cancellation, admission control, transactions, or generation systems for unsupported caller concurrency.
- Expanding validation for malformed private arguments, invented call sequences, duplicate completions, adversarial adapters, or caller-owned fields that the core does not consume. Ownership is established by not retaining or interpreting such data, not by adding speculative constructor rejection.
- Changing the per-tab View behavior, action destination semantics, write confirmation behavior, filesystem ordering, or special-entry mutation behavior.
- Adding alternate filesystem, watch, mutation, write-UI, GC, or Registry abstractions beyond the concrete seams justified by production, deterministic tests, standalone core, and custom management.

## Further Notes

- The repository's established domain terms are Instance, Manager, Lifecycle, Tree, Buffer, Sync, Work, Watch, View, Registry, GC, presentation, Entry, ActionContext, and foreign marker. Implementation and tests should use these terms consistently.
- Instance is the core product module. Manager is Fre's default process-management convenience; it is not the authority that makes an Instance valid.
- Registry is a shared identity owner, not a generic repository abstraction. GC is optional process policy used by a manager, not an Instance child. A custom manager follows the same rule: its group, quota, cache, tenancy, or other business metadata belongs in manager-owned records keyed by Instance identity, not on Instance.
- A Neovim User event is intentionally different from an injected command. The core reports a committed fact; each consumer independently decides which external effect applies.
- The dependency graph must be checked using requires, retained references, runtime calls, injected closures, and event payloads. Removing a direct `require` alone does not establish one-way ownership.
- The deletion test applies to Instance-private children, Registry, and GC. Deleting one must force its complete responsibility into the core facade or another owner; shallow forwarding files are not acceptable merely to satisfy the target directory layout.
- Migration should proceed in ownership-complete stages: establish the standalone core constructor and private paths; establish Registry marker ownership; add protected User events; move View state into View; move GC state into GC; remove Instance-to-Manager calls; migrate concrete child dependencies; move group migration to Fre; migrate Actions and takeover; then update documentation and tests.
- At every stage, avoid a temporary design that becomes permanent: no Manager callback bag, no global Registry installed into View, no `instance._create_child`, no duplicate lifecycle callback interface beside Neovim events, no omnibus effective-config copy, and no copied GC, caller-business, or View fields retained on Instance or its buffer metadata.
- The architecture diagram is normative for dependency direction. The file layout is normative for core-private ownership; shared adapters and plugin integration remain outside `lua/fre/instance/`.
