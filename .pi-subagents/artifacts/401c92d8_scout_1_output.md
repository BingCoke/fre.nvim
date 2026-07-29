# Code Context

## Files Retrieved
1. `lua/fre/init.lua` (lines 8-11) - public `fre.new(opts)` entry.
2. `lua/fre/manager.lua` (lines 95-119) - validates root, reads `opts.inherit`, resolves config, calls constructor.
3. `lua/fre/config.lua` (lines 278-291, 416-521) - admits `inherit` and derives sort/hidden state from predecessor.
4. `lua/fre/instance.lua` (lines 1-10, 287-297, 806-845, 1638-1665, 1728-1809) - runtime inheritance hooks, lifecycle teardown, constructor field.
5. `lua/fre/inheritance.lua` (lines 1-239) - complete predecessor expansion snapshot/compile/drive state machine.
6. `tests/instance_spec.lua` (lines 51-478) - async lifecycle, registration, cleanup, direct constructor contract.
7. `tests/state_inheritance_spec.lua` (lines 192-609) - all behavior coupled to predecessor inheritance.
8. `tests/manager_spec.lua` (lines 1-129) - manager ID/index/group lifecycle; no inheritance coverage.

## Key Code
- Current construction chain: `fre.new(opts)` → default `Manager:create_instance(opts)` →
  `inheritance.snapshot(opts.inherit)` → `inheritance.compile(snapshot, absolute_root)` →
  `Manager:resolve_instance_config(opts, opts.inherit)` →
  `Instance.new(manager, root, effective, expansion)` → buffer/tree/watch setup → register → `_start_load(true)`.
- `Instance.new` allocates ID and buffer, copies effective config, initializes tree/watchers, registers, starts async load;
  any constructor fault runs `cleanup_failed_constructor`, consumes the ID, removes indexes and wipes the buffer.
- Ready lifecycle: `_finish_initial` reconciles/render/syncs watchers, then calls `inheritance.start(self)`.
  Explicit `expand` calls `inheritance.resume`; `collapse` calls `inheritance.collapse`.
- Destruction: `_start_destroy` invalidates generations/callbacks/watchers/mappings; `_finish_destroy` wipes buffer,
  unregisters, and retains only `id/root/bufnr/state/_destroyed`.

## Review Findings
- **blocker** `lua/fre/manager.lua:109-115`: `opts.inherit` is a direct source-instance reference and affects both
  expansion state and effective config, violating “instance solely determined by passed opts” in the intended
  value-options sense (the opts currently embed another live instance).
- **blocker** `lua/fre/config.lua:278-291,416-466`: public `new_fields.inherit`, validation, `predecessor`
  parameter, `predecessor_sort`, and `predecessor_hidden_file` copy mutable runtime state (`current_sort`,
  `current_hidden_file`) from another instance.
- **blocker** `lua/fre/instance.lua:1764`: `_inheritance_trie` is an inheritance-only instance field.
- **major** `lua/fre/instance.lua:296,816,821,844`: lifecycle operations are coupled to hidden inheritance
  state, so post-construction behavior is not represented by ordinary explicit options.
- **major** `lua/fre/inheritance.lua:39-239`: `snapshot`, `compile`, `start`, `resume`, `collapse` and trie fields
  `desired/children/status/windows/started` exist solely to reproduce predecessor expansion state.
- No persistent predecessor pointer is stored on the child after creation; the prohibited source reference is
  accepted transiently as `opts.inherit`, inspected synchronously, then reduced to config values and a trie.

## Minimal Change
1. Remove `inherit` from `config.new_fields`; delete its validation and all predecessor helpers/parameter logic.
2. Change `Manager:resolve_instance_config(opts, predecessor)` to `(opts)` and resolve only setup defaults + opts.
3. In `Manager:create_instance`, delete snapshot/compile and call `Instance.new(self, root, effective)`.
4. Change `Instance.new(..., expansion)` to three arguments; delete `_inheritance_trie`, inheritance require,
   and the four `start/resume/collapse` calls. `lua/fre/inheritance.lua` then becomes fully deletable.
5. If expansion restoration remains desired, model it as an explicit value option (for example
   `expanded = {"a", "a/b"}`), validated/copied by config with no instance reference; this is a separate feature,
   not required for the smallest removal.

## Red Tests / Test Changes
- Add to `tests/instance_spec.lua`: `fre.new({root=..., inherit=instance})` must error with unknown field
  `inherit`; assert a child created with only `root` uses setup `sort/hidden_file`, not another instance’s runtime state.
- Replace/remove all eight inheritance scenarios in `tests/state_inheritance_spec.lua:207-609`; under the stated
  contract they encode behavior that must disappear. If explicit `expanded` opts are introduced, rewrite only
  expansion cases to pass plain path arrays and assert no `_inheritance_trie`/source reference exists.
- Update `tests/instance_spec.lua:429,465`: call `resolve_instance_config({root=root})` and
  `Instance.new(manager, root, effective)` without legacy nil predecessor/expansion arguments.
- `tests/manager_spec.lua` needs no behavioral rewrite; optionally add a manager-level unknown-`inherit` test.

## Architecture
Setup defaults and explicit opts should merge in `config.resolve_instance`; manager should normalize root and pass
that self-contained effective value to `Instance.new`. Instance then owns only its buffer/tree/watch/load state.

## Start Here
Open `lua/fre/manager.lua:95-119`: it is the narrow choke point where both forms of inheritance enter construction.

## Residual Risks
Removing inherited expansion deletes asynchronous branch-loading behavior and its error handling; ensure no
out-of-scope callers invoke `fre.inheritance` directly. No commands/tests were run because this was read-only review.