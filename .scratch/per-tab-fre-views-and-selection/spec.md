# Simplify Per-Tab Fre Views and Selection Actions

Status: ready-for-agent

## Problem Statement

Fre currently spreads presentation behavior across Instance state, window mechanics, mappings, and selection actions. A single Instance can be displayed in multiple windows in the same tab, while open, hidden, and toggle choose among those windows using ambient editor state and layout history. The window layer also owns layout policy, visibility discovery, metadata, rollback, and lifecycle consequences. This makes ordinary behavior difficult to explain and makes select, tab_select, and split_select inconsistent when the source is a float or when the selected entry should be installed somewhere other than the invoking Fre window.

From a user's perspective, it is unclear which Fre window an operation affects, whether selecting an entry will replace the picker or another window, and whether the source Instance will remain visible. From a maintainer's perspective, supporting arbitrary duplicate Fre buffers, cached layout state, full-editor rollback, and cross-module visibility transitions creates more state and failure paths than a small Neovim plugin needs.

## Solution

Give every Instance at most one Fre-managed active View per tab while retaining shared Instance data across tabs. Keep only active View records; hiding removes the record, and reopening uses an explicit layout or the Instance's immutable default. A focused View module owns tab-local View lifecycle and ownership transfer, a pure layout module resolves layout input, and the window layer performs exact policy-free Neovim operations.

Selection actions will use exact captured source and destination window IDs. They will prepare a file buffer or child Instance, establish the destination, commit the selected buffer, update View ownership, and optionally hide the source View after destination commit. Dynamic mappings can inspect the active View's layout and origin to choose Oil-style float behavior without expanding ActionContext or teaching the window layer about floats.

Fre will guarantee these semantics only for Views created and operated through Fre APIs, mappings, and actions. Manually duplicating a Fre buffer through raw Neovim commands is unsupported and will not trigger an automatic reconciliation system.

## User Stories

1. As a Fre user, I want one Instance to share its tree and buffer state across tabs, so that navigation state remains consistent wherever I view it.
2. As a Fre user, I want each tab to contain at most one Fre-managed View for an Instance, so that open, hide, and toggle affect an unambiguous window.
3. As a Fre user, I want Views in different tabs to keep independent Neovim cursor and scroll state, so that working in one tab does not move another tab's cursor.
4. As a Fre user, I want opening a hidden Instance in a tab to create one View, so that repeated opens do not produce duplicate managed windows.
5. As a Fre user, I want opening an already visible Instance without a layout override to focus its existing View, so that open is predictable and inexpensive.
6. As a Fre user, I want an explicit layout override to relayout the current tab's managed View, so that layout changes are intentional rather than an implicit toggle state.
7. As a Fre user, I want hiding an Instance to affect only the source or requested tab, so that the same Instance remains available in other tabs.
8. As a Fre user, I want a separate explicit operation to hide an Instance from every tab, so that global cleanup is possible without overloading tab-local hide.
9. As a Fre user, I want toggle to be strictly binary in the target tab, so that visible always means hide and hidden always means open.
10. As a Fre user, I want reopening without an explicit layout to use the Instance's configured default, so that hidden Views do not require retained presentation history.
11. As a Fre configuration author, I want an Instance-specific layout override to be copied when the Instance is created, so that later setup changes do not unpredictably mutate existing Instances.
12. As a Fre configuration author, I want explicit action or open arguments to take precedence over the Instance default, so that per-invocation behavior remains possible.
13. As a Fre user, I want native window resizing to change only live geometry, so that it does not silently rewrite the layout I requested.
14. As a Fre user, I want current-position Views to restore the buffer they replaced when hidden, so that opening Fre temporarily does not lose my prior editing context.
15. As a Fre user, I want Fre-created split, float, and tab Views to close when hidden, so that no empty presentation windows are left behind.
16. As a Fre user, I want selecting a file with select to replace an exact target window, so that selection never guesses from ambient focus.
17. As a Fre user, I want select to default to the invoking Fre View when no target is supplied, so that ordinary non-float behavior remains direct.
18. As a Fre user, I want selecting a directory in the invoking View to replace the parent with a child Instance in the same View, so that directory navigation preserves the presentation.
19. As a Fre user, I want a directory child to inherit the target View's origin, layout, and close-or-restore behavior, so that hiding and later selections remain coherent.
20. As a Fre user, I want selecting a file into an ordinary target window to leave that window as an ordinary file window, so that Fre does not retain stale View ownership.
21. As a Fre user, I want selecting a directory into an ordinary target window to create one child View there, so that the child can later hide and restore the previous buffer correctly.
22. As a Fre user, I want tab_select to install the selection in a newly created tab, so that the source View remains available unless I explicitly hide it.
23. As a Fre user, I want split_select to create the requested split relative to an exact anchor window, so that split placement is deterministic.
24. As a Fre user, I want file and directory selections to follow the same destination rules across select, tab_select, and split_select, so that action names differ only by destination shape.
25. As a Fre user, I want invalid target or anchor windows to fail before destination mutation, so that a stale mapping does not modify an unrelated window.
26. As a Fre user, I want hide_source to hide only the source Instance's View in the captured source tab, so that other tabs and other Instances remain unaffected.
27. As a Fre user, I want hide_source to run only after the destination is successfully installed, so that a failed selection does not close my picker.
28. As a Fre user, I want selecting from a float to be configurable per mapping, so that one shortcut can keep navigation in the float while another sends a file to the originating window.
29. As a Fre configuration author, I want a read-only View query available to mapping functions, so that mappings can inspect active layout and origin without accessing private tables.
30. As a Fre configuration author, I want Instance-specific mappings to continue merging with defaults, so that customizing selection does not require redeclaring unrelated mappings.
31. As a Fre user, I want a directory child loading state to appear immediately in its committed destination, so that asynchronous loading does not make selection appear unresponsive.
32. As a Fre user, I want a child load failure to appear in the already selected child View, so that Fre does not attempt a surprising editor-wide rollback.
33. As a Fre user, I want reveal to expand shared tree state while moving only a currently visible target View's cursor, so that hidden tabs do not retain surprising future cursor jumps.
34. As a Fre maintainer, I want presentation state to be separate from Instance load lifecycle, so that ready, failed, and destroyed do not multiply into visible and hidden state variants.
35. As a Fre maintainer, I want garbage collection to verify actual buffer visibility immediately before destruction, so that unsupported external windows cannot cause a visible buffer to be destroyed.
36. As a Fre maintainer, I want ordinary operations to use a small per-Instance tab map rather than global reverse indexes, so that state synchronization remains easy to audit.
37. As a Fre maintainer, I want window mechanics to receive exact buffers, windows, tabs, and layouts, so that the lower layer contains no source-float or action policy.
38. As a Fre maintainer, I want tests to assert public Neovim behavior rather than private View records and rollback snapshots, so that internal simplification does not require rewriting unrelated assertions.
39. As a Fre maintainer, I want unsupported manual Fre-buffer duplication documented as unsupported, so that the implementation does not grow an event-driven repair system for editor misuse.
40. As a Fre user, I want documented dynamic keymap examples for layout-sensitive Enter behavior and separate selection shortcuts, so that advanced behavior is discoverable without becoming global configuration.
41. As a Fre user viewing one Instance in multiple tabs, I want every visible View to keep pointing at the same semantic Entry when another View expands, collapses, or refreshes the shared projection, so that buffer row changes do not move my cursor onto unrelated entries.

## Implementation Decisions

