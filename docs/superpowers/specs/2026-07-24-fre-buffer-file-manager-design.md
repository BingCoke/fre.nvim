# fre.nvim Buffer File Manager Design

- Status: Draft for user review
- Date: 2026-07-24
- Project: `fre.nvim`
- Reference implementation studied: `../oil.nvim`

## 1. Summary

`fre.nvim` is a local-filesystem manager implemented as an editable Neovim buffer.

The buffer shows root-relative paths rather than an indented tree. Directories can be expanded in place, so an instance rooted at `/project` can render:

```text
src/
src/a.ts
src/b.ts
src/lib/
src/lib/c.ts
tests/
```

The user edits this text and executes `:write` to prepare, confirm, and execute filesystem operations. Existing rows carry concealed stable identity, allowing Fre to distinguish rename, move, copy, delete, and create operations. The default write action presents immediate cancellable progress; direct execution remains UI-free and exposes a single-use handle.

Each Fre instance owns exactly one buffer and one independent tree model. A buffer is created as soon as the instance is created, even when no window currently displays it. Windows are optional views over that buffer. By default, the first `setup()` also makes Fre the process-wide directory-buffer explorer in place of netrw.

The implementation prioritizes a simple public model and responsive file/tree operations. Internally it uses per-directory nodes, incremental subtree projection, per-directory watchers, concealed physical row-identity markers, real parseable column text, extmarks for internal row lookup and highlighting, concurrent ordinary directory reads, and serial per-Execution callback-form `vim.uv` filesystem work with best-effort cancellation. It does not reuse Oil's single-directory view/parser internals.

## 2. Goals

Fre must provide:

1. A normal editable buffer representing a filesystem tree.
2. Root-relative full paths as the editable text format.
3. In-place expansion of arbitrary nested and branching directories.
4. Direct buffer edits for create, copy, move, rename, and delete.
5. A two-phase `prepare()` and `execute(plan)` mutation API with a simple single-use Execution handle.
6. A confirmation summary and immediate cancellable progress float for the default `:write` action.
7. Best-effort cancellation of active mutation work, with reconciliation owned by the default write workflow.
8. Correct move scheduling, including cycles such as `a -> b` and `b -> a`.
9. Local filesystem watching for root and active expanded directories.
10. Instance GC by hidden TTL and per-group maximum instance count.
11. New-instance inheritance of expansion state, current sort function, and hidden-file state.
12. Window primitives supporting left, right, top, bottom, and floating layouts.
13. Function-based actions and function-based buffer-local mappings.
14. Real, yankable columns such as icon, permissions, and modification time before the editable path.
15. Cross-instance copy by yanking and pasting a namespaced existing-row marker.
16. Serializable buffer metadata through `vim.b` and full Lua state through instance lookup.
17. Snapshot-path cursor lookup through `get_pos()` without exposing extmark IDs.
18. Predictable Vim errors instead of complex recovery systems.
19. Optional process-wide replacement of netrw for local directory buffers, enabled by default.

## 3. Non-goals

The first implementation will not provide:

- Oil adapter compatibility.
- SSH, S3, trash, archive, or other non-local backends.
- A compatibility abstraction for older Neovim versions.
- Persistent cross-instance clipboard state after the source instance has been destroyed.
- Transactional rollback after a partially executed or canceled plan.
- A headless worker process, external `cp`/`rm`, hard cancellation latency guarantee, or detached recovery machinery.
- Resuming, retrying, waiting on, reusing, or subscribing to an Execution after creation.
- A public progress UI DSL or configuration surface.
- Three-way merging between buffer edits and external filesystem changes.
- Recursive platform-specific filesystem watching.
- Editable metadata columns.
- Local roots or entry names containing a newline byte, which cannot be represented as one Neovim buffer line.
- A persistent on-disk session format.
- A draft model for preserving unsaved edits across projection-changing tree operations.
- A global sort of the flattened buffer.
- Automatic `:cd`, `:lcd`, or `:tcd` behavior.
- Runtime restoration of netrw or switching the process-wide default file explorer after the first `setup()`.

Users can implement policy such as automatic window-local cwd through Fre's filetype, buffer metadata, and public lookup API.

## 4. Terminology

### Instance

A Lua object owning one root, one buffer, one node tree, effective configuration, watchers, and GC state.

### Node

An instance-local representation of one filesystem entry. Directory nodes own their direct children and sibling ordering.

### Entry

A freshly copied plain table with exactly `instance_id`, `node_id`, `absolute_path`, `relative_path`, `name`, and `kind`. `instance_id` and `node_id` are positive integer IDs. `relative_path` is the normalized root-relative filesystem-semantic snapshot path using `/`, with no display-only trailing slash; the root Entry uses `""`. `absolute_path` is the normalized absolute filesystem snapshot path with no display-only trailing slash. `name` is the snapshot basename without a display slash, and `kind` is `"file"`, `"directory"`, or `"symlink"`. Caller mutation never affects a node. Directory row rendering alone appends `/`.

### View

The ordered visible rows projected from an instance's node tree into its buffer.

### Expanded

A directory state indicating that its children should be visible when its ancestor chain is visible.

### Active expanded directory

An expanded directory whose complete ancestor chain is also expanded. Only active expanded directories require live projection and watchers.

### Plan

A plain caller-constructible Lua table containing exact ordered filesystem operations and user-facing display lines. `prepare()` is the default compiler, not a provenance requirement.

### Execution

A single-use handle returned by `instance:execute()`. It exposes cancellation and copied status while supplied operations execute in array order.

## 5. Core Design Rules

1. The buffer is the sole source of unsaved filesystem edits.
2. Fre does not maintain a second hidden draft of modified rows.
3. Projection-changing operations fail while the buffer is modified.
4. Window operations remain available while the buffer is modified.
5. Node trees, node IDs, extmarks, and watchers are never shared between instances.
6. Inheritance copies path-based state at instance creation and never creates live coupling.
7. Every directory sorts only its direct children; the flattened view is their DFS projection.
8. Configured columns are real read-only buffer text and remain available to ordinary selection and yank.
9. Every successful projection records the exact stable IDs it rendered; only that baseline participates in delete detection.
10. Watch events never overwrite modified, hidden, or write-locked buffers and instead retain `needs_refresh`.
11. `prepare()` owns operation choice, ordering, move-cycle lowering, and display.
12. `execute(plan)` trusts caller data, performs supplied operations in order, and owns no presentation or reconciliation.
13. `actions.write` owns readiness, locking, confirmation, progress presentation, and filesystem reconciliation.
14. Directory actions remain one Plan operation; move is exactly one rename with no implicit fallback.
15. Automatic GC protects visible and modified instances; explicit destruction may force-discard when execution is terminal.
16. Neovim's actual windows are the source of truth for instance visibility.
17. Filesystem conflicts and partial effects surface naturally during execution; Fre does not roll them back.

## 6. Top-level Public API

```lua
local fre = require("fre")

fre.setup(opts)

local instance = fre.new({
  root = "/project",
})

local current = fre.get_instance()       -- current buffer
local by_buf = fre.get_instance(bufnr)   -- explicit buffer
local by_id = fre.get_instance_by_id(id)
```

### `fre.setup(opts)`

Stores validated global defaults. Calling setup does not create an instance. Its first call also fixes the process-wide `default_file_explorer` decision for the rest of the Neovim process; later calls continue updating other defaults but silently discard that field.

### `fre.new(opts)`

Creates an instance, its hidden buffer, root node, buffer metadata, autocmds, and initial root load. `default_file_explorer` is setup-only and is rejected in `new(opts)`.

`root` is required. `instance.root` is computed without filesystem I/O as a stable lexical absolute platform-aware normalized path and never changes. The asynchronous initial load resolves the internal real root and requires it to exist as a directory; symlink roots are allowed.

### `fre.get_instance(bufnr?)`

Returns the instance associated with a Fre buffer. Omitting `bufnr` uses the current buffer. It returns `nil` for non-Fre buffers.

### `fre.get_instance_by_id(id)`

Returns a live instance by ID, or `nil` after destruction.

## 7. Instance Public Surface

An instance exposes simple read-only-by-convention fields:

```lua
instance.id
instance.bufnr
instance.root
instance.config
```

The public primitive methods are:

```lua
instance:open(layout)
instance:hidden()
instance:toggle(layout)

instance:expand(path)
instance:collapse(path)
instance:toggle_expand(path)
instance:reveal(path)

instance:set_hidden_file(value)
instance:toggle_hidden_file()
instance:set_sort(sort_fn)
instance:refresh(opts)
instance:when_ready(callback)

instance:get_pos(path)
instance:get_entry(row)

instance:prepare()
instance:execute(plan, handlers_or_callback)
instance:destroy()
```

Rules:

- Paths accepted by instance methods can be absolute or root-relative except for `get_pos(path)`, whose key is the root-relative snapshot path.
- Public methods normalize paths internally.
- `get_pos(path)` applies the same lexical root-relative filesystem-semantic normalizer used for Entry values. It treats one display-only trailing slash equivalently, so `src` and `src/` select the same snapshot key, but it does not call `vim.trim()` or remove meaningful leading or trailing path whitespace.
- `get_pos(path)` returns `{ row, col }` for a visible retained marker occurrence, where `row` is 1-based and `col` is a 0-based UTF-8 byte offset directly passable to `nvim_win_set_cursor()`. It never exposes an extmark ID.
- `get_pos(path)` uses snapshot node identity, not arbitrary edited path text. A node row extmark is only a fast hint; a mismatched hint triggers the exact-marker scan and deterministic rebinding defined in Section 14.
- `get_pos(path)` returns `nil` when the normalized snapshot path is absent, collapsed or otherwise not visible, or no exact marker occurrence remains. A selected retained row whose grammar is malformed raises a row-specific Vim error.
- `get_entry(row)` uses a 1-based row and returns a fresh Entry with exactly the fields and value contracts defined in Section 4. Out-of-range, absent, blank or unmarked new rows, and rows with complete marker removal return `nil`.
- A valid local or live foreign marker returns its source snapshot Entry regardless of the retained edited destination path. Duplicate marker occurrences return the same semantic Entry values in independently copied tables.
- A malformed, reserved, or unknown marker; destroyed foreign source; invalid source node; descriptor parse failure; semantic read-only change; or kind/trailing-slash mismatch raises a row-specific Vim error.
- `ActionContext.entry` is exactly `instance:get_entry(ActionContext.row)`.
- `when_ready(callback)` observes the current initial-load attempt and calls `callback(err)` exactly once. It queues while creating and schedules an immediate callback from ready or load-failed state. `User FreReady` carries the same success or failure with the instance ID and buffer number.
- `refresh(opts)` accepts optional `force` and `on_complete` fields under the exact Section 27 contract; asynchronous completion is delivered as `on_complete(err)` exactly once.
- `reveal(path)` never opens or toggles a window.
- `set_sort()` stores the new comparator and calls normal refresh.
- `destroy()` forcefully discards modified content only when no Execution is active. It synchronously raises a direct Vim error and changes nothing if this instance has an Execution in any nonterminal state.
- Calling methods other than harmless identity lookups after destruction reports a Vim error.

Programmatic execution composes handlers with the single-use handle:

```lua
local execution = instance:execute(plan, {
  on_progress = function(progress)
    consume(progress.current, progress.completed, progress.total)
  end,
  on_complete = function(err, result)
    finish(err, result.status)
  end,
})

local snapshot = execution:get_status()
local accepted = execution:cancel()

-- On a later execution, a function is shorthand for on_complete.
instance:execute(another_plan, function(err, result)
  finish(err, result.status)
end)
```

## 8. Configuration Model

The following table is the exact built-in default configuration, not an illustrative setup:

```lua
local columns = require("fre.columns")

require("fre").setup({
  -- Take over local directory buffers such as `nvim .` and `:edit src/`.
  -- Set false on the first setup call to leave them to netrw or another plugin.
  default_file_explorer = true,

  hidden_file = false,

  sort = function(parent, a, b)
    if a.kind ~= b.kind then
      return a.kind == "directory"
    end
    local a_lower = a.name:lower()
    local b_lower = b.name:lower()
    if a_lower ~= b_lower then
      return a_lower < b_lower
    end
    return a.name < b.name
  end,

  columns = {
    columns.icon(),
    columns.permissions(),
    columns.mtime({ format = "%Y-%m-%d %H:%M" }),
  }, -- rendered as real buffer text before the path

  gc = {
    ttl_ms = 60_000,
    default_group = "default",
    groups = {
      default = 10,
      project = 5,
    },
  },

  layout = {
    position = "left",
    size = 40,
  },

  use_mapping_default = true,
  mapping = {},

  buffer = {
    options = {
      buftype = "acwrite",
      bufhidden = "hide",
      swapfile = false,
      buflisted = false,
    },
    variables = {},
  },

  window = {
    options = {
      wrap = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      conceallevel = 3,
      concealcursor = "nvic",
    },
  },
})
```

The functions and constructor results shown above are the built-in public configuration values. `default_file_explorer` is Manager-owned setup state and is not copied into `instance.config`. The built-in normal-mode mapping base listed in Section 25 is a separate internal constant and is not part of `config.mapping`. Fre validates these defaults through the same schema used for user configuration. Execution cancellation and the fixed write-progress presenter add no fields.

An instance can override defaults:

```lua
local instance = require("fre").new({
  root = "/project",
  inherit = previous_instance,

  hidden_file = true,
  sort = custom_sort,
  columns = custom_columns,

  gc = {
    ttl_ms = 10_000,
    group = "project",
  },

  mapping = {
    n = {
      ["<C-l>"] = require("fre.actions").refresh,
    },
  },
})
```

`default_file_explorer` cannot be supplied to `new()`. Execution cancellation and the default write-progress float add no setup or per-instance configuration fields. Direct `execute()` remains UI-free, while `actions.write` delegates the fixed internal presenter to `progress.lua`.

## 9. Configuration Precedence

Configuration merging is field-specific:

- Scalar and function fields replace the inherited value.
- `columns` and every other sequence replace wholesale.
- `mapping`, `buffer.options`, `buffer.variables`, `window.options`, and other named maps merge by key. User `mapping` mode tables merge by mode and LHS across setup and then new; they never contain the separate built-in mapping base.
- Nested records merge only at these explicitly listed record fields: `gc.ttl_ms`, `gc.default_group`, `gc.groups`, `gc.group`, `layout.position`, `layout.size`, `layout.width`, `layout.height`, `layout.row`, `layout.col`, and `layout.border`. No generic recursive deep merge is used.
- `setup.gc.groups` is the Manager-owned map from group name to capacity. `new.gc.group` selects one group, and `setup.gc.default_group` supplies the omitted instance group.
- Effective instance configuration stores only `gc = { ttl_ms, group }`. `setup.gc.groups` is forbidden in `new()`, and group capacity cannot otherwise be overridden per instance.
- Effective `use_mapping_default` is the final setup/new boolean. Effective `mapping` contains only the snapshotted user override maps. Buffer mapping installation derives a separate installed map exactly once: start from the internal built-in base only when that boolean is true, then overlay the user maps by mode and LHS. When false, install only the user maps.
- `default_file_explorer` is a setup-only Manager boolean and is forbidden in `new()`. It never appears in effective instance configuration.

The first `setup(opts)` starts from the exact built-ins in Section 8, applies the rules above, validates the result, atomically stores defaults for future instances, and permanently records the effective `default_file_explorer` value for this Neovim process. Every later `setup(opts)` silently discards its `default_file_explorer` field before validation and retains the first value; all other fields still reset from exact built-ins. Before committing, Manager rejects any candidate `gc.groups` map that omits a group referenced by a live instance. A valid setup atomically replaces future-instance defaults and capacities, then enforces capacity once while protecting visible and modified instances. Existing instances retain their snapshotted effective configurations.

`new(opts)` starts from the current setup defaults, applies the same field-specific rules, resolves the new-only `root` and `inherit` fields, validates the result, and snapshots the effective configuration. It rejects `default_file_explorer` as a setup-only field. `instance.config.mapping` therefore exposes only copied user override maps, never installed built-ins. Mutable setup or caller tables are never shared with the instance, buffer mappings, or later setup/new calls.

When `new({ inherit = predecessor })` is used, dynamic view state has special precedence:

### Sort function

1. Explicit `new.sort`.
2. Predecessor's current sort function, including a function installed by `set_sort()`.
3. `setup.sort`.

### Hidden-file state

1. Explicit `new.hidden_file`.
2. Predecessor's current hidden-file state.
3. `setup.hidden_file`.

### Expansion state

Expansion is copied from the predecessor using the path-based inheritance algorithm defined later in this document.

The following are not inherited from the predecessor:

- GC TTL or group.
- Columns.
- Mappings.
- Buffer options or extra variables.
- Window options.
- Layout defaults.

Those fields continue to use setup plus explicit new-instance overrides.

Effective instance configuration is copied into the instance. Mutable setup tables are not shared with instances. Lua function references can be reused because Fre does not mutate function objects. Repeated `setup()` follows the reset-from-built-ins rule above for every field except the silently discarded process-wide `default_file_explorer` field and never changes predecessor snapshots or existing instance configuration.

## 10. Instance Registry and Lifecycle

The manager owns only the minimum global indexes required to resolve instances and enforce GC:

```lua
manager.instances_by_id[id] = instance
manager.instances_by_buf[bufnr] = instance
manager.groups[group_name] = {
  capacity = setup.gc.groups[group_name],
  instances = { [id] = instance },
}
```

The manager does not mirror Neovim's complete tab/window graph. Visibility is queried from Neovim with `vim.fn.win_findbuf(instance.bufnr)`.

### Default file explorer takeover

`default_file_explorer` is evaluated exactly once by the first `setup()` call. The Manager retains that boolean independently of future-instance defaults. A later `setup()` neither changes it nor attempts to restore netrw.

When the retained value is `false`, Fre does not set netrw globals, clear netrw autocmds, install a directory takeover autocmd, or inspect the current buffer.

When the retained value is `true`, the first setup performs this process-wide initialization:

1. Set `vim.g.loaded_netrw = 1` and `vim.g.loaded_netrwPlugin = 1`.
2. If the `FileExplorer` augroup already exists, clear it so an already-loaded netrw cannot race Fre for directory buffers.
3. Install one Manager-owned `BufEnter` autocmd for directory takeover. Individual instances do not own this autocmd.
4. Run the same takeover check once for the current window after setup, covering setup that occurs while a directory buffer is already current.

The takeover callback uses a transient per-buffer reentrancy guard and ignores unnamed buffers, Fre-owned buffers, non-local URI or scheme buffers, invalid buffers, and paths for which `vim.fn.isdirectory()` returns zero. The synchronous directory predicate matches the startup/editor interception performed by Oil; creation of the Fre instance still performs `real_root` resolution and directory loading asynchronously.

For a matching local directory buffer in the entered window:

1. If the source buffer is modified, raise a direct Vim error and leave its text, window, and buffer unchanged.
2. Create a new independent instance with the directory's lexical absolute path as `root`, no predecessor, and the current setup defaults. No global root-to-instance cache is introduced.
3. Replace only the entered window's buffer with the new Fre buffer using current-window layout semantics. A different window that later enters the same original directory buffer is handled independently.
4. If the original directory buffer is unmodified and no window still displays it, delete it. A deletion failure surfaces directly but does not roll back the already-created Fre instance or add recovery state.

Synchronous validation or instance-construction failure occurs before the window replacement and leaves the original directory buffer in place. An asynchronous initial-load failure after replacement uses the ordinary instance initial-load error path. Reentrant `BufEnter` events caused by the replacement see the Fre-owned buffer and stop. Fre provides no `unsetup()` or netrw restoration path.

An instance moves through these lifecycle states:

```text
creating -> ready-hidden <-> ready-visible -> destroying -> destroyed
         -> load-failed -> creating
         -> load-failed -> destroying -> destroyed
```

The `load-failed -> creating` transition is an explicit `instance:refresh()` retry. `execute(plan)` is independent of readiness because a caller Plan is self-contained.

### Creating

`fre.new()` performs these steps:

1. Validate the requested root syntax and compute its lexical absolute normalized path without filesystem I/O.
2. Resolve setup, predecessor, and explicit configuration precedence.
3. Validate the effective GC group.
4. Allocate a process-global instance ID that is never reused during the Neovim process lifetime.
5. Create the buffer immediately.
6. Attach required buffer options, variables, metadata, autocmds, and write handler.
7. Create the lexical root node.
8. Register the instance in Manager indexes.
9. Start the asynchronous initial load, which resolves `real_root`, requires that it exists as a directory, and only then lists and watches it.
10. Begin expansion-state restoration when a predecessor exists.
11. Treat the instance as hidden until a window displays the buffer.
12. Enforce group capacity after registration while excluding this newly registering instance from that pass.

The constructor returns before asynchronous real-root resolution and root loading finish. The buffer displays a non-protocol loading row while creating. Success commits the first projection and baseline, transitions to ready-hidden or ready-visible, calls current `when_ready` observers with `nil`, and emits `User FreReady`.