- Instance remains the owner of shared filesystem state, the Fre buffer, tree projection, drafts, watchers, refresh behavior, and asynchronous load lifecycle.
- An Instance may have one active Fre-managed View in each tab and may therefore be visible in several tabs simultaneously.
- A View is an internal active presentation record, not a public handle. Hidden tabs have no retained View record.
- The active View record contains the exact window, originating window, normalized requested layout, whether hide closes or restores the window, and the previous buffer when restoration is required.
- Active Views are stored only in `Instance._views`, a per-Instance map keyed by tabpage. Hidden and stale entries are removed. No process-wide window-to-View reverse index or visible counter will be introduced.
- The View module is the sole owner of opening, hiding, toggling, inspecting, transferring, detaching, and pruning active View records.
- The layout module contains pure normalization, validation, default resolution, and geometry materialization. It does not own Instance or View state.
- The window module exposes exact policy-free Neovim mechanics. It does not infer source floats, origins, visibility, Instance ownership, GC eligibility, or action behavior.
- The Instance public presentation methods remain thin delegates over the View module.
- Setup layout is normalized and copied into immutable Instance configuration at creation. Instance-specific configuration may override the setup default.
- Layout resolution uses only an explicit invocation layout followed by the Instance default. Hiding does not retain per-tab layout history.
- Effective window geometry is measured from Neovim when needed and is not cached as authoritative presentation state.
- Opening a visible View without an explicit layout focuses it. Opening with the same normalized explicit layout reuses the same window without resetting cursor or scroll. Opening with a different explicit layout performs a local relayout and updates the active record only after success.
- `Instance:hidden()` remains tab-local and defaults to the current tab. `Instance:hide_all()` hides every active View. The mapped hidden action and action-level source cleanup operate on the exact tab captured in ActionContext rather than whichever tab is current later.
- Toggle is binary and tab-local. A visible View is hidden; an absent or stale View is opened. Layout comparison does not create a third toggle branch.
- Current-position Views restore their prior buffer when valid and otherwise use a safe empty buffer. Fre-created split, float, and tab destinations are closed on hide.
- If a close-on-hide View has become Neovim's final ordinary window and cannot be closed, hiding installs a safe empty buffer in that window and removes View ownership.
- Origin exists only for an active View. Hiding clears it, and reopening captures a fresh origin from the explicit anchor or synchronous caller.
- The public read-only `fre.view.inspect(instance, tabpage?)` query defaults to the current tab, validates and prunes the requested entry, and returns a copied snapshot containing the active window, normalized requested layout, and origin. It returns nil when no valid active View exists and cannot mutate ownership.
- ActionContext remains a synchronous invocation snapshot containing the Instance, exact source tab and window, selected Entry information, and mode or range information required by existing actions.
- Layout, origin, visibility, lifecycle tokens, and reconciliation metadata are not copied into ActionContext. Mappings query current View data only when needed.
- Caching ActionContext for delayed execution is unsupported. Actions perform inexpensive checks that the captured window, tab, and Fre buffer still match before mutation.
- Fre guarantees one-View-per-tab behavior only for Views created through Fre operations. Manually displaying a Fre buffer in an additional native window is unsupported and is neither adopted nor automatically retired.
- Buffer-local leave or close handling schedules a small prune for the affected Instance after a managed window closes, changes buffer, or its tab disappears. Pruning scans only that Instance's active tab map, removes stale entries, and notifies GC when the Instance has no managed Views. It does not form a general event reconciliation router.
- Actions share a small internal preparation and installation flow rather than a generalized transaction framework.
- Selection preparation produces either a regular file buffer or a child Instance whose loading buffer can be installed immediately.
- `select` accepts optional `target_winid`, `hide_source`, and child `instance` options. Its target defaults to the exact source window captured in ActionContext.
- `tab_select` accepts optional `hide_source` and child `instance` options and creates an explicit new tab destination.
- `split_select` accepts a required split layout plus optional `anchor_winid`, `hide_source`, and child `instance` options. Its anchor defaults to the exact captured source window only when that window is ordinary; a float source must supply an exact ordinary anchor, such as the active View's origin.
- `hide_source` defaults to false for all three selection actions. Target and anchor defaults never consult ambient editor focus or infer float policy.
- Installing a regular file detaches any managed Fre View ownership from the target after the buffer installation succeeds.
- Installing a child into a managed Fre View transfers the target record from the previous Instance to the child Instance after buffer installation succeeds.
- Installing a child into an ordinary window creates one active child View that restores the target's previous buffer when hidden.
- Creating a child in a Fre-created split, float, or tab records close-on-hide behavior and the exact origin used to create the destination.
- hide_source is orthogonal to destination choice. It refers to the source Instance's exact View in the captured source tab, not to all Views of that Instance.
- hide_source runs after destination commit. If target replacement already detached or transferred the source View, source hiding is a no-op.
- Option, Entry, target, and anchor validation occurs before destination mutation. Resources created before buffer installation are cleaned up on pre-commit failure.
- Successful destination buffer installation is the commit point. Focus or source-hide failures after that point do not trigger editor-wide rollback.
- A directory child that later enters load-failed remains installed and presents that state. The parent is not restored automatically.
- Instance lifecycle is represented independently as creating, ready, load-failed, destroying, or destroyed. Visibility is derived from active Views and actual final buffer visibility, not encoded in lifecycle state names.
- GC is notified by normal hide and prune operations. Immediately before destructive cleanup, it checks actual Neovim windows displaying the Fre buffer and defers destruction while any remain.
- Reveal expands the shared tree projection. It moves a cursor only when the requested tab has an active View; it does not store a long-lived pending cursor for a hidden tab.
- Before mutating the shared projection buffer, refresh captures a transient snapshot for every valid active View in `Instance._views`: its exact window, the cursor Entry's full path, old row, and Neovim window view. These snapshots exist only for that projection update and are never retained in the View records.
- After mutation, refresh builds one path-to-row index and restores each still-valid active View to the same Entry path at its new row. It adjusts the saved topline by the cursor row delta, clamped to valid Neovim bounds, so the Entry remains at approximately the same relative screen position without changing the current tab or focused window.
- If the previous cursor Entry is no longer projected because of collapse, deletion, or refresh, restoration walks to the nearest surviving ancestor path. If no ancestor remains, it uses the root or first valid Entry.
- These rules apply independently to active Views in current and non-current tabs. A tab with no active View has no cursor snapshot and receives no deferred cursor intent; manually duplicated unsupported Fre-buffer windows receive no cursor-preservation guarantee.
- Cursor and viewport restoration is independent best-effort work performed after the shared projection update. If a View snapshot cannot be decoded, its Entry or fallback cannot be resolved, the window becomes invalid, or a Neovim cursor/view operation fails, Fre leaves that View at its natural post-update cursor and viewport, continues restoring other Views, and does not report an error or roll back the projection.
- Instance-level mapping overrides continue to merge with setup/default mappings unless default mappings are explicitly disabled.
- Documentation adds a tips section about dynamically configuring keymaps. It includes one Enter mapping that chooses behavior from the active View's layout and Entry kind, plus separate shortcuts that always select in the source or origin destination.
- The new model replaces conflicting old layout-history, multi-view, rollback, and visibility-state paths rather than coexisting with them behind compatibility branches.