Failure displays a non-protocol error row, transitions to `load-failed`, calls observers with the direct error, and emits the same event carrying that error. The instance remains registered, openable, hideable, retryable, and destructible. While creating or load-failed, projection lookups and mutations (`get_entry`, `get_pos`, prepare, write, expand/collapse, reveal, sorting/filtering, and ordinary refresh other than retry) report readiness errors. Identity fields, `open`, `hidden`, `toggle`, `when_ready`, retry refresh, `execute(plan)`, and `destroy` remain available.

### Destroying

`destroy()` is the single cleanup path used by explicit destruction, TTL GC, and group-capacity GC. Its first precondition is that this instance has no active Execution in any nonterminal state. If that precondition fails, `destroy()` synchronously raises a direct Vim error and changes nothing: it does not terminalize the Execution, defer destruction, pin GC, or create detached state. Automatic GC also filters visible and modified instances before calling this path.

When the precondition passes, destruction performs:

1. Mark the instance as destroying so new work is rejected.
2. Invalidate outstanding non-Execution load and refresh generations.
3. Stop and close all watcher handles and debounce timers.
4. Close windows currently displaying the instance buffer where required by buffer deletion.
5. Force-delete the buffer, including when modified.
6. Remove the Manager ID, buffer, and group indexes. Manager visibility is queried directly from Neovim; instance-owned `hidden_since`, TTL scheduling state, and other GC state are simply discarded on successful destruction.
7. Drop node, metadata, mapping, layout, and pending-expansion state.
8. Mark the instance destroyed.

A late non-Execution async callback checks lifecycle and its captured generation, performs only required resource cleanup, and exits without touching Neovim state. Forced unsaved-edit destruction is available only through explicit `destroy()` when no Execution is active.

## 11. Node Tree Model

Every filesystem entry visible or cached by an instance is represented by an instance-local node:

```lua
Node = {
  id = 17,
  name = "src",
  path = "/project/src",
  kind = "directory",
  parent_id = 1,

  stat = nil,
  link = nil,

  children_by_name = nil,
  children_order = nil,
  load_state = "unloaded",
  expanded = false,

  row_extmark = nil,
  visible_size = 0,
  load_generation = 0,
  watcher = nil,
}
```

The exact private representation can change, but the following invariants are required:

- Node IDs are unique within an instance.
- IDs are not reused during an instance lifetime.
- `path` is the last filesystem snapshot path, not an unsaved edited path.
- Directory children are owned only by their direct parent.
- `children_by_name` supports reconciliation.
- `children_order` is the only sibling-order source used by projection.
- A node can remain cached while not visible.
- A node's extmark exists only while the node has a visible row.
- The root is a directory node but has no row of its own.

Instance-local indexes provide direct lookup:

```lua
instance.nodes_by_id[id] = node
instance.nodes_by_path[absolute_path] = node
```

Fre does not maintain a second live index for arbitrary edited path text. `get_pos(path)` uses `nodes_by_path`, then treats the node's row extmark only as a fast hint for locating the exact local namespaced marker. If the hinted row is not that marker, it scans current buffer rows for that exact marker and rebinds as specified in Section 14. Its keys remain snapshot paths while the buffer is modified.

## 12. Directory Loading and Reconciliation

A directory load uses local filesystem APIs only.

For each direct child, Fre obtains:

- Basename.
- Entry kind.
- Absolute normalized path.
- `lstat` metadata required for permissions, mtime, symlink behavior, and sort callbacks.

A root or entry basename containing a newline byte is unsupported because one filesystem entry must map to one Neovim buffer line. `fre.new()` rejects such a root, and directory loading reports a Vim error identifying an unsupported entry rather than skipping or escaping it.

Entry names with leading or trailing whitespace are loaded normally. Their editable row paths are subject to the `vim.trim()` boundary normalization defined in Section 14, so path-boundary whitespace is not preserved by a successful write and refresh.

Metadata requests use bounded asynchronous concurrency. A directory is considered ready for sorting and first projection after required direct-child metadata has completed or produced an error.

A refresh reconciles a directory node as follows:

1. Scan the directory's current direct children.
2. Match old and new entries by basename and compatible kind.
3. Reuse unchanged child nodes and stable IDs.
4. Replace nodes whose kind changed incompatibly.
5. Create nodes for new entries.
6. Detach missing entries from the current child map.
7. Preserve cached descendant trees for reused directory nodes.
8. Call the instance's current sort comparator for this parent's direct children.
9. Store the resulting order in `children_order`.
10. Patch only this directory's affected visible region when the dynamic column-width vector is unchanged; otherwise rerender all visible rows.

Detached nodes are retained only as long as required to preserve row identity during an active buffer edit or execution. Normal unmodified refresh can release unreachable nodes.

## 13. Per-node Sorting

The sort callback has the shape:

```lua
sort = function(parent_entry, a, b)
  return a.name < b.name
end
```

`parent_entry`, `a`, and `b` are read-only public Entry projections with the exact Section 4 value contracts. For the root's children, `parent_entry` is the root Entry: its `relative_path` and `name` are `""`, its `absolute_path` is `instance.root`, its IDs are positive integers, and its `kind` is `"directory"`. The default comparator places directories before non-directories, then compares names case-insensitively with a deterministic original-name fallback.

Sorting rules:

- A directory sorts only its direct children.
- The root sorts its own direct children.
- Loading, watch refresh, write reconciliation, and explicit `refresh()` sort as part of their normal work.
- The flattened view never runs a global sort.
- A custom comparator is responsible for providing a valid strict ordering.
- Comparator failures surface as Vim errors.
- User buffer line ordering has no filesystem meaning.
- A successful refresh restores configured sibling ordering.

`instance:set_sort(fn)` first checks that the buffer is unmodified. Only then does it replace the instance comparator and call normal `refresh()`. It does not use sort generations, node-dirty flags, or a separate sort action.

If the asynchronous refresh later fails, the new comparator remains installed and the error is reported. A later successful refresh uses that comparator.

## 14. Buffer Representation

A Fre buffer is an editable `acwrite` buffer. Existing rows contain a concealed identity marker, configured real-text columns, and one final root-relative path field:

```text
<marker><icon> <permissions> <mtime> src/
<marker><icon> <permissions> <mtime> src/a.ts
<marker><icon> <permissions> <mtime> src/lib/
```

Only the path is a filesystem-name field in the first implementation. Directories end with `/`; files and symlinks do not.

### Physical stable-ID encoding

Existing rows store identity as concealed physical text. The marker is:

```lua
"\31fre:" .. base36(instance_id) .. ":" .. base36(node_id) .. "\31"
```

The complete physical row is:

```text
<marker><dynamically padded column 1><space>...<dynamically padded column N><space><root-relative path>
```

When no columns are configured, the path immediately follows the marker.

`\31` is the ASCII unit-separator byte `0x1f`. Fre reserves a leading unit-separator for its row protocol. A newly typed line normally has no marker or generated columns and consists only of path text. Consequently, an unmarked row whose first byte is `0x1f` is not representable: it collides with the reserved marker prefix and produces a row-specific prepare error.

Raw APIs such as `nvim_buf_get_lines()` return marker, columns, and path. Public Fre entry/path APIs return parsed entry data and path rather than the protocol bytes.

The physical-row decoder applies these rules:

- No leading unit-separator: apply `vim.trim()` to the complete row and treat the result as the proposed path.
- A leading unit-separator must begin a complete `\31fre:<instance-id>:<node-id>\31` marker. Any other unmarked row beginning with `0x1f`, including an invalid or truncated reserved prefix, is a row-specific prepare error.
- A complete marker for the current instance and a live snapshot node: parse columns with the current instance's descriptors and treat the row as an existing occurrence.
- A complete marker for another live instance and node: parse columns with the source instance's descriptors and treat the row as a cross-instance copy source.
- An unknown instance, unknown node, or invalid marker syntax is a row-specific prepare error.
- A syntactically valid marker is authoritative. Numeric node-ID collisions across instances cannot bind because the instance namespace is part of the marker.

The leading-byte restriction is deliberately narrow. Fre does not reject a valid marked row merely because its retained path begins with `0x1f`, and it does not reject loaded paths, marked move targets, or internal path components containing `0x1f`; only an otherwise unmarked physical row beginning with the reserved byte is ambiguous.

Fre deliberately does not restore damaged markers. Completely removing a marker makes the remaining text an unmarked new row unless its new first byte is the reserved `0x1f`; the original local ID then has zero occurrences, so confirmation shows the resulting delete plus create. A partially damaged reserved prefix is an error.

### Conceal and highlights

Fre installs a buffer-local syntax conceal rule matching the physical marker prefix. Conceal follows marker text after ordinary yank, paste, move, undo, and redo; it does not depend on copying an extmark.

Fre windows default to `conceallevel = 3` and `concealcursor = "nvic"`. Users who override these required presentation options may see the physical protocol bytes.

Configured columns are ordinary buffer bytes. Extmarks may highlight parsed column ranges, but they do not supply row identity, column text, or repair metadata. Extmarks are not required to survive yank/paste.

### Dynamic layout, parsed ranges, and read-only columns

Each unmodified projection render follows the same table-layout model:

1. Run every configured descriptor's `render(entry, ctx)` callback for every currently visible row and retain the raw text plus optional highlight.
2. For each column, compute the maximum `nvim_strwidth()` of its raw rendered text across those rows, with a minimum width of one display cell.
3. Pad each raw field with ASCII spaces to that render's column maximum according to the descriptor's `align` value of `"left"`, `"center"`, or `"right"`. Center alignment puts `floor(total_padding / 2)` spaces on the left and the extra space on the right when total padding is odd, matching Oil's conventional behavior.
4. Join adjacent physical fields with exactly one ordinary ASCII space and append the final root-relative path after the last ordinary ASCII-space separator.

Rendered column text must be valid UTF-8, remain on one line, and contain no C0 control or DEL byte. Fre does not truncate column text. Widths are derived anew from the complete visible projection; descriptors do not configure permanent widths. The width vector is rendering and patch state only: the view retains it solely to decide how much of an unmodified projection can be patched. Physical fields remain ordinary real buffer text separated by ordinary ASCII spaces; there is no hidden path delimiter or other layout metadata.

`buffer.lua` owns the one shared physical-row decoder; this does not add another architecture layer. The decoder resolves marker/source identity, delegates configured field grammar to `columns.lua`, and returns marker/source resolution data, parsed semantic field values, actual consumed byte ranges, the normalized path, and its exact retained byte range. Cursor logic and `mutation/prepare.lua` call this decoder. `prepare.lua` owns occurrence interpretation and Plan construction, not a duplicate row parser.

After resolving a marker to a local or foreign source node, the decoder selects that source instance's descriptors and invokes them sequentially:

```lua
parsed_value, remaining_suffix = descriptor.parse(unconsumed_suffix, ctx)
```