## Testing Decisions

- Tests will assert externally observable Neovim behavior through public Instance methods and exported actions. Private View records, metadata variables, internal helper call order, and exact rollback structures are not behavioral contracts.
- The primary seam is the existing window layout behavior spec through public open, hidden, and toggle operations. It will cover one managed View per Instance per tab, focus and relayout behavior, independent cross-tab Views, tab-local hide, binary toggle, exact geometry, window options, and cursor or scroll continuity for active Views.
- The necessary secondary seam is the existing actions and mappings behavior spec. It will cover select, tab_select, and split_select for files and directories; exact target and anchor validation; child View transfer; ordinary-target adoption; float-origin mappings; and post-commit hide_source behavior.
- Configuration tests remain the seam for built-in and Instance-specific layout defaults, merge behavior, supported layout families, and invalid layout rejection.
- Destruction and GC tests remain a narrow integration seam for cross-tab cleanup, normal hide intervals, stale managed View pruning, and the final actual-buffer-visibility guard.
- Instance tests retain public open return behavior, readiness interaction, and initial cursor positioning where those contracts cannot be observed more clearly in the primary seam.
- Existing headless Plenary tests and real Neovim tabs, windows, buffers, autocmds, and filesystem fixtures remain the prior art and execution environment.
- Same-layout reuse tests will assert stable window identity and cursor or winsaveview behavior without inspecting internal layout history.
- Different-layout tests will assert the resulting window presentation and the absence of duplicate managed Views in the same tab.
- Cross-tab tests will assert that hiding or replacing one tab's View does not affect another tab's View of the same Instance.
- Selection tests will assert that replacing a source with a file leaves no stale Fre ownership, while replacing it with a directory child preserves the observable hide and destination behavior.
- Float selection tests will assert both configurable behaviors: directory navigation remaining in the float and file selection installing into the captured origin before hiding the source float.
- Invalid destination tests will assert that the source remains visible and that no destination split, tab, or child View is committed.
- Load-failure tests will assert that an installed directory child remains the destination and visibly reports failure rather than restoring the parent.
- Reveal tests will assert shared expansion, active-tab cursor movement, and no deferred cursor jump after revealing while a target tab is hidden.
- Cross-tab projection tests will place the second View's cursor after a directory expanded from the first View, then assert that it follows the same Entry path to its new row, preserves its relative viewport position within valid bounds, and does not steal focus.
- Collapse and refresh tests will assert that a cursor whose Entry disappears falls back first to the nearest surviving ancestor and then to the root or first valid Entry, without creating persistent per-tab cursor state.
- Cursor-restoration failure tests will make a secondary View unresolvable or invalid and assert that the projection update still succeeds without an error, other Views continue restoring, and the failed View is otherwise left untouched.
- GC tests will include a visible buffer safety case but will not require Fre to adopt or reconcile manually duplicated external windows.
- Large fault-injection suites that assert global snapshots, transition flags, scratch retirement ordering, or broad post-effect rollback will be replaced by a small number of user-visible pre-commit cleanup cases.
- Tests for selecting among several same-tab Fre views, hiding all same-tab duplicates, manually splitting the same Fre buffer, and automatic BufWinEnter reconciliation will be removed because those behaviors are outside the new contract.
- New direct unit-test seams for View internals should not be introduced unless a failure cannot be observed through the public Instance or action seams. Pure layout validation may remain independently testable through the existing configuration seam.

## Out of Scope

- Supporting or automatically repairing manually duplicated Fre buffers created through raw Neovim window and buffer commands.
- Public View handles or a second public presentation object alongside Instance.
- A global one-View-per-Instance restriction across all tabs.
- A process-wide reverse window index, visible counter, View or presentation generation number, capability token, or presentation transaction manager. Existing generation counters used for unrelated asynchronous tree, load, watcher, or GC synchronization are outside this decision.
- Persisting per-tab requested layouts after hide.
- Persisting a pending reveal cursor for a hidden tab.
- Supporting delayed or cached ActionContext values.
- Inferring a selection destination from whichever window happens to be current after a mapping begins.
- A setup-wide automatic hide policy that applies identically to every selection mapping.
- Cross-tab hide_source behavior; global hiding remains a separately named operation.
- Full editor rollback after a destination buffer has been successfully installed.
- Automatic parent restoration when an asynchronously loaded child Instance fails.
- Preserving undocumented internal window metadata, transition flags, layout-history tables, or tests that encode them.
- Changing shared tree, draft, mutation, watcher, or filesystem semantics except where lifecycle state names currently depend on presentation visibility.
- Adding compatibility branches that keep the rejected same-tab multi-view architecture active beside the new model.

## Further Notes

- The repository currently uses the terms Instance, Fre buffer, Fre view, layout, Entry, ActionContext, select, tab_select, split_select, source view, destination, and child Instance. The implementation and documentation should keep those terms consistent.
- The active View term formalizes the single Fre-managed presentation owned by an Instance in one tab. It does not imply a public View object.
- This is an internal architectural replacement with deliberate user-visible clarifications. Migration notes should call out tab-local hide, binary toggle, default-layout reopening, unsupported native duplicates, and action-level hide_source.
- The implementation should be staged so tests move with each ownership boundary, but the finished code should contain one model rather than old and new presentation systems running in parallel.
- No existing ADR or domain glossary constrains this work. The published spec is the current authoritative statement of the agreed behavior.