The parse contract is exact:

- `unconsumed_suffix` is the literal physical row suffix remaining when that descriptor is called. It need not begin at a canonical visual column boundary.
- `ctx` includes the read-only source entry projection, descriptor configuration, column index, and whether this is the last configured column. It does not include the marker owner's current or historical dynamic width vector.
- The callback owns a deterministic, width-independent grammar for its rendered semantic value and required separator. Oil-style, it may consume leading or trailing alignment whitespace, the field separator, and leading alignment whitespace that visually appears to belong to the next field. Inter-field ASCII whitespace is grammar-consumed and has no immutable visual-column owner.
- The callback must make progress and return a `remaining_suffix` that is a strictly shorter literal byte suffix of `unconsumed_suffix`. The next descriptor parses exactly that returned suffix.
- The framework rejects a thrown error, nil result, unchanged or longer suffix, a result that is not a literal byte suffix of the input, or any other no-progress/malformed return. Each descriptor's half-open byte range records the bytes it actually consumed, even when that differs from rendered visual ownership.
- Each descriptor supplies `equals(entry, parsed_value, ctx)`. A semantic mismatch or callback error means the read-only field no longer matches the referenced source-node snapshot and produces a row-specific prepare error.

Built-in parsers use self-delimiting grammars for icons, permissions, and configured time formats. A custom renderer may contain ordinary spaces only when its paired parser can consume that grammar deterministically. Parsing does not infer a hidden delimiter, rerender bytes to discover a boundary, consult any current or historical width vector, or repair malformed fields. A missing or invalid separator required by a descriptor's grammar is a parse error. Parseable edits confined to alignment or separator whitespace are not independently detected as read-only metadata changes; successful write reconciliation normalizes them by rerendering.

After the final descriptor returns, the decoder applies `vim.trim()` semantics to the entire literal remaining suffix and uses the retained bytes as the root-relative path. It performs the same operation on the complete text of every new unmarked row. The exact path range is the half-open physical-row byte span `[start_byte, end_byte)` retained after removing boundary whitespace: `start_byte` advances past trimmed leading bytes and `end_byte` retreats before trimmed trailing bytes. Last-column padding and its required separator are already part of the descriptor's actual consumed range. When no columns are configured, the marker is followed directly by the path suffix and the same retained-range calculation applies. If trimming retains no bytes, the normalized path is empty and its range is the zero-width insertion boundary `[line_byte_length, line_byte_length)` at end-of-line so the row can be repaired before prepare rejects an empty path. Leading and trailing path whitespace is therefore not round-trippable: it is silently ignored and removed after a successful write and refresh. Internal spaces remain literal. This is an explicit accepted trade-off matching Oil's effective behavior.

Editable metadata operations such as `chmod` can be added later only through an explicit column mutation contract.

### Cursor behavior

Normal and Visual mode may enter every visible column. `CursorMoved` clamps only positions that enter the concealed marker, moving them to the first visible column or directly to the path when no columns are configured. Thus `0` reaches the first visible column and ordinary Visual-mode yank can copy column text.

Insert mode remains path-only. `InsertEnter` prepositions the cursor at the first retained path byte for an existing row. `InsertCharPre` is the authoritative check immediately before every inserted character and moves a cursor in the marker or read-only columns to that byte. `CursorMovedI` maintains the same rule during insert-mode movement. These autocmds use the decoder's exact retained path range, never the raw suffix start; an empty-after-trim marked row uses its end-of-line zero-width insertion boundary so it can be repaired. New unmarked rows have no generated column boundary and are edited normally.

If a row begins with Fre's reserved prefix but its marker or column fields cannot be parsed, `InsertEnter` and `InsertCharPre` reject insertion with a row-specific Vim error and insert no byte. Fre does not guess a path boundary or postpone this particular safety decision until `prepare()`.

### `instance:get_pos(path)`

`get_pos()` accepts only a root-relative snapshot path. It applies the same lexical root-relative filesystem-semantic normalizer used by Entry values, including `/` separators and equivalence of one display-only trailing slash (`src` equals `src/`), without `vim.trim()` or removal of meaningful path whitespace. It resolves that normalized snapshot node through `nodes_by_path` and requires the node to be visible. Its row extmark is only a fast hint:

1. If the hinted row still contains that node's exact local namespaced marker, decode that row and return its position.
2. Otherwise scan current buffer rows for that exact marker; this is an identity scan, never a scan or index for arbitrary edited path text.
3. If exactly one row matches, rebind the node row extmark to it and use it.
4. If multiple rows match and the old hint matches one, the hinted occurrence remains authoritative. If the old hint does not match, choose the lowest matching row deterministically and rebind.
5. If no row matches, return `nil`.

The return value is `{ row, col }`, with a 1-based row and 0-based UTF-8 byte column directly passable to `nvim_win_set_cursor()`. `col` is the selected row decoder's exact first retained path byte after the real columns and `vim.trim()` boundary normalization. When trimming retains an empty path, `col` is the end-of-line zero-width repair boundary.

It also returns `nil` when the snapshot path is absent or its node is collapsed or otherwise not visible. Unsaved renamed paths are not lookup keys until successful write reconciliation. A decode error on the selected row, including malformed marker, descriptor grammar, semantic fields, or retained path grammar, raises a Vim error identifying that row.

The fallback runs only when `get_pos()` or an already-required internal lookup explicitly needs this contract. Fre adds no `TextChanged` bookkeeping, changed-range marker registry, or live edited-path index. A full refresh recreates canonical row extmarks.

Fre does not remap the complete Vim operator language or automatically repair destructive edits. Consequences are explicit:

- `dd` followed by `p` carries the physical marker and columns; `get_pos()` self-heals to the pasted occurrence when the old hint no longer matches.
- Same-instance `yy`/`p` creates another occurrence of the same local stable ID and therefore expresses copy according to Section 30. If the duplicate is pasted before the original, the still-matching original hint remains authoritative; if the hint is unavailable, the lowest duplicate is chosen.
- Cross-instance `yy`/`p` retains the source namespace and expresses copy from the source node into the destination root.
- Undo and redo preserve physical marker semantics. A later `get_pos()` validates its hint and deterministically rebinds after either operation when needed.
- Visual and characterwise yanks can select real column text.
- Editing only the final path preserves identity.
- Editing a read-only column's semantic value while retaining the marker causes `prepare()` and `get_entry()` to error; parseable alignment or separator whitespace alone is normalized by successful write reconciliation.
- Commands such as `cc` or `d0` that completely remove the marker are interpreted as delete plus create, and the default confirmation displays both operations.
- A partially damaged marker produces a row-specific error rather than automatic recovery.

### Programmatic buffer changes

Fre suppresses its own bookkeeping while applying projection patches. It never edits a modified row merely to repair marker, column, or descendant path text.

After a successful programmatic projection commit:

- The buffer remains or becomes `nomodified` according to the refresh/reconciliation caller.
- The cursor and each window view are restored where possible.
- Raw columns are rendered for the complete visible projection and a new dynamic width vector is computed.
- If the width vector is unchanged, only affected rows need replacement; if any width changes, every visible row is rerendered so padding remains aligned.
- Stable markers, columns, highlights, and lookup extmarks are regenerated from reused node IDs.
- View records the exact projected local stable-ID baseline.

Fre never performs an automatic descendant-prefix rewrite after a directory row edit. The buffer remains exactly the user's draft until prepare and the subsequent write workflow reconcile it.

## 15. Buffer-local Metadata and Options

Every buffer receives required defaults:

```lua
vim.bo[bufnr].buftype = "acwrite"
vim.bo[bufnr].filetype = "fre"
vim.bo[bufnr].bufhidden = "hide"
vim.bo[bufnr].swapfile = false
vim.bo[bufnr].buflisted = false
```

Configured buffer options are then applied. Overriding required options is allowed as an advanced user choice, but documentation must state that changing `buftype` can disable normal `BufWriteCmd` behavior.

Fre reserves one serializable metadata variable:

```lua
vim.b[bufnr].fre = {
  version = 1,
  instance_id = instance.id,
  root = instance.root,
  gc_group = instance.config.gc.group,
}
```

The full effective configuration is not stored in `vim.b` because mappings, sort callbacks, and column descriptors contain Lua functions. It remains available through `fre.get_instance(bufnr).config`.

User-provided `buffer.variables` are copied into `vim.b` after the reserved metadata is installed. They cannot overwrite `vim.b.fre`.

Configuration validation recursively restricts `buffer.variables` to serializable booleans, numbers, strings, sequential arrays, and string-keyed tables containing the same value types. It rejects functions, userdata, threads, cyclic tables, mixed unsupported key types, and other values that cannot be represented safely as buffer variables.

## 16. Real Columns

Column configuration uses explicit constructors:

```lua
local columns = require("fre.columns")

columns = {
  columns.icon(),
  columns.permissions(),
  columns.mtime({ format = "%Y-%m-%d %H:%M" }),
  columns.custom({
    id = "custom",
    align = "left",
    render = function(entry, ctx)
      return "text", "FreCustomColumn"
    end,
    parse = function(suffix, ctx)
      local value, remaining = suffix:match("^%s*(text)%s+(.*)$")
      return value, remaining
    end,
    equals = function(entry, parsed_value, ctx)
      return parsed_value == "text"
    end,
  }),
}
```

A column constructor returns a descriptor containing:

- Stable column identity.
- Alignment policy.
- Metadata requirements.
- A deterministic render callback returning text and optional highlight.
- A deterministic parse callback consuming bytes according to its width-independent field/separator grammar and returning semantic value plus a strictly shorter literal suffix.
- An `equals` callback comparing parsed semantics with the referenced snapshot entry.

The framework owns per-render dynamic width calculation and padding. The shared `buffer.lua` decoder owns sequential callback validation, path-suffix trimming, and actual-consumption byte-range accounting while delegating field grammar to these descriptors. Parsing has no alternate hidden delimiter, permanent width, or dependency on the marker owner's current or historical width vector.

Columns render as real text between the concealed marker and final path. The view writes complete row strings with `nvim_buf_set_lines()`; extmarks apply highlights only.

Consequences:

- Ordinary Vim yanks can include column text.
- A linewise yank also contains the concealed marker, which is required for same- and cross-instance filesystem copy semantics.
- Columns participate in line parsing and byte-range calculation.
- Editing column bytes marks the buffer modified.
- The first implementation rejects semantic metadata changes and descriptor grammar failures during `prepare()` rather than executing metadata mutations; parseable alignment or separator whitespace is not a semantic change.
- Refresh rerenders columns only while the buffer is unmodified or through the private locked write-reconciliation path.
- An unchanged dynamic width vector permits affected-row replacement; a changed vector requires complete visible-row rerendering.
- Custom render/parse/equality behavior must be deterministic and satisfy the progress-making literal-suffix contract.
- Custom columns can use node metadata and instance context.

The built-in icon column uses generic Fre icons by entry kind. Users who want extension-specific icons can implement a custom column using any icon provider.

## 17. Hidden-file State

A hidden entry is a child whose basename begins with `.`. Fre does not add platform-specific hidden-attribute semantics in the first implementation.

The instance owns one mutable boolean hidden-file state.

```lua
instance:set_hidden_file(true)
instance:toggle_hidden_file()
```

Changing this state filters each affected directory node's `children_order` during projection; it does not remove cached nodes.

Because filtering inserts or removes rows, both methods fail while the buffer is modified.

The state is inherited from a predecessor unless explicitly overridden by `new.hidden_file`.

## 18. Expand and Collapse

`instance:expand(path)` accepts a directory path anywhere under the root.

Expansion walks path segments from the root:

1. Ensure the current parent is loaded.
2. Resolve the next child by normalized path.
3. Verify that the child is a directory.
4. Mark it expanded.
5. Load its direct children if needed.
6. Continue until the requested directory is expanded.

This allows one call to establish a deep path even when intermediate directories have not yet been loaded.

For branches such as:

```text
src/x/x/x/
src/x/y/
src/y/x/
```

Fre shares the loaded `src` and `src/x` prefixes. Each directory exists once in the node tree and is read at most once per active load generation.

### Incremental projection

- Expanding a visible directory logically inserts one contiguous DFS subtree after its row.
- Collapsing a visible directory logically removes one contiguous descendant range.
- Every projection change renders raw columns for all resulting visible rows and recomputes the dynamic width vector.
- When that vector is unchanged, the view applies only the contiguous subtree insertion/removal and affected row replacements.
- When any width changes, the view rerenders all visible rows because every row's padding may change.
- `visible_size` tracks the current visible subtree size.
- Later-row extmarks move automatically when lines are inserted or removed.
- `get_pos(path)` resolves the visible snapshot node through `nodes_by_path`, validates its row-extmark hint against the exact marker, and performs the on-demand exact-marker fallback from Section 14 when needed; it never indexes arbitrary unsaved path text.

### Collapse retention

Collapsing a directory:

- Sets that directory's active visibility to collapsed.
- Removes descendant rows.
- Stops watchers in the newly inactive subtree.
- Retains loaded child nodes and descendant `expanded` flags.

Re-expanding the directory can restore cached deep expansion immediately, followed by asynchronous refresh.

## 19. Reveal

`instance:reveal(path)` receives only a path.

It does not accept layout and never calls `open()` or `toggle()`.

It performs:

1. Normalize and verify that the path is under the instance root.
2. Determine the target's parent directory.
3. Expand the complete parent chain.
4. Record the target path as the instance's reveal target.
5. Convert the resolved snapshot target to its root-relative key and resolve the final cursor tuple with `get_pos(path)`.
6. If the instance is visible in the current tab, pass that tuple to `nvim_win_set_cursor()`.
7. If hidden, retain the target so a later `open()` or `toggle()` can position the cursor.

Multiple overlapping reveal requests use latest-target-wins cursor semantics. Directory loads already started for an older request can still populate cache.

If the target is excluded by hidden-file filtering, reveal reports a Vim error and asks the caller to enable hidden files explicitly.

If the buffer is modified:

- Revealing an already visible path is allowed.
- Revealing a path that requires expansion fails under H1.

## 20. Expansion Inheritance

New and old instances never share node objects. Inheritance exports an immutable path snapshot from the predecessor:

```lua
ExpansionSnapshot = {
  root = "/project",
  expanded = {
    ["/project/src"] = true,
    ["/project/src/x"] = true,
    ["/project/src/x/x"] = true,
    ["/project/src/x/x/x"] = true,
    ["/project/src/x/y"] = true,
    ["/project/src/y"] = true,
    ["/project/src/y/x"] = true,
  },
}
```

The snapshot includes all directories with `expanded = true`, including descendants currently hidden behind a collapsed ancestor.

### Re-rooting

For a new root, Fre:

1. Keeps expanded paths located under the new root.
2. Treats the new root itself as implicitly open.
3. Preserves collapsed barriers instead of force-expanding them.
4. Synthesizes only ancestor expansion that did not exist in the predecessor because the new root is above the old root.
5. Drops state for unrelated path trees.

Examples:

- Old `/project`, new `/project/src`: retain expansion under `src`.
- Old `/project/src`, new `/project`: expand the connecting `src` path, then restore old subtree state.
- Same root: copy the complete expansion state.
- Unrelated roots: inherit no expansion.

### Pending expansion trie

The new instance stores inherited targets in a prefix trie rather than calling `expand()` independently for every path.

For targets `x/x/x`, `x/y`, and `y/x`, the trie is:

```text
x
├─ x
│  └─ x
└─ y

y
└─ x
```

Each shared directory prefix is loaded once. Pending branches below a collapsed barrier remain dormant until that barrier is expanded.

Missing or no-longer-directory paths remove only their pending branch. They do not fail creation of the whole instance.

Inheritance is a creation-time snapshot. Later expand/collapse operations in either instance never propagate to the other.

## 21. Modified-buffer and Execution Interaction Policy

The editable buffer is the only unsaved draft. While `modified` is true, expand, collapse, toggle-expand, `refresh()` without force, sort, hidden-file/filter changes, and reveal that would change projection fail. `instance:refresh({ force = true })`, window operations, selection of existing snapshot entries, `get_entry`, `get_pos`, explicit force-discard destroy, and `prepare()` remain available. Automatic GC is not available for a modified instance.

`actions.write` requires a normally editable buffer. Before prepare it snapshots only the prior `modifiable` value, makes the buffer nonmodifiable, and owns the write lock through confirmation, execution, reconciliation, and unlock. During that lock, text edits, another write, projection changes, refresh, destroy, and another Execution are rejected; navigation, lookup, window operations, and selection remain available.

Direct `execute(plan)` does not acquire the write lock, snapshot buffer text, or change `modifiable`. It is single-flight only with respect to another active Execution.

Selection uses the source snapshot Entry rather than retained edited destination text. An unsaved renamed or duplicated marked row opens its existing `Entry.absolute_path`; an unmarked new row has no Entry and cannot be selected.

Editing a directory row never rewrites visible descendant rows. Prepare resolves carried descendants from stable identities and ancestor operations. Removing a directory row does not require removing its visible descendant rows; parent shadowing is resolved during prepare.

## 22. Window Layout Primitives

An instance buffer exists independently of windows.

Supported layouts are:

```lua
{ position = "current" }
{ position = "left", size = 40 }
{ position = "right", size = 40 }
{ position = "top", size = 15 }
{ position = "bottom", size = 15 }
{
  position = "float",
  width = 0.8,
  height = 0.8,
  row = 0.1,
  col = 0.1,
  border = "rounded",
}
```

Numeric dimensions can be absolute cells or documented fractional values where supported by the field.

### `instance:open(layout?)`

`open()` ensures the instance is visible in the current tab and returns the resulting window ID.

Resolution order for an omitted layout:

1. The last layout used by this instance in the current tab.
2. The instance's effective layout configuration, which already captured setup at creation.

If one or more windows in the current tab already display the instance, `open()` chooses the current window when it already shows the buffer; otherwise it chooses the valid displaying window with the lowest window ID. A matching layout reuses that window. A different layout closes only the chosen view and recreates it with the same buffer; other views remain.

The instance stores only last-layout preference by tab. It does not maintain a duplicate global window graph.

### `instance:hidden()`

Closes every current-tab window displaying this instance, in ascending window-ID order. It does not delete the buffer or instance.

### `instance:toggle(layout?)`

- Hidden in current tab: open using the requested or resolved layout.
- Visible with the same layout: hide it.
- Visible with a different requested layout: switch layout and remain visible.

The same instance can be displayed in different tabs using the same buffer. Instance GC visibility is global across all windows.

## 23. Action Module

`require("fre.actions")` exports ordinary Lua functions. There is no action registry, string dispatch, action object protocol, or action DSL.

Representative exports are:

```lua
local actions = require("fre.actions")

actions.expand
actions.collapse
actions.toggle_expand
actions.reveal

actions.open
actions.hidden
actions.toggle

actions.set_hidden_file
actions.toggle_hidden_file
actions.refresh

actions.select
actions.tab_select
actions.split_select

actions.confirm
actions.write
actions.destroy
```

An action receives a context and optional options:

```lua
action(ctx, opts)
```

The mapping layer constructs context as:

```lua
ActionContext = {
  instance = instance,
  bufnr = bufnr,
  winid = winid,
  tabpage = tabpage,
  mode = mode,
  row = row,
  col = col,
  entry = entry_or_nil,
  range = visual_range_or_nil,
}
```

`ActionContext.row` is 1-based, matching `get_entry(row)`. `ActionContext.col` is the cursor's 0-based UTF-8 byte offset, matching Neovim's cursor tuple convention. `ActionContext.entry` is exactly the fresh result of `ctx.instance:get_entry(ctx.row)`, including `nil` or its row-specific error; the mapping layer does not reinterpret edited path text.

Actions called manually can use `actions.context()` to build a context from the current editor state.

Thin actions can directly call one instance primitive. Composite actions remain normal functions and can call other actions or primitives.

## 24. Select Actions

The three built-in selection functions differ only in destination strategy. Each requires nonnil `ctx.entry` and opens `ctx.entry.absolute_path`; a nil Entry is a direct Vim error. Thus a marked unsaved rename or copy selects its existing source snapshot, while an unmarked new row cannot be selected.

### `actions.select(ctx, opts?)`

The target window defaults to `ctx.winid`. `opts.target_winid` can explicitly override it. Fre validates that the chosen window still exists before opening either a file or directory; an invalid target is a Vim error.

For a file or symlink:

- Replace the target window's buffer with `ctx.entry.absolute_path`.

For a directory:

1. Validate every supported `opts.instance` override using normal `new()` rules, but reject `opts.instance.root` and `opts.instance.inherit` with direct Vim errors.
2. Create a child instance with the validated overrides, `root = ctx.entry.absolute_path`, and `inherit = ctx.instance`. The action-supplied root and predecessor cannot be overridden.
3. Display the child buffer in the same resolved target window.

The source instance becomes hidden if that was its final visible window.

### `actions.tab_select(ctx, opts?)`

For a file or symlink, open `ctx.entry.absolute_path` in a new tab.

For a directory:

1. Validate supported `opts.instance` overrides and reject `root` or `inherit`.
2. Create a new tab.
3. Create a child instance rooted at `ctx.entry.absolute_path` with `ctx.instance` as predecessor and the validated remaining overrides.
4. Display the child buffer in the new tab's current window.

### `actions.split_select(ctx, opts?)`

Example:

```lua
actions.split_select(ctx, {
  layout = {
    position = "right",
    size = 80,
  },
  instance = {
    gc = {
      group = "project",
      ttl_ms = 10_000,
    },
  },
})
```

For a file or symlink, open `ctx.entry.absolute_path` using the requested split layout.

For a directory, validate the supported `opts.instance` overrides and reject `root` or `inherit`, then compose:

```lua
local child_opts = merge_instance_overrides(opts.instance or {})
child_opts.root = ctx.entry.absolute_path
child_opts.inherit = ctx.instance

local child = fre.new(child_opts)
child:open(opts.layout)
```

The source instance remains visible because the new target uses a split.

Select functions do not require a separate global tab-view data model. They compose the already-resolved snapshot Entry, normal Neovim file opening, `fre.new()`, and instance window primitives. Other child overrides retain normal hidden-state, sort, and expansion inheritance rules.

## 25. Function-based Mappings

Public configuration defaults to:

```lua
use_mapping_default = true
mapping = {}
```

`config.mapping` contains only user override maps. The built-in normal-mode mapping base is a separate internal constant:

```lua
local mapping_base = {
  n = {
    ["<CR>"] = actions.select,
    ["zv"] = actions.expand,
    ["zc"] = actions.collapse,
    ["za"] = actions.toggle_expand,
    ["q"] = actions.hidden,
    ["g."] = actions.toggle_hidden_file,
    ["R"] = actions.refresh,
  },
  i = {},
  v = {},
}
```

User `mapping`, when present, has exactly the named mode tables it overrides. Mapping values are functions. Strings, `false`, and `{ action = ... }` descriptors are not accepted; there is no per-key disable syntax.

Example:

```lua
mapping = {
  n = {
    ["<CR>"] = custom_select,
    ["<C-f>"] = function(ctx)
      actions.toggle(ctx, {
        layout = {
          position = "float",
          width = 0.8,
          height = 0.8,
        },
      })
    end,
  },
}
```

Setup and instance user maps merge by mode and LHS, with the instance value replacing the setup value at the same mode/LHS. Buffer installation is derived once from the final effective configuration:

- With `use_mapping_default = true`, copy the internal base and overlay the merged user mappings by mode and LHS.
- With `use_mapping_default = false`, install only the merged user mappings.
- The internal base is never merged into or exposed through `config.mapping`.
- Insert and visual mode have no built-in defaults.
- Mutable mapping tables are copied; later caller mutation cannot change effective config or installed buffer mappings.

Mappings are buffer-local and receive Fre's action context. The exact built-in normal mappings are `<CR>` select, `zv` expand, `zc` collapse, `za` toggle-expand, `q` hidden, `g.` toggle-hidden-file, and `R` refresh. There are deliberately no built-in `h` or `l` mappings.

## 26. Watch Model

Fre watches only local directories represented by the root or an active expanded directory. Each active directory node owns its own `uv_fs_event_t` handle. This matches the node refresh boundary, avoids platform-dependent recursive watch semantics, lets collapse release an inactive branch, and refreshes only one sibling list for an ordinary event.

### Watch callback

A watcher callback:

1. Verifies that the instance and node are still live.
2. Debounces repeated events for that node.
3. Sets `instance.needs_refresh = true` when the buffer is modified, the instance is hidden, or `actions.write` owns the mutation lock.
4. Otherwise schedules an atomic refresh of that directory node.

The callback does not depend on the event filename because platform support is inconsistent. Watch errors are reported once, stop the affected watcher, and set `needs_refresh`. A later explicit refresh or visibility-triggered refresh recreates required watchers.

`needs_refresh` is a coarse recovery signal, not a three-way merge journal. It records only that the current projection may be stale. A successful full refresh or write reconciliation clears it; failed refresh leaves it set.

### Hidden and visible instances

A hidden instance never patches its buffer in response to a watch event. Instead it sets `needs_refresh`. On the first `BufEnter` or hidden-to-visible transition, Fre runs one full refresh of the root and active expanded directories when the buffer is unmodified and unlocked. Modified or locked buffers retain `needs_refresh` until an explicit discard refresh or write reconciliation succeeds.

## 27. Refresh and Async Coordination

### Public refresh

The normative public forms are `instance:refresh()` and `instance:refresh({ force = true })`. `opts` may be omitted and otherwise accepts exactly optional `force` and `on_complete` fields. `force` defaults to `false` and must be boolean. `on_complete`, when present, must be a function receiving `err`, where success passes `nil`. Invalid options are synchronous public-misuse errors.

Before scheduling I/O, refresh synchronously rejects a destroying or destroyed instance, a creating instance whose initial attempt is still active, and any instance whose `actions.write` lock is active. `force = true` does not bypass the write lock. A load-failed instance instead transitions to creating and starts a fresh initial-load attempt. Ready instances reload the root and every active expanded directory.

When the ready buffer is modified, omitted or false `force` raises synchronously and changes nothing. `force = true` is explicit caller authorization to discard modified text without prompting. The old text remains untouched until the complete candidate succeeds; success atomically replaces it and marks `nomodified`, while failure preserves it and reports the asynchronous error.

Refresh returns `nil` immediately after scheduling. It calls `on_complete(err)` exactly once on Neovim's main loop when supplied. Without `on_complete`, an asynchronous failure uses Fre's standard error reporter. Synchronous precondition and option errors never schedule I/O or invoke the callback.

The built-in `actions.refresh` calls ordinary `instance:refresh()` for an unmodified buffer. For a modified buffer it prompts first; confirmation calls the same public `instance:refresh({ force = true })`, while cancellation leaves the draft unchanged.

Every refresh first scans and builds a complete candidate tree and view without mutating authoritative nodes, buffer text, extmarks, or `modified`. Only after every required scan, sort, column render, and validation succeeds does one commit replace the tree/view and projection. A successful commit records the exact projected stable-ID baseline, clears `needs_refresh`, and marks the buffer `nomodified`. A failed candidate changes nothing and leaves `needs_refresh` set.

### Write reconciliation

`actions.write` owns a private reconciliation path that may replace its modified, locked source buffer. `execute()` never calls this path and never refreshes instance state.

After `execute()` has started, `actions.write` always attempts reconciliation after success, failure, or cancellation. It scans the root first, then only formerly active expanded paths that still exist as directories through candidate ancestor chains. Completed deletion or movement of an expanded directory prunes that branch normally. A successful candidate atomically commits filesystem truth, discards the stale draft, records a new projected baseline, clears `needs_refresh`, marks `nomodified`, and then unlocks.

If reconciliation fails, `actions.write` reports both the execution outcome and reconciliation error, unlocks without claiming that the old text matches the filesystem, sets `needs_refresh`, and leaves `instance:refresh({ force = true })` as the explicit recovery route. It does not roll back filesystem effects.

Parse failure and confirmation cancellation happen before `execute()` starts; they unlock and preserve the draft without reconciliation.

### Per-node generation and patch serialization

`load_generation` remains a node-local async race guard for actual directory reads. Starting a newer load invalidates an older callback for that node; different nodes may load concurrently.

Directory reads may finish concurrently, but buffer mutations are queued per instance on Neovim's main event loop. Before applying a completed async refresh, Fre checks that the instance and node are live, the generation is current, the buffer is still unmodified and unlocked, and the node remains relevant. Otherwise the result cannot change buffer text.

## 28. Garbage Collection

GC has two independent policies: hidden TTL per instance and maximum live instances per configured group. Existing configuration shapes and zero-disable semantics remain unchanged.

### Visibility

An instance is visible when `vim.fn.win_findbuf(instance.bufnr)` returns at least one valid window. Manager stores no visibility index. When the first window appears, Fre clears `hidden_since` and invalidates the TTL deadline. When the last window disappears, it records `hidden_since`, schedules TTL when enabled, and enforces group capacity.

A never-opened instance starts hidden. The instance being registered is excluded from its own creation-time capacity candidate set, so `new()` cannot destroy the object it is returning. If all older candidates are visible or modified, temporary overflow is allowed and capacity is reconsidered on the next ordinary trigger.

### TTL and group capacity

- `ttl_ms > 0` attempts automatic destruction after that continuous hidden duration; zero disables TTL.
- `setup.gc.groups[name] > 0` caps the group; zero disables capacity GC.
- Showing an instance resets its hidden interval.
- Capacity selects the oldest eligible hidden instance by `hidden_since`, with creation sequence as the deterministic tie-breaker.
- Visible, modified, newly registering, and nonterminal-execution instances are not automatic GC candidates.
- TTL and capacity are independent; both zero means manual lifetime.

An unknown group passed to `new()` is a configuration error. A repeated `setup()` that omits or changes away a group still referenced by any live instance is rejected atomically; defaults and capacity maps remain unchanged. Existing groups can be removed after their last instance is destroyed.

### Modified buffers and explicit destruction

Automatic TTL and capacity GC never discard a modified buffer. It drops that candidate and considers the next eligible hidden instance for capacity. Explicit `destroy()` remains a force-discard operation when no Execution is active. Any destruction attempt during a nonterminal Execution fails without changing the instance.

## 29. User Extension Through Buffer Data

Fre provides metadata and options but does not impose editor policy.

For example, users can implement automatic window-local cwd:

```lua
vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(args)
    local data = vim.b[args.buf].fre
    if data then
      vim.cmd.lcd(vim.fn.fnameescape(data.root))
    end
  end,
})
```

Users can also inspect full Lua configuration or call instance primitives:

```lua
local instance = require("fre").get_instance(args.buf)
if instance then
  -- user policy
end
```

Fre's responsibilities end at providing stable buffer identity, root metadata, filetype, options, and Lua APIs.

## 30. Preparing a Mutation Plan

`instance:prepare()` is the default compiler from the current editable projection to a complete executable Plan. It requires an initially ready instance, is deterministic over the last successful snapshot, current buffer lines, projected baseline IDs, stable markers, and live foreign marker sources, and performs no filesystem I/O or buffer mutation.

Prepare owns all interpretation and planning: row parsing, occurrence classification, conflict checks, dependency ordering, move-cycle lowering, final operation order, and user-facing display. `execute()` never repeats those decisions.

### Path parsing

Each row is decoded by the one shared `buffer.lua` physical-row decoder. Marked rows parse configured descriptors and apply `vim.trim()` to the remaining suffix; unmarked rows apply `vim.trim()` to the whole row. Prepare preserves the existing marker namespace, descriptor equality, exact retained byte ranges, required directory trailing `/`, reserved leading `0x1f` rule, newline rejection, internal-space behavior, and stable-kind checks.

Prepared destination paths use normalized internal `/` separators, reject absolute or empty editable paths, reject `.` and escaping `..`, cannot target the instance root, and resolve to normalized absolute paths lexically inside the destination root. These checks describe `prepare()` output only; they are not a sandbox imposed on caller-created Plans.

### Projected deletion baseline

Every successful initial render, refresh, or write reconciliation stores the exact set of local stable IDs projected into the buffer. Occurrence counting during prepare ranges only over that baseline.

For each baseline ID:

- Zero valid local occurrences emits one delete of the original entry.
- One occurrence at the original normalized path is unchanged; one at another path is a move.
- Multiple occurrences retain the original when present; otherwise the deterministic primary destination becomes the move and other distinct destinations become copies.

Filtered, collapsed, or otherwise nonprojected cached nodes are absent from the baseline and never imply deletion merely because their rows are not present. Removing a projected directory row emits one directory delete operation; its unchanged descendants are carried by that directory operation rather than expanded into descendant deletes.

### Ancestor operations and duplicate occurrences

Prepare determines ancestor directory moves, copies, and deletes before classifying descendant occurrences. An unchanged descendant carried by an ancestor directory operation emits no redundant operation. A descendant explicitly moved or copied outside an ancestor target remains an operation and is ordered before the ancestor operation that would remove its source.

Fre does not rewrite visible descendant row text when a directory row is edited. This avoids letting a duplicated copy occurrence mutate the original subtree. Parent-carried descendant semantics are resolved only by prepare from stable identities and normalized paths, independent of buffer row order.

When no occurrence retains the original path and no ancestor determines the carried target, the lexicographically smallest normalized target is the move target and remaining distinct targets are copies. Duplicate target paths are rejected.

### Foreign instance occurrences

A marker from another live instance is a copy source, never a move or destination-owned occurrence. The shared decoder resolves the foreign source snapshot and descriptors, validates semantic read-only fields and kind syntax, and prepare emits one copy from that absolute snapshot path to the destination target.

The source instance and node must remain live until prepare resolves them. Once the Plan contains the absolute source path, later source destruction does not change that Plan. Source and destination may use different column descriptors; successful destination reconciliation renders destination columns.

### New rows, shadowing, and conflicts

Unmarked rows ending in `/` produce `create_directory`; other unmarked rows produce empty `create_file`. A directory action always remains one Plan operation. Prepare never expands a directory into descendant operations.

A parent directory delete shadows redundant descendant deletes and unchanged descendants whose final result remains in that subtree. Descendant moves or copies preserving data outside it remain explicit and are ordered first.

Default prepare rejects duplicate normalized targets, creates targeting occupied snapshot paths unless the Plan first vacates them, copy source equal to target, a directory copy/move target inside its source, incompatible ancestor/descendant outcomes, malformed or ambiguous markers, descriptor errors, and read-only-column changes. These checks make prepared Plans coherent; caller-created Plans are not required to satisfy them.

### Move cycles

Prepare lowers move cycles before returning. For `a -> b` and `b -> a`, `plan.operations` contains the actual ordered rename sequence through a collision-resistant temporary sibling path. Longer and case-only cycles use the same technique.

Temporary rename operations are real Plan operations and are executed in array order. They may be omitted from `plan.display`, which remains the user-facing summary. Failure or cancellation can leave a temporary path; Fre performs no rollback.

## 31. Plan Format

A Plan is ordinary caller-owned Lua data:

```lua
Plan = {
  operations = {
    { type = "move", from = "/project/a", to = "/project/b", kind = "file" },
    { type = "copy", from = "/project/src", to = "/project/src-copy", kind = "directory" },
  },
  display = {
    "MOVE  a -> b",
    "COPY  src/ -> src-copy/",
  },
}
```

The conventional operation shapes are:

```lua
{ type = "create_file", path = absolute_path }
{ type = "create_directory", path = absolute_path }
{ type = "copy", from = absolute_source, to = absolute_target, kind = kind }
{ type = "move", from = absolute_source, to = absolute_target, kind = kind }
{ type = "delete", path = absolute_path, kind = kind }
```

where `kind` is `file`, `directory`, or `symlink`. Prepared Plans use these shapes, normalized absolute paths, and root-relative display for in-root paths. External copy sources may be displayed absolutely or with their live source-instance label.

Plan has no version, generation, provenance, capability, timestamp, opaque identity, or prepare-only restriction. Callers may create or modify a Plan and pass it directly to `execute()`. The caller owns its ordering, paths, conflicts, operation fields, and display consistency.

`execute()` ignores `display`. It does not run a whole-Plan validator. If an operation is unknown or lacks data needed by its filesystem primitive, execution fails when it reaches that operation; earlier operations remain completed.

## 32. Confirmation and `:write`

Fre buffers use `BufWriteCmd`. The default workflow belongs entirely to `actions.write`:

```text
require initial readiness
-> acquire the instance write lock and make the source buffer nonmodifiable
-> instance:prepare()
-> actions.confirm(ctx, plan.display)
-> instance:execute(plan, handlers)
-> reconcile filesystem truth after success, failure, or cancellation
-> restore modifiable and release the lock
```

The lock prevents a second write, projection change, refresh, destroy, or text edit. Navigation, lookup, window operations, and selection remain available. Direct `execute()` neither acquires this buffer lock nor snapshots, refreshes, or mutates tree/view/buffer state.

Parse or confirmation failure happens before execute starts: the workflow unlocks, restores the prior `modifiable` value, and preserves the modified draft. Once execute starts, the workflow always follows Section 27 reconciliation rules.

### Empty Plan

When prepare emits no operations, `actions.write` skips confirmation and progress, uses its private reconciliation path to normalize the projection, marks `nomodified` on success, and unlocks. It does not call either public refresh form because the write lock remains active.

### Confirmation

Default confirmation requires the prepared `display` string array and presents it verbatim in a temporary read-only scratch view. It does not derive content from operations or inspect Plan validity. Cancellation executes nothing and preserves the draft.

Caller-created Plans may use any display content or omit display when bypassing the default presenter. Users can compose prepare, another confirmation UI, and execute directly.

### Progress presentation

Only `actions.write` creates the default immediate, cancellable progress float. It renders the Execution's current operation, optional adapter detail, completed/total Plan operation counts, and cancel hint. Temporary operations count as operations but need not appear in confirmation display.

Closing the float requests cancellation; losing focus alone does not. Terminal completion closes it and presents the execution outcome followed by any reconciliation error. Presentation never changes Execution state or callback cardinality.

### Direct execution

`instance:execute(plan, handlers_or_callback)` performs no confirmation, buffer locking, progress UI, refresh, or reconciliation. The caller observes its Execution and is responsible for refreshing any affected Fre instances.

## 33. Executor Model

`instance:execute(plan, handlers_or_callback)` is asynchronous and single-flight per instance. It trusts the supplied Plan and immediately creates an Execution over the supplied `operations` array. A concurrent Execution on the same instance is rejected.

Handlers may contain `on_progress(progress)` and `on_complete(err, result)`, or a function may be shorthand for completion. Execution exposes only `cancel()` and `get_status()`. Callbacks are protected and completion is attempted exactly once.

### State and progress

State transitions are:

```text
running -> succeeded
running -> failed
running -> canceling -> canceled
running -> canceling -> failed
```

There is no preparing or refreshing Execution phase. Status contains state, completed, total, current operation, and optional adapter detail. Counts refer directly to entries in `plan.operations`, including prepare-generated temporary renames.

Execution dispatches operations strictly in array order and starts the next only after the current filesystem primitive completes. It does not reorder, merge, lower, append, infer dependencies, validate display, inspect prepare provenance, compare snapshots, or perform complete-plan filesystem preflight.

Filesystem primitives may use multiple asynchronous requests internally to implement one whole-directory copy or delete, but they do not expose descendant Plan operations. Adapter detail may describe internal progress without changing Plan totals.

### Operation semantics

- `create_file` creates one empty file; an occupied target is an execution error.
- `create_directory` creates the planned directory; parents are not invented unless earlier operations create them.
- `copy` invokes the adapter's one whole-entry copy primitive for the declared kind. Symlink copy copies the link itself.
- `move` invokes exactly one filesystem rename from `from` to `to`, regardless of kind.
- `delete` invokes the adapter's one whole-entry delete primitive for the declared kind. Symlink delete removes the link itself.

Move has no implicit `EXDEV` or other copy-delete fallback. A cross-filesystem rename fails unless the caller or prepare explicitly supplied different operations. Execution never invents such operations after confirmation.

### Failure and cancellation

At the first operation or adapter failure, Execution stops scheduling later Plan entries, records the current operation and whether an effect may be partial, transitions to failed, and invokes completion. Completed effects are never rolled back.

`cancel()` is accepted once while running, requests cancellation of the active adapter request when possible, and prevents later Plan operations from starting. If the active request cannot be canceled, its completion is handled once and no new operation is scheduled. Cancellation does not refresh buffers or delete partial targets or temporary paths.

The result reports terminal status, completed/total, current operation when any, and `partial_current` as false, true, or unknown. Exact libuv request bookkeeping and late-callback resource closure are implementation details, not public Plan or acceptance contracts.

## 34. External Changes and Optimistic Execution

Prepare compares edited rows with the last successful projected snapshot. It does not merge external changes. Execute applies caller-supplied operations to the filesystem as it exists when each operation runs; normal filesystem failures report conflicts.

An unrelated external create or rename does not invalidate a prepared Plan. After default write execution, reconciliation shows the new truth. If an external process already deleted or moved a source, the corresponding user operation fails when reached.

Watch events during hidden, modified, or locked states set `needs_refresh`. The next eligible visibility refresh, explicit refresh, or write reconciliation clears it after successfully committing filesystem truth.

## 35. Local Path and Symlink Rules

The path module owns platform-aware lexical normalization, Windows drive and separator handling, practical ASCII case-insensitive equality on Windows, root-relative display conversion, and temporary sibling-name generation.

`instance.root` is the stable lexical normalized absolute root. Initial loading may resolve an internal real root for scanning, but execute does not provide a root sandbox for caller Plans and performs no whole-plan or per-operation containment, `realpath`, or `lstat` preflight.

Default prepare emits root-contained mutation targets and may accept an external absolute `copy.from` because copy does not mutate that source. Caller-created Plans are trusted and may contain paths outside the instance root; the caller assumes that power and risk.

Symlinks are represented from loaded `lstat` data, are not expanded as directories, and selection delegates their path to normal Neovim opening. Prepared move, copy, and delete operations act on the link itself rather than following its target.

## 36. Error Handling

Fre uses a small error model:

- Setup/new misuse and prepare errors raise direct Vim/Lua errors before a Plan is returned.
- Row errors identify the row and retained path; prepared conflict errors identify paths.
- Execute reports an operation dispatch or filesystem error when that operation is reached; earlier effects remain.
- Watch errors identify the directory, set `needs_refresh`, and stop the watcher.
- Reconciliation errors leave `needs_refresh`, unlock the buffer, and expose `instance:refresh({ force = true })` recovery.
- Progress and completion handler errors surface without changing terminal state or callback cardinality.

Fre does not silently repair malformed markers, rewrite caller Plans, fall back from rename to copy-delete, roll back completed filesystem effects, or add warning-only behavior for invalid configuration.

## 37. Suggested Module Boundaries

The exact filenames may change, but these responsibilities form the intended seams:

```text
lua/fre/init.lua                 public setup/new/lookup API
lua/fre/config.lua               defaults, merge, validation
lua/fre/manager.lua              instance indexes, directory takeover, group GC
lua/fre/instance.lua             Instance primitives and active Execution
lua/fre/path.lua                 lexical local-path normalization
lua/fre/fs.lua                   ordinary async directory loading
lua/fre/tree.lua                 nodes, child reconciliation, expansion trie
lua/fre/view.lua                 projection, projected baseline, rendering, needs_refresh
lua/fre/buffer.lua               lifecycle, physical-row decoder, conceal, cursor integration
lua/fre/window.lua               layouts and deterministic multi-window selection
lua/fre/watch.lua                per-directory watchers and debounce
lua/fre/columns.lua              real-column renderers and field grammars
lua/fre/actions.lua              lock, prepare/confirm/execute workflow, reconciliation
lua/fre/progress.lua             private default write-progress presentation
lua/fre/mutation/prepare.lua     occurrence interpretation, ordering, cycles, display
lua/fre/mutation/execute.lua     Plan-order interpretation, Execution state and cancellation
lua/fre/mutation/fs.lua          whole-entry filesystem primitives and test adapter seam
lua/fre/mutation/move_graph.lua  prepare-time move-cycle lowering
lua/fre/gc.lua                   TTL and capacity scheduling
```

Tree owns node relationships and directory-local ordering. Buffer owns one physical-row decoder and delegates field grammars to Columns. View owns projection state, exact projected baseline IDs, and `needs_refresh`. Prepare owns every Plan decision. Execute owns only serial interpretation and Execution observation. Mutation FS exposes whole-entry primitives and hides any adapter-specific directory implementation. Actions owns the buffer lock, confirmation, progress UI, and reconciliation. Manager owns lifetime indexes and process-wide takeover.

## 38. Testing Strategy

Tests prioritize the normal end-to-end buffer file-manager workflow. Temporary real directories cover ordinary integration; a small injectable mutation filesystem adapter scripts failures, cancellation, and partial effects that cannot be induced portably. Tests assert through public interfaces rather than request-generation bookkeeping.

### Pure tests

- POSIX and Windows-shaped lexical normalization, practical ASCII case-insensitive Windows equality, and root-relative display.
- Expansion inheritance, pending tries, sibling sorting, DFS projection, and hidden filtering.
- Marker encoding/decoding, descriptor parsing, retained byte ranges, `vim.trim()` behavior, kind suffixes, and read-only-column errors.
- Projected baseline occurrence interpretation, including collapsed/filtered nodes that must not become deletes.
- Local and foreign marker copies, duplicate occurrence selection, ancestor carrying, directory shadowing, and conflict errors from default prepare.
- Prepare-time dependency ordering and two-node, longer, and case-only move-cycle lowering into actual temporary rename operations.
- Prepared display is produced with the final ordered operation set; arbitrary caller Plan display is not validated.
- Configuration precedence, live-group removal rejection, GC candidate ordering, and mutable-table isolation.
- Execution state, progress copies, exactly-once completion, sequential operation dispatch, and stop-at-first-error behavior.

### Headless Neovim integration

- Initial loading exposes deterministic success and failure completion; methods obey creating, ready, load-failed, and destroyed contracts.
- Directory takeover, marker conceal, real columns, cursor boundaries, mappings, layouts, selection, lookup, expansion, reveal, and inheritance preserve their documented behavior.
- Every successful projection records its exact stable-ID baseline.
- Directory row edits do not programmatically rewrite descendant text; prepare still carries implied descendants, and a duplicate copy occurrence never changes original rows.
- Table-driven public refresh tests cover omitted and false `force`, `force = true`, invalid options, synchronous creating/destroying/destroyed/write-lock rejection with no I/O or callback, load-failed retry, atomic preservation on scan failure, exactly-once `on_complete(err)`, standard error reporting when the callback is absent, and `actions.refresh` prompting before the public force form.
- Hidden, modified, and write-locked watcher events set `needs_refresh`; the first eligible visibility transition refreshes and clears it.
- Multiple windows sharing one instance retain independent cursor/view state while instance content and lifetime remain shared.

### Mutation integration

- Default `:write` locks, prepares, confirms, executes, reconciles, restores `modifiable`, and marks `nomodified`.
- Empty Plan skips confirmation/execution and succeeds through private reconciliation.
- Create, rename, move, copy, delete, cross-instance copy, parent shadowing, and move cycles work through prepared Plans.
- One directory action remains one Plan operation; no descendant operation or recursive Plan progress is exposed.
- Move performs one rename. `EXDEV` fails and never triggers an implicit copy-delete sequence.
- Direct caller Plans execute without readiness, prepare provenance, display validation, root sandboxing, or whole-plan preflight.
- A direct Plan with valid early operations and a later malformed/unknown operation leaves early effects and fails when the invalid operation is reached.
- Execution never refreshes or changes Fre buffer/tree state; its caller is responsible.
- Parse and confirmation cancellation preserve the draft.
- Once execution starts, success, failure, and cancellation all cause `actions.write` to attempt reconciliation. Successful reconciliation shows filesystem truth; failed reconciliation leaves `needs_refresh` and `instance:refresh({ force = true })` recovery.
- Partial filesystem effects are not rolled back.
- The fake mutation adapter deterministically covers first-operation failure, later failure after completed operations, cancelable and noncancelable active work, partial whole-directory operations, and exactly-once completion.

### Watch and GC tests

- Root and expanded-node events use their directory refresh boundaries; collapse releases watchers and re-expansion recreates them.
- Modified/hidden/locked events set rather than lose `needs_refresh`; stale load generations cannot patch the buffer.
- TTL and capacity zero-disable semantics remain independent.
- Visible and modified instances are protected from automatic GC.
- A newly registered hidden instance cannot evict itself; temporary overflow resolves on a later eligible trigger.
- Repeated setup atomically rejects removal of a group used by a live instance.
- Explicit destroy may discard modified text but cannot collide with a nonterminal Execution.

## 39. Acceptance Criteria

The design is implemented successfully when all of the following are observable:

1. A local Fre instance can load asynchronously without a window and exposes deterministic ready or load-failed completion.
2. Its buffer renders editable root-relative paths, real read-only columns, concealed stable markers, and incremental branching expansion.
3. Lookup, sorting, hidden state, inheritance, layouts, selection, mappings, and default explorer takeover retain the contracts above.
4. Every successful projection stores the exact visible stable-ID baseline; nonprojected cached nodes never become deletes.
5. `prepare()` compiles ordinary buffer edits into a complete ordered caller-readable Plan with operations and display, including copies, parent carrying, conflicts, and move-cycle temporary renames.
6. A Plan is plain caller-constructible data with no version, provenance, generation, capability, timestamp, or prepare-only identity.
7. Confirmation presents the prepared display verbatim and never changes Plan operations.
8. `execute(plan)` runs supplied operations in array order, independent of readiness and prepare, and never replans, appends, lowers, validates display, preflights the whole Plan, or refreshes instance state.
9. Unknown or malformed operations fail when reached, preserving earlier completed effects; filesystem errors stop later operations and never roll back.
10. Directory actions remain single Plan operations. Move is exactly one rename and has no implicit cross-filesystem fallback.
11. Execution remains UI-free and exposes cancellable progress plus exactly-once completion; internal request bookkeeping is not public contract.
12. `actions.write` alone owns readiness, buffer locking, confirmation, progress presentation, and post-execution reconciliation.
13. Parse/confirmation cancellation preserves the draft; after execution starts, successful reconciliation replaces it with filesystem truth after every terminal outcome.
14. Reconciliation failure reports directly, unlocks, leaves `needs_refresh`, and permits recovery through `instance:refresh({ force = true })`.
15. Public `refresh()` defaults to non-force and rejects modified text; `refresh({ force = true })` explicitly discards it without prompting after atomic success. Both synchronously reject creating, destroying, destroyed, and write-locked instances; load-failed refresh retries initial loading; optional `on_complete(err)` observes async completion exactly once. Watcher events retain a pending refresh signal instead of being lost.
16. Automatic GC protects visible and modified instances, cannot self-evict a new instance, and repeated setup cannot orphan a live GC group.
17. Default prepare emits normalized root-contained targets, while direct caller Plans are explicitly trusted and receive no execute-time root sandbox.
18. Actual filesystem, watcher, refresh, configuration, and handler failures surface under the documented error rules.

## 40. Explicit Trade-offs

This design intentionally accepts:

- A trusted direct Plan can target paths outside the instance root, use misleading display, or fail partway because execute does not police caller intent.
- Prepared Plans are based on the last projected snapshot and are not invalidated by later filesystem changes.
- Execution stops at the first failure and never rolls back earlier filesystem effects.
- A move is one rename; cross-filesystem moves fail unless the caller explicitly supplies copy and delete operations.
- Whole-directory filesystem primitives may have partial effects, while Plan and progress expose only the one directory operation.
- Once default write execution begins, successful reconciliation discards the stale draft even after failure or cancellation.
- Reconciliation can fail; `needs_refresh` plus public `instance:refresh({ force = true })` is the recovery path rather than a transaction or merge system.
- Automatic GC may exceed capacity temporarily to protect visible, modified, or newly registering instances.
- Real columns and `vim.trim()` make alignment and boundary whitespace normalization part of successful write behavior.
- Stable markers are not automatically repaired; damaged identities can become errors or explicit delete-plus-create intent.
- Cross-instance copy requires the source to remain live only until prepare resolves its absolute path.
- Local-only filesystem scope, one immediate progress presenter, and a first-setup-only default-explorer decision.

These trade-offs keep prepare complete, execute small, and the default write workflow recoverable without turning Fre into a transaction manager.

## 41. Open Questions

No product or architecture decision remains open for the first implementation. Adapter-internal algorithms for whole-directory copy/delete, helper names, and concrete test tooling are implementation details as long as they preserve the single-operation Plan interface and observable contracts above.
