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
7. Best-effort cancellation of asynchronous preflight and mutation work, followed by immediate terminal reconciliation.
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

A plain Lua table containing logical filesystem operations and human-readable confirmation lines.

### Physical execution step

An internal low-level operation used by the executor. Temporary moves used to break cycles are physical steps and never appear in the logical plan or confirmation summary.

### Execution

A single-use handle returned by `instance:execute()` after synchronous Plan schema validation. It exposes cancellation and copied status snapshots while one asynchronous execution progresses to a terminal state.

## 5. Core Design Rules

1. The buffer is the sole source of unsaved filesystem edits.
2. Fre does not maintain a second hidden draft of modified rows.
3. Projection-changing operations fail while the buffer is modified.
4. Window operations remain available while the buffer is modified.
5. Node trees, node IDs, extmarks, and watchers are never shared between instances.
6. Inheritance copies path-based state at instance creation and never creates live coupling.
7. Every directory sorts only its direct children.
8. The flattened view is a DFS projection of already sorted sibling lists.
9. Configured columns are real buffer text before the path, remain read-only in the first implementation, and can be selected or yanked with ordinary Vim operations.
10. Watch events never overwrite a modified buffer.
11. Filesystem conflicts are detected naturally by execution failures, not by a stale-buffer lock.
12. Modified instances are not protected from explicit destruction or GC.
13. `execute(plan)` does not verify that a plan came from the most recent `prepare()` call.
14. Neovim's actual windows are the source of truth for instance visibility.
15. Pure-Lua Plan schema validation is synchronous; every filesystem preflight and mutation call made by execution is callback-form `vim.uv`.
16. One scheduling request is outstanding per active Execution generation, including terminal candidate refresh, so cancellation and partial-state accounting remain explicit.
17. Direct `execute()` is presentation-free; only `actions.write` owns the default progress UI.
18. Errors are surfaced as Vim errors; rare failures do not justify a large recovery subsystem.

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
instance:refresh()

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
- Async methods report delayed errors through the standard Fre error reporter and their documented handlers.
- `reveal(path)` never opens or toggles a window.
- `set_sort()` stores the new comparator and calls normal refresh.
- `destroy()` forcefully discards modified content only when no Execution is active. It synchronously raises a direct Vim error and changes nothing if this instance has an Execution in any nonterminal state.
- Calling methods other than harmless identity lookups after destruction reports a Vim error.

Programmatic execution composes handlers with the single-use handle:

```lua
local execution = instance:execute(plan, {
  on_progress = function(progress)
    consume(progress.phase, progress.completed, progress.total)
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

The first `setup(opts)` starts from the exact built-ins in Section 8, applies the rules above, validates the result, atomically stores defaults for future instances, and permanently records the effective `default_file_explorer` value for this Neovim process. Every later `setup(opts)` silently discards its `default_file_explorer` field before validation and retains the first value; all other fields still reset from exact built-ins, validate, and atomically replace future-instance defaults normally. Existing instances retain their snapshotted effective configurations. The Manager replaces its capacity map with the new `setup.gc.groups` map, including the built-in `default` group when omitted, then performs normal capacity enforcement once; visible instances remain protected.

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
creating -> live-hidden <-> live-visible -> destroying -> destroyed
```

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
12. Enforce group capacity after registration.

The constructor returns the instance before the asynchronous real-root resolution and directory loads complete. The buffer can display a loading state if opened immediately. Resolution, non-directory, and load failures use the existing initial-load Vim error path; they are never synchronous constructor filesystem exceptions.
Until that asynchronous initial readiness work has resolved `real_root` and completed the required root load, a direct `execute()` call synchronously raises the lifecycle/readiness Vim error before creating an Execution, locking the buffer, or starting any filesystem I/O. This guard does not move filesystem work into the constructor.

### Destroying

`destroy()` is the single cleanup path used by explicit destruction, TTL GC, and group-capacity GC. Its first precondition is that this instance has no active Execution in any nonterminal state. If that precondition fails, `destroy()` synchronously raises a direct Vim error and changes nothing: it does not terminalize the Execution, defer destruction, pin GC, or create detached state. Normal displayed-buffer GC protection makes automatic collision unlikely; an abnormal GC call reaches the same error.

When the precondition passes, destruction performs:

1. Mark the instance as destroying so new work is rejected.
2. Invalidate outstanding non-Execution load and refresh generations.
3. Stop and close all watcher handles and debounce timers.
4. Close windows currently displaying the instance buffer where required by buffer deletion.
5. Force-delete the buffer, including when modified.
6. Remove the Manager ID, buffer, and group indexes. Manager visibility is queried directly from Neovim; instance-owned `hidden_since`, TTL scheduling state, and other GC state are simply discarded on successful destruction.
7. Drop node, metadata, mapping, layout, and pending-expansion state.
8. Mark the instance destroyed.

A late non-Execution async callback checks lifecycle and its captured generation, performs only required resource cleanup, and exits without touching Neovim state. Forced unsaved-edit destruction remains intentional whenever no Execution is active.

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

Fre does not maintain a second live index for arbitrary edited path text. `get_pos(path)` uses `nodes_by_path`, then treats the node's row extmark only as a fast hint for locating the exact local namespaced marker. If the hinted row is not that marker, it scans current buffer rows for that exact marker and rebinds as specified in Section 14. Its keys remain snapshot paths while the buffer is modified. A narrow transient map may coordinate Fre's own programmatic directory-prefix rewrites, but it is not a public lookup index and does not mutate the filesystem snapshot tree.

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
- Loading, watch refresh, successful or canceled terminal execution refresh, and explicit `refresh()` sort as part of their normal work.
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

`buffer.lua` owns the one shared physical-row decoder; this does not add another architecture layer. The decoder resolves marker/source identity, delegates configured field grammar to `columns.lua`, and returns marker/source resolution data, parsed semantic field values, actual consumed byte ranges, the normalized path, and its exact retained byte range. Cursor logic, descendant-prefix rewriting, and `mutation/prepare.lua` all call this decoder. `prepare.lua` owns occurrence interpretation and Plan construction, not a duplicate row parser.

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

Built-in parsers use self-delimiting grammars for icons, permissions, and configured time formats. A custom renderer may contain ordinary spaces only when its paired parser can consume that grammar deterministically. Parsing does not infer a hidden delimiter, rerender bytes to discover a boundary, consult any current or historical width vector, or repair malformed fields. A missing or invalid separator required by a descriptor's grammar is a parse error. Parseable edits confined to alignment or separator whitespace are not independently detected as read-only metadata changes; successful execute plus refresh normalizes them by rerendering.

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

It also returns `nil` when the snapshot path is absent or its node is collapsed or otherwise not visible. Unsaved renamed paths are not lookup keys until successful execute and refresh. A decode error on the selected row, including malformed marker, descriptor grammar, semantic fields, or retained path grammar, raises a Vim error identifying that row.

The fallback runs only when `get_pos()` or an already-required internal lookup explicitly needs this contract. Fre adds no `TextChanged` bookkeeping, changed-range marker registry, or live edited-path index. A full refresh recreates canonical row extmarks.

Fre does not remap the complete Vim operator language or automatically repair destructive edits. Consequences are explicit:

- `dd` followed by `p` carries the physical marker and columns; `get_pos()` self-heals to the pasted occurrence when the old hint no longer matches.
- Same-instance `yy`/`p` creates another occurrence of the same local stable ID and therefore expresses copy according to Section 30. If the duplicate is pasted before the original, the still-matching original hint remains authoritative; if the hint is unavailable, the lowest duplicate is chosen.
- Cross-instance `yy`/`p` retains the source namespace and expresses copy from the source node into the destination root.
- Undo and redo preserve physical marker semantics. A later `get_pos()` validates its hint and deterministically rebinds after either operation when needed.
- Visual and characterwise yanks can select real column text.
- Editing only the final path preserves identity.
- Editing a read-only column's semantic value while retaining the marker causes `prepare()` and `get_entry()` to error; parseable alignment or separator whitespace alone is normalized by successful execution and refresh.
- Commands such as `cc` or `d0` that completely remove the marker are interpreted as delete plus create, and the default confirmation displays both operations.
- A partially damaged marker produces a row-specific error rather than automatic recovery.

### Programmatic buffer changes

Fre suppresses its own bookkeeping while applying projection patches or directory-prefix rewrites. It never edits a modified row merely to repair marker or column text.

After a programmatic view refresh:

- The buffer remains `nomodified`.
- The cursor and window view are restored where possible.
- Raw columns are rendered for the complete visible projection and a new dynamic width vector is computed.
- If the width vector is unchanged, only affected rows need replacement; if any width grows or shrinks, every visible row is rerendered so padding remains aligned.
- Stable marker text, real columns, highlights, and internal row lookup extmarks are regenerated from reused node IDs.

After a programmatic descendant-prefix rewrite caused by a user directory rename:

- The buffer remains modified.
- The decoder's exact retained path range is the only replaced span; rewriting begins at its first retained byte, never at the raw post-column suffix start, so marker, columns, descriptor-consumed whitespace, and trimmed boundary whitespace remain unchanged.
- The filesystem tree snapshot remains unchanged until execution succeeds.

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
- Refresh rerenders columns only while the buffer is unmodified, during the successful empty-Plan write refresh, or during successful or canceled terminal execution refresh.
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

Fre deliberately uses the simple H1 policy. The editable buffer remains the only unsaved draft.

The following operations fail with a Vim error while `vim.bo[bufnr].modified` is true:

- `expand()`.
- `collapse()`.
- `toggle_expand()`.
- `refresh()`.
- `set_sort()`.
- `set_hidden_file()`.
- `toggle_hidden_file()`.
- `reveal()` when the target is not already visible.

The following remain available because they do not rewrite the Fre buffer:

- `open()`.
- `hidden()`.
- Window-level `toggle()`.
- Opening an existing file through an action.
- Creating another instance from an existing directory path.
- `get_entry()` and `get_pos()`.
- Explicit `destroy()` when no Execution is active.
- GC destruction when no Execution is active.

From the start of asynchronous execution preflight through terminal reconciliation, the source Fre buffer has `modifiable = false`. Navigation, `open()`, `hidden()`, window-level `toggle()`, selection/open actions, `get_entry()`, and `get_pos()` remain usable. Text edits, `:write`, another `execute()`, `prepare()`, `destroy()`, `expand()`, `collapse()`, `toggle_expand()`, `reveal()`, `refresh()`, `set_sort()`, hidden-file/filter changes, and any other projection change raise direct Vim errors while the execution lock is active.

Before locking, `execute()` snapshots the exact pre-execution buffer text, `modified`, and `modifiable` values. A normal successful or canceled terminal refresh leaves the buffer `nomodified` and restores the configured/pre-execution `modifiable` value rather than blindly setting it to true. Failure, including terminal refresh failure, restores the exact three-value snapshot before unlocking.

`actions.write` requires a normally editable Fre buffer. If the effective configuration made it nonmodifiable, the action raises a direct Vim error before calling `execute()`.

Selection uses the source snapshot Entry, not the edited retained destination path. An unsaved renamed or copied marked row opens its existing `Entry.absolute_path`. A new unmarked row has no Entry, so every select-family action raises a direct Vim error and never executes pending edits implicitly.

### Directory rename coordination

A directory row rename is detected by stable identity. After `InsertLeave`, or after a normal-mode text change, Fre uses the shared physical-row decoder and its exact retained path ranges to rewrite the path prefix of visible descendant rows when the directory row has a parseable new directory path.

Example:

```text
src/        -> lib/
src/a.ts    -> lib/a.ts
src/x/      -> lib/x/
src/x/b.ts  -> lib/x/b.ts
```

This rewrite is part of the user's text edit and preserves `modified = true`. It does not update the filesystem tree snapshot.

If the directory row is temporarily malformed, descendant rewriting waits; `prepare()` later reports any unresolved parse error.

Deleting a directory row does not require immediate deletion of descendant text rows. Plan normalization makes the parent directory delete shadow redundant descendant operations.

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

If the instance is already visible in the current tab:

- Matching layout: reuse and optionally focus the existing window.
- Different layout: close that view and recreate it with the same buffer in the requested layout.

The instance stores only last-layout preference by tab. It does not maintain a duplicate global window graph.

### `instance:hidden()`

Closes the current tab's window displaying this instance. It does not delete the buffer or instance.

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

Fre watches only local directories represented by the root or an active expanded directory.

Each active directory node owns its own `uv_fs_event_t` handle.

Reasons for per-directory watching:

- It matches the node refresh boundary.
- It avoids platform-dependent recursive watch semantics.
- Collapse can release an entire inactive branch's watcher resources.
- A change refreshes one sibling list rather than the complete tree.

### Watch callback

A watcher callback:

1. Verifies that the instance and node are still live.
2. Debounces repeated events for that node.
3. Ignores the event if the buffer is modified.
4. Ignores the event if an Execution owns the instance mutation lock. Such an event may be lost; Fre stores no pending state.
5. Otherwise schedules refresh of that directory node.

The callback does not depend on the event filename because platform support is inconsistent. It rescans the node's direct children.

Watch errors are reported once for the affected node and stop that watcher. A later explicit refresh, visibility-triggered rescan, or re-expansion can recreate it.

### Hidden instances

An unmodified hidden instance can still refresh its hidden buffer. Fre does not need an Oil-style `dirty` flag because the buffer already exists and can be patched without a window.

A modified hidden instance ignores watch events exactly like a visible modified instance.

## 27. Refresh and Async Coordination

### `instance:refresh()`

Explicit refresh reloads:

- The root directory.
- Every currently active expanded directory.

It fails while the buffer is modified.

### Atomic refresh and terminal execution refresh

Every refresh first scans and builds a complete candidate tree and view without mutating authoritative nodes, buffer text, extmarks, or the buffer's `modified` flag. Only after every required scan, sort, column render, and validation succeeds does one commit replace the authoritative tree/view and buffer projection. A failed candidate is discarded, so no partial refresh is visible.

After successful plan execution or accepted cancellation, terminal reconciliation first scans the root. It then scans only the formerly active expanded paths that the root-first candidate tree still shows, through their candidate ancestor chains, as existing directories. If completed operations deleted or moved a formerly expanded directory, that path and its unreachable descendant expansion state are pruned as normal reconciliation; the resulting `ENOENT` is not treated as a refresh failure and Fre does not attempt to scan it. Any other actual root or retained-directory scan, sort, column-render, or validation error fails the complete candidate atomically.

A successful terminal candidate reapplies sorting and filtering and commits the rendered projection as `nomodified`. Cancellation performs this point-in-time best-effort reconciliation immediately to discard unexecuted edits. The terminal candidate uses the Execution's serial per-generation request scheduler, with at most one scheduling request outstanding. This restriction is Execution-specific; ordinary non-Execution refresh may still read different directories concurrently.

If this terminal refresh fails after success or cancellation, the Execution transitions to `failed`; `canceling -> failed` is allowed. Fre surfaces the direct Vim error, leaves the authoritative tree/view unchanged, restores exact pre-execution text, `modified`, and `modifiable`, releases the lock, and calls `on_complete` exactly once. It does not expose a partially refreshed buffer or add recovery state.

Watch events received while the mutation lock is held are ignored and may be lost. A late `EBUSY` side effect is often caught by a later watcher event, but this is not guaranteed when its event races the terminal scan and unlock. A later visibility-triggered rescan or explicit `refresh()` restores truth. Success and cancellation reconciliation are point-in-time best effort only; no stale, `needs_refresh`, or epoch flag is stored.

### Per-node generation

`load_generation` remains a node-local async race guard for actual filesystem reads. It is unrelated to sorting.

Starting a newer ordinary load invalidates an older callback for the same node. Different directory nodes can load concurrently outside an Execution; terminal Execution reconciliation instead uses the serial scheduler above.

### Buffer patch serialization

Directory reads can complete concurrently, but buffer mutations are queued per instance and applied on Neovim's main event loop.

Before applying a completed async refresh, Fre checks again that:

- The instance is live.
- The node generation is current.
- The buffer is still unmodified.
- The node remains relevant to the requested projection.

If any check fails, the result is discarded or retained only as safe cache without changing buffer text.

## 28. Garbage Collection

GC has two independent policies:

1. Hidden TTL per instance.
2. Maximum live instances per configured group.

Configuration:

```lua
gc = {
  ttl_ms = 60_000,
  default_group = "default",
  groups = {
    default = 10,
    project = 5,
    permanent = 0,
  },
}
```

Instance override:

```lua
gc = {
  ttl_ms = 10_000,
  group = "project",
}
```

### Visibility

An instance is visible if a direct `vim.fn.win_findbuf(instance.bufnr)` query returns at least one valid window. Manager stores no visibility index. `hidden_since` and TTL deadline state belong to the instance.

When the first window appears:

- Clear `hidden_since`.
- Invalidate the current TTL deadline.

When the last window disappears:

- Set `hidden_since` if it was not already set.
- Schedule a TTL callback when `ttl_ms > 0`.
- Enforce group capacity.

A never-opened new instance starts hidden at creation time.

### TTL

- `ttl_ms > 0`: attempt destruction after that continuous hidden duration.
- `ttl_ms = 0`: disable time-based GC for that instance.
- Showing the instance resets the hidden interval completely.
- A delayed callback rechecks instance identity and instance-owned `hidden_since` before attempting destruction.

### Group capacity

- `setup.gc.groups[name] > 0`: cap live instances in that group.
- `setup.gc.groups[name] = 0`: disable capacity GC for that group.
- An unknown group passed to `new()` is a configuration error.
- When over capacity, attempt to destroy the hidden instance with the oldest instance-owned `hidden_since`.
- Use creation sequence as a deterministic tie-breaker.
- Visible instances are never capacity-evicted.
- If every candidate is visible, allow temporary overflow.
- Enforce the limit again when an instance becomes hidden or a new instance is created.

TTL and capacity switches are independent. Both must be zero for a fully manual-lifetime instance.

### Modified buffers

When no Execution is active, GC does not protect modified buffers and successful destruction force-wipes their contents without save confirmation. A nonterminal Execution still makes every destruction attempt fail under the lifecycle precondition.
When an automatic TTL or capacity attempt collides with a nonterminal Execution, it calls the same `destroy()` path, receives the required direct Vim error, reports that error internally as appropriate, changes nothing, and drops that GC attempt. There is no pin, deferred-destruction queue, retry timer, or detached state. Destruction can occur only on a later ordinary GC trigger or a later explicit `destroy()` call after execution is terminal.

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

`instance:prepare()` is deterministic over:

- The last successful destination-instance filesystem snapshot.
- The current editable buffer lines.
- Stable row identity markers.
- The paths, descriptors, and snapshot nodes resolved from still-live source instances referenced by foreign markers.

It does not rescan the filesystem and does not mutate the buffer.

### Path parsing

For each row, prepare calls the shared `buffer.lua` physical-row decoder, then interprets its result. The decoder returns:

- Optional namespaced stable identity and source resolution.
- Parsed semantic real-column fields and their actual consumed byte ranges when a marker is present.
- Final normalized root-relative destination path text and its exact retained byte range.
- Entry kind from stable identity or, for a new row, trailing `/` after path-boundary trimming.

Rules:

- For a marked row, the decoder parses every configured descriptor and then applies `vim.trim()` semantics to the entire remaining literal suffix. For a new unmarked row, it applies the same semantics to the entire row. The retained bytes form the path used by all following validation and normalization.
- A new directory path must end in `/`.
- A new file path must not end in `/`.
- After trimming, every retained local or foreign stable directory row must end in `/`, while every retained stable file or symlink row must not. A mismatch is a row-specific prepare error; stable identity cannot convert entry kind.
- Paths are normalized with internal `/` separators.
- Absolute paths are rejected.
- Empty paths, including rows made empty by `vim.trim()`, are rejected by prepare even though the decoder exposes the end-of-line repair boundary.
- Newline bytes are rejected and cannot be escaped into one row.
- Leading and trailing path whitespace is silently ignored by `vim.trim()` and is not round-trippable. Internal spaces remain literal path bytes.
- An unmarked row whose first physical byte is reserved `0x1f` is rejected as ambiguous; valid marked rows and non-leading path components containing that byte are not rejected on this basis.
- `.` and escaping `..` segments are rejected.
- The resolved absolute target must remain inside the instance root.
- The root itself is not a row and cannot be deleted or renamed.

`prepare.lua` performs occurrence interpretation and Plan construction from these decoder results. It does not parse physical rows or descriptor fields independently.

### Existing ID occurrence rules

For each original stable ID:

#### Zero occurrences

Generate delete for the original entry.

#### One occurrence

- Same normalized path: unchanged.
- Different normalized path: move.

#### Multiple occurrences

Preparation derives ancestor-directory move/copy mappings before choosing descendant operations. Buffer line order is never an operation-selection tie-breaker.

For one stable ID:

- If one occurrence retains the original path, it remains the original entry.
- An occurrence at the exact descendant path implied by an ancestor directory move or recursive copy is carried by that ancestor operation and emits no redundant descendant operation.
- When an ancestor directory move implies the primary descendant target and that occurrence exists, it is the primary carried occurrence regardless of where its line appears.
- Every remaining distinct non-carried occurrence becomes a copy from the original snapshot source. The dependency compiler schedules such reads before an ancestor move or delete removes that source.
- If neither the original path nor a primary ancestor-implied occurrence exists, the lexicographically smallest normalized target is the move target and remaining distinct targets are copies. This deterministic choice has no flattened-view ordering meaning.
- Duplicate target paths are rejected.

A descendant occurrence exactly implied by an ancestor recursive copy is normalized away. Editing such an implied occurrence to a different target while omitting its implied target is an incompatible parent/child combination in the first implementation; users can retain the implied occurrence and add another duplicate target to express an extra copy.

This supports normal same-instance line yank/paste behavior without assigning filesystem meaning to buffer order.

### Foreign instance occurrences

A marker whose instance ID differs from the destination instance represents a copy source, never a move or destination-owned occurrence.

Prepare performs these steps:

1. Call the shared `buffer.lua` decoder, which resolves the process-global source instance and source node, selects the source descriptors, parses their field grammars, and returns the source snapshot plus normalized destination path and exact ranges.
2. Verify from the decoder result that the marker resolves to a live foreign source rather than a destination-owned occurrence.
3. Validate the returned semantic fields against the source-node snapshot through descriptor equality callbacks.
4. Validate the normalized destination-root-relative target and the stable source kind's required trailing-slash syntax.
5. Emit one logical copy from the resolved source snapshot path to that destination target.

The source instance and node must both be live at destination `prepare()` so the marker, source path, source descriptors, and source snapshot can be resolved. The source node's snapshot path is used even when the source buffer currently has unrelated unsaved edits. Foreign occurrences do not participate in the destination instance's local zero/one/multiple occurrence counts.

If the source instance or node has already been destroyed or released before prepare, prepare reports a row-specific Vim error, emits no partial Plan, and leaves the destination buffer modified. Fre does not pin source instances, add cross-instance reference counting, or maintain persistent clipboard provenance. Once prepare has emitted an absolute-path `copy.from` in a Plan, later source-instance destruction does not invalidate the Plan; normal live filesystem checks still run at execute time.

Source and destination instances may configure different columns. The foreign marker selects the source descriptor set for parsing the pasted physical row. Descriptor parsing does not consult the source's current or historical dynamic width vector, so a source rerender or width change alone after paste does not invalidate that row. A successful destination refresh rerenders the copied target using the destination instance's columns.

### New rows

Rows without an existing stable ID generate:

- `create_directory` when ending in `/`.
- `create_file` otherwise.

New files are empty. Fre does not infer file contents from another row unless that row carries a copied existing ID.

### Deletes and directory shadowing

A removed directory row generates one recursive directory delete.

A parent directory delete shadows only descendant operations whose final result remains inside the deleted subtree, including redundant descendant deletes and unchanged rows.

A descendant move or copy whose target is outside the deleted subtree must be retained and scheduled before the parent delete. For example, moving `dir/a` to `saved-a` while deleting `dir/` preserves the move and then deletes the remaining directory.

The same normalization principle applies where an ancestor directory move or copy already carries unchanged descendants with it: remove only operations exactly implied by the ancestor operation, never a descendant operation that preserves data outside the ancestor target.

### Directory rename normalization

Visible descendant prefix rewriting should make the buffer explicit before prepare. Prepare computes ancestor directory operations before descendant classification and gives the exact implied descendant path priority over all non-carried targets.

For example, if `dir/` moves to `newdir/` while the `dir/a` marker also appears at `saved-a`, `newdir/a` is carried by the parent move and `saved-a` is a copy scheduled before the parent move. The result never depends on which descendant line appears first.

Prepare normalizes only descendant moves or copies exactly implied by an ancestor directory operation. Descendant operations that preserve data outside the ancestor target remain explicit and are ordered before any ancestor operation that would remove their source.

### Target conflicts

Prepare rejects:

- Multiple entries targeting the same normalized path.
- A create targeting an occupied snapshot path unless the same plan vacates it first.
- A directory move/copy target that is structurally inside its own source directory.
- A copy whose normalized source and target are the same path.
- Incompatible parent/child operation combinations, including replacing an ancestor-copy-implied descendant target instead of retaining it and adding an extra occurrence.
- Invalid, unknown, or ambiguous namespaced stable identity markers.
- Semantic read-only-column mismatches and descriptor parse failures, including missing or invalid required separators.

These are plan-structure checks. They are not a live filesystem conflict check.

## 31. Logical Plan Format

A plan is a normal Lua table. Its only allowed top-level keys are:

- Required `operations`: a dense array of operation tables.
- Optional `display`: a dense array of strings.

Unknown top-level keys are rejected by the shared plan validator used by `execute()` and `actions.confirm()`.

The exact operation schemas are:

```lua
{ type = "create_file", path = absolute_path }

{ type = "create_directory", path = absolute_path }

{
  type = "copy",
  from = absolute_source,
  to = absolute_target,
  kind = "file" | "directory" | "symlink",
}

{
  type = "move",
  from = absolute_source,
  to = absolute_target,
  kind = "file" | "directory" | "symlink",
}

{
  type = "delete",
  path = absolute_path,
  kind = "file" | "directory" | "symlink",
}
```

Example:

```lua
Plan = {
  operations = {
    {
      type = "move",
      from = "/project/a",
      to = "/project/b",
      kind = "file",
    },
    {
      type = "copy",
      from = "/project/src",
      to = "/project/src-copy",
      kind = "directory",
    },
  },

  display = {
    "MOVE  a -> b",
    "COPY  src/ -> src-copy/",
  },
}
```

Each operation accepts only the fields shown in its schema; unknown operation fields are rejected.

Operation paths are absolute normalized local paths. User-facing display uses root-relative paths for in-root values. A copy source outside the destination root is shown as an absolute source path unless `prepare()` can label it with its live source instance and source-root-relative path. If present, every `display` element must be a string. `prepare()` always emits display lines. The executor validates `display` when present but otherwise ignores it.

`kind` is required for copy, move, and delete. Execute verifies the live source with `lstat` and rejects a mismatched kind before mutating the filesystem.

The plan contains no instance version, snapshot version, capability token, prepare timestamp, or provenance signature.

`execute(plan)` accepts a caller-created or caller-modified plan after full structural and root-scope validation. It does not require the plan to come from `prepare()`.

## 32. Confirmation and `:write`

Fre buffers use `BufWriteCmd`. The default write path belongs to `actions.write` and is:

```text
instance:prepare()
-> actions.confirm(ctx, plan)
-> instance:execute(plan, handlers)
-> open and focus the default progress float
```

`execute()` exclusively owns terminal execution reconciliation. The default write action must not invoke a second refresh.

### Empty plan

If `prepare()` returns no operations:

- Do not show confirmation or progress UI.
- Refresh the instance.
- Mark the buffer `nomodified` after successful refresh.

This handles edits that only reorder rows or return text to its original state.

### Default confirmation presenter

`actions.confirm()` runs the shared plan validator. If `plan.display` is absent, it derives deterministic logical summary lines from `operations`; otherwise it presents the validated string array.

The summary appears in a temporary read-only scratch view and asks the user to execute or cancel. It shows only logical operations and never shows temporary move paths or physical scheduling details.

Canceling confirmation executes nothing, leaves the Fre buffer unchanged, and leaves it modified. Users can bypass or replace confirmation by composing `prepare()`, their own UI, and `execute(plan)` directly.

### Default progress presenter

Only `actions.write` creates the default progress UI, delegating rendering and terminal presentation to internal `progress.lua`. Immediately after confirmed execution returns its handle, Progress opens and focuses one centered editor-relative floating window backed by an unlisted scratch buffer. It has `style = "minimal"`, `focusable = true`, and a rounded border. There is no delay, and the source Fre buffer never renders progress text.

The float has exactly four content rows:

1. Phase and current logical operation or move-cycle summary.
2. Optional detail, blank when absent.
3. Spinner plus `completed/total` logical operation counts.
4. Cancel hint.

Geometry is fixed internal policy with no configuration or fallback mode. Before starting `execute()`, `actions.write` computes `available_width = vim.o.columns` and `available_height = vim.o.lines - vim.o.cmdheight`. A rounded border plus at least one content column and all four content rows requires `available_width >= 3` and `available_height >= 6`; otherwise `actions.write` raises a direct Vim error before creating an Execution or starting I/O. When it fits, `content_width = min(80, available_width - 2)`, `content_height = 4`, `outer_width = content_width + 2`, and `outer_height = 6`. Editor-relative placement is `col = floor((available_width - outer_width) / 2)` and `row = floor((available_height - outer_height) / 2)`. Long text uses the existing display-cell truncation with a visible ellipsis and never wraps.

Recursive traversal, copy, delete, and cross-device move steps may update `detail` without incrementing logical totals. A move cycle uses the one synthetic `move cycle (N moves)` current summary defined in Section 33; private physical steps never become logical progress items. Temporary paths are normally hidden, but terminal `detail` identifies a known leftover path after failure or cancellation as required by Section 33.

The float has these interaction rules:

- Explicit `c`, `C`, `q`, or `Esc` closes the float immediately and requests cancellation regardless of the boolean returned by the associated Execution's `cancel()`.
- Any external close, including `:close`, `<C-w>c`, or `WinClosed`, closes immediately and requests cancellation regardless of the return value.
- Losing focus alone neither closes the float nor requests cancellation; the float remains visible.
- A programmatic call to that Execution's `cancel()` closes its associated float only when it returns `true`; a `false` call has no UI effect.
- Success or failure closes the float automatically.
- An internal-closing guard prevents programmatic or terminal auto-close from recursively requesting cancellation through `WinClosed`.
- Once closed, the progress UI cannot be minimized, restored, reopened, or moved into the Fre buffer.

On cancellation, `actions.write` uses `vim.notify()` for a terminal summary that explicitly reports the completed count, a partial or potentially partial current operation, and the discarded unexecuted remainder. On success it emits the required execution summary. Failure auto-closes and surfaces the direct executor error as a Vim error.

Presentation is isolated in narrow internal `progress.lua`. `actions.write` installs Progress's wrapped completion handler: it closes the float, notifies or presents the terminal outcome, and only then forwards any outer completion behavior exactly once. Progress consumes Execution handlers and the handle; it does not define mutation state, filesystem cancellation, or a public UI/configuration DSL. `execute()` has no terminal-presentation prerequisite or UI responsibility.

### Direct execution

Calling `instance:execute(plan, handlers_or_callback)` directly performs no confirmation and creates no progress UI. Callers consume progress through handlers and inspect or cancel the returned handle.

## 33. Executor Model

`instance:execute(plan, handlers_or_callback)` is asynchronous and single-flight per instance. After successful synchronous validation it returns one simple Execution handle. Starting another execution while one is active reports a Vim error.

`handlers_or_callback` may be omitted, may be a handlers table containing exactly optional `on_progress(progress)` and `on_complete(err, result)` function fields, or may be a function shorthand for `on_complete`. Unknown fields and present non-functions are rejected synchronously. Function references are snapshotted into the Execution.

The instance retains the active handle only until terminal state, unlock, and removal of that active reference. `on_complete` is then attempted exactly once, so it may start a new Execution even while an old quarantined `EBUSY` request remains live. A caller-held terminal handle remains readable through `get_status()` and otherwise collects naturally.

Execution exposes only:

```lua
execution:cancel()    -- boolean
execution:get_status() -- copied plain table
```

It has no resume, retry, wait, event-subscription, reuse, or extmark API.

### State, phase, and progress

State transitions are exactly:

```text
running -> succeeded
running -> failed
running -> canceling -> canceled
running -> canceling -> failed
```

`refreshing` is exclusively a phase and is never a state. The phase is one of `preparing`, `executing`, or `refreshing`. Async filesystem preflight and dependency preparation use `preparing`; Plan mutations use `executing`; successful and canceled terminal candidate refreshes use `refreshing`. State remains `running` during a success terminal refresh and `canceling` during a cancellation terminal refresh. A refresh failure leaves phase `refreshing` and follows `running -> failed` or `running -> canceling -> failed`.

`get_status()` returns a fresh plain table. `on_progress()` receives the same copied shape whenever observable state, phase, count, current operation, or detail changes:

```lua
{
  state = "running" | "canceling" | "succeeded" | "failed" | "canceled",
  phase = "preparing" | "executing" | "refreshing",
  completed = integer,
  total = integer,
  current = operation_or_cycle_summary_or_nil,
  detail = string_or_nil, -- omitted when absent
}
```

`completed` and `total` count logical Plan operations only. Outside a move cycle, `current` is `nil` at a logical-operation boundary or a copied logical operation table using the exact Section 31 schema. During a cycle of N logical moves, `current` is the single synthetic string `move cycle (N moves)`. `total` includes those N operations, while `completed` advances by N only after the whole cycle finishes; a canceled or failed partial cycle advances it by zero. During ordinary work, `detail` may identify a recursive physical step without exposing cycle temporary paths; terminal delivery may identify a known leftover temporary path in that same existing string field. No returned or delivered table aliases executor-owned mutable state or the caller's Plan.

Each `on_progress` call is protected. If it throws, Fre surfaces that error exactly once as a Vim error, disables that Execution's progress handler, and continues execution.

Executor completion first finishes terminal refresh or snapshot restoration, closes immediately available request-owned file descriptors and directory handles, restores buffer state, unlocks the instance, transitions to the terminal state, clears the instance active reference, and delivers the terminal progress/result. It then invokes the protected `on_complete(err, result)` exactly once. There is no executor terminal-presentation prerequisite; an `actions.write` wrapper performs its presentation before forwarding outer completion behavior. An `EBUSY` RequestRecord is quarantined by its closure before completion; only record-owned file-descriptor, directory-handle, request-userdata, or equivalent resource closure may occur later. The result is a fresh plain table:

```lua
{
  status = "succeeded" | "failed" | "canceled",
  completed = integer,
  total = integer,
  current = operation_or_cycle_summary_or_nil,
  partial_current = false | true | "unknown",
  uv_cancel = "accepted" | "busy" | "no_request", -- canceled only
}
```

For success, `current = nil` and `partial_current = false`. Outside cycles, failure or cancellation uses the interrupted copied logical operation or `nil` at a boundary; `partial_current` is `false`, `true`, or `"unknown"` according to known effects and an `EBUSY` request. For any partially finished move cycle, `current = "move cycle (N moves)"`, `completed` advances by zero for its N moves, and `partial_current = "unknown"` regardless of which private moves ran. The result deliberately does not enumerate per-move states or residual temporary paths. Private temporary paths may remain; the summary is diagnostic, not a recovery plan. Terminal refresh and explicit filesystem inspection are the recovery route.

Succeeded and canceled completion use `err = nil`. Failed completion, including terminal refresh failure, receives the direct error object/message. `on_complete` invocation is protected and attempted exactly once; if it throws, Execution state, request-owned resource closure, unlock, and terminal status remain final and the handler error surfaces as a Vim error. With no completion handler, execution failure is still surfaced through Fre's standard Vim error reporter.

### Synchronous validation and asynchronous preflight

Before creating a handle, locking the buffer, or starting I/O, `execute()` first checks the instance lifecycle/readiness precondition. If asynchronous initial `real_root` resolution and required root load have not completed successfully, it synchronously raises the lifecycle/readiness Vim error and creates no Execution. Once ready, it performs only pure-Lua validation:

- `plan` is a table and `operations` is a dense array.
- Every operation uses one recognized exact schema from Section 31 and has no unknown fields.
- Required fields are strings and `kind` is one allowed enum value where required.
- Optional `display` is a dense string array and no unknown top-level keys exist.
- Operation paths have absolute normalized local syntax.
- Every create path, delete path, move source, move target, and copy target is lexically inside this instance's stable lexical root.
- A copy source may be outside the destination root because copy reads it without mutating it.
- No operation deletes, moves, overwrites, or targets the destination instance root itself.
- A directory move or copy target is not structurally inside its own source.

Validation constructs an execution-owned deep copy containing every exact Plan top-level field, operation record, path/kind string, and display string. Preflight, scheduling, progress, and result construction use only this copy; caller mutation immediately after `execute()` returns is irrelevant. Handler validation and function-reference snapshotting occur in the same synchronous boundary.

Any lifecycle/readiness failure or failure in this pure-Lua Plan, handler, and lexical validation raises synchronously, creates no Execution handle, and starts no filesystem request. `execute(plan)` remains independent of `prepare()` provenance.

After handle creation and buffer lock, every filesystem-dependent preflight check is callback-form `vim.uv` work represented by the Execution in phase `preparing`:

- Existing in-root source parents resolve inside the real root.
- A symlink final source component can be moved, copied, or deleted as a link, but symlinked parents of any path Fre mutates cannot escape the destination root.
- Every write target's nearest existing ancestor resolves inside the real root.
- Live source `lstat` kind matches the declared kind, including external copy sources.
- Filesystem occupancy and dependency assumptions required before mutation hold.

This complete-plan asynchronous preflight finishes before the first mutation. It does not check Plan provenance, snapshot freshness, unrelated external changes, or eliminate normal filesystem races. The executor repeats asynchronous real-root containment and required `lstat` checks immediately before every physical mutating step using the filesystem state produced by earlier steps, including executor-generated temporary moves. External copy sources are rechecked with `lstat` but need not resolve inside the destination root.

No synchronous filesystem call is permitted in execution validation, preflight, containment, `lstat`, `realpath`, mutation, recursive traversal, terminal rescan, or request-owned resource closure. A stuck filesystem call must remain represented by a cancellable Execution rather than blocking before handle creation.

### Serial filesystem scheduling

All executor preflight, mutation, and terminal candidate-refresh filesystem calls use callback-form `vim.uv`. There is at most one scheduling request for an active Execution generation at a time. This cardinality applies only to Execution scheduling; ordinary non-Execution refresh may issue concurrent directory reads.

Each async step owns a self-contained `RequestRecord` or equivalent closure containing its Execution generation, request userdata, and only file descriptors, directory handles, or other resources opened by that step. `Execution.active_request` points to the current record; there is no instance-global request slot. A normal callback clears only its own matching active pointer.

Recursive copy, recursive delete, directory traversal, file-copy chunks, cross-device move fallback, and move-cycle chains advance one scheduling request at a time. A callback may schedule the next ordinary step only while its captured Execution generation is current. On immediate `EBUSY` cancellation, that record is quarantined by closure; a new Execution may start after old `on_complete` without overwriting, canceling, or clearing the quarantined record.

The dependency compiler lowers logical operations into ordered physical work:

- Explicit parent-directory creation precedes child target creation.
- A copy reads its source before another operation moves or deletes that source.
- A target-vacating move or delete precedes another operation occupying that target.
- Directory operations order before or after descendant operations according to containment.
- Independent operations remain sequential.

### Move cycles

Move dependencies are analyzed as a graph. A cycle such as:

```text
MOVE a -> b
MOVE b -> a
```

is lowered internally to:

```text
a   -> .fre-tmp-<id>
b   -> a
tmp -> b
```

Longer cycles use the same one-temporary-path rotation strategy. Temporary paths use a Fre-specific collision-resistant basename on the same local filesystem where possible and never appear in a logical Plan or progress totals. A successful logical cycle performs its required final temporary-path rotation before its moves count complete. Failure or cancellation launches no extra path deletion and may leave the temporary path on disk. Case-only renames can use the same technique.

A cycle is one scheduling unit for diagnostics: `current = "move cycle (N moves)"`, `total` still includes N logical Plan moves, and `completed` advances by N only after the complete rotation succeeds. Cancellation invalidates the entire active chain and may leave a temporary path or partially rotated names. A partial cycle advances by zero, reports `partial_current = "unknown"`, and exposes no per-move state or residual path list.

### Filesystem operation semantics

#### Create file

Create a new empty file. Existing target errors are surfaced.

#### Create directory

Create the explicitly planned directory. Parent directories are not implicitly invented unless they also exist as planned create operations.

#### Copy file

Copy file bytes and basic mode where supported by callback-form local APIs.

#### Copy directory

Recursively copy the source tree without following symlinks.

#### Copy symlink

Copy the link itself, not the target.

#### Move

Attempt local rename first. On cross-device failure, lower the logical move to a serial copy-then-delete chain appropriate to its kind. Cancellation or failure can leave both a partial target and some or all of the source.

#### Delete file or symlink

Delete the entry itself.

#### Delete directory

Recursively delete the directory and its contents without following symlinks.

### Active cancellation

`cancel()` is accepted exactly once only while state is `running` and phase is `preparing` or `executing`. The accepted call returns `true`, changes state to `canceling`, immediately invalidates the Execution generation, and closes the associated default progress float when one exists. Repeated calls, terminal-state calls, and calls after phase becomes `refreshing` return `false` and have no programmatic UI effect. Explicit or external float closure remains immediate and requests cancellation regardless of that return value.

Cancellation then calls `current_request:cancel()` when a request exists. The canceled result records:

- `uv_cancel = "accepted"` immediately when `request:cancel()` returns successfully. This classification is final before the request callback runs.
- `uv_cancel = "busy"` when cancellation returns `EBUSY`; the OS call may finish later.
- `uv_cancel = "no_request"` when cancellation occurs at a serial step boundary.

Generation invalidation immediately prevents the current recursion, cross-device chain, move-cycle chain, and every later Plan operation from scheduling another request. It does not wait for the current logical operation, tree, or cycle to finish. Completed filesystem effects are never rolled back, the current operation is not counted completed, and executor temporary paths may remain.

When libuv accepts cancellation, a later `ECANCELED` callback is expected cleanup-only evidence. It performs only request-owned file-descriptor, directory-handle, request-userdata, or equivalent resource closure and cannot establish or revise `uv_cancel`, terminal status, partial-current classification, or filesystem paths. After `EBUSY`, a late success or error callback has the same resource-closure-only lane: it cannot mutate Execution fields, schedule work, delete a temporary path, emit another terminal progress state, refresh, unlock, or invoke completion again. There is no guarantee that the OS syscall stopped.

Immediately after issuing or skipping request cancellation, Fre enters phase `refreshing` and uses the serial root-first terminal candidate rescan from Section 27. If that candidate succeeds, Fre atomically commits it, marks the buffer `nomodified`, restores the configured/pre-execution `modifiable` value, unlocks, transitions to `canceled`, and completes exactly once without waiting for an `EBUSY` callback. This reconciliation is only a point-in-time best-effort snapshot. A watcher may later observe a late `EBUSY` side effect, but its event can race the terminal scan and unlock and be lost; a later visibility-triggered rescan or explicit `refresh()` restores truth.

If the cancellation terminal refresh fails, Fre discards the candidate, transitions from `canceling` to `failed` with phase `refreshing`, surfaces the direct refresh error, leaves the authoritative tree/view unchanged, restores the exact pre-execution buffer text, `modified`, and `modifiable`, closes immediately available request-owned resources, unlocks, and invokes completion exactly once with failed status. It launches no filesystem-path cleanup and does not complete as canceled or add a recovery state machine, rollback, detached worker, external `cp`/`rm`, or hard latency guarantee. Any known leftover temporary path is identified in the existing progress `detail` text before terminal delivery.

This is intentionally similar to Oil's immediate terminal behavior: Oil finishes and calls refresh without waiting for a late adapter callback, then ignores that callback. Fre additionally retains the current libuv request, attempts to cancel it, and stops all internal serial chains.

### Failure

At the first non-cancellation filesystem or executor failure:

1. Invalidate the generation and stop scheduling work.
2. Close only immediately available request-owned file descriptors, directory handles, request userdata, and equivalent resources; do not launch any filesystem operation to remove temporary paths.
3. Restore the exact pre-execution buffer text, `modified`, and `modifiable`.
4. Release the mutation lock and clear the active reference without refreshing.
5. Transition to `failed`, deliver terminal progress/result, report the original direct error with any known leftover temporary path in that existing error text, and invoke completion exactly once.
6. Do not roll back completed user-visible filesystem effects.

Failure and cancellation terminalization never creates a cleanup Execution, background deletion, hidden state, structured recovery array, or post-terminal path-deletion lane. Known leftovers stay on disk. A later Execution and an explicit or ordinary-GC-triggered destroy may coexist with quarantined old RequestRecords because those records own only their late resource closure.

### Success

After every logical operation succeeds, including every required final cycle-temporary step:

1. Set phase to `refreshing` and run the serial root-first terminal candidate scan from Section 27.
2. Reconcile node trees, sorting, stable row state, real columns, and highlights.
3. Mark the buffer `nomodified` and restore the configured/pre-execution `modifiable` value.
4. Close immediately available request-owned resources, release the mutation lock, transition to `succeeded`, and clear the active reference.
5. Deliver terminal progress/result, then invoke protected completion exactly once.

## 34. External Changes and Optimistic Execution

Fre intentionally does not maintain a stale lock or `needs_refresh` flag.

While the buffer is modified, watch events are ignored. Prepare compares the buffer to the last successful snapshot. Execute applies that logical delta to the filesystem as it exists at execution time.

Expected examples:

### Unrelated external create

The user renames `a` while an external process creates `z`. The move succeeds, and post-success refresh displays `z`.

### Unrelated external rename

The user edits `a`; an external process renames unrelated `b` to `c`. The user's operation succeeds, and refresh shows `c`.

### External deletion of an unchanged row

The external deletion generates no user delete because the user did not remove that row relative to the snapshot. After another successful user operation, refresh removes the missing row.

### Same-entry delete conflict

The user removes `a` from the buffer and an external process also deletes `a`. Execution attempts the logical user delete and reports the missing-source filesystem error.

### Same-entry move conflict

The user renames `a` to `b`, but an external process removes or renames `a`. Execution reports the failed source move.

This is deliberately optimistic and operation-driven. Fre does not try to merge snapshots.

A cancellation rescan is similarly optimistic, point-in-time, and best-effort. Watch events are ignored while the execution lock is held. After unlock, a watcher may observe a late successful `EBUSY` request as an ordinary external change, but that event can race and be lost; a later visibility-triggered rescan or explicit `refresh()` restores truth. Fre stores no watcher epoch, pending-event, or stale flag.

## 35. Local Path and Symlink Rules

Fre has one local path module responsible for:

- Platform-aware normalization.
- Windows drive and separator handling.
- Root containment checks.
- Root-relative display conversion.
- Case sensitivity rules needed for equality and case-only rename.
- Temporary sibling/path creation.

The public `instance.root` is the stable lexical absolute normalized path computed without filesystem I/O. The asynchronous initial load separately resolves and stores the internal `real_root`; planned new targets continue to use normalized lexical paths because they may not exist yet.

Lexical containment alone is insufficient when an in-root parent directory is a symlink. During public plan execution, Fre asynchronously resolves each in-root source parent and each write target's nearest existing ancestor and requires those real paths to remain inside the real root. The final source component is asynchronously checked with `lstat`, allowing Fre to operate on an in-root symlink itself without following its target.

`copy.from` is the deliberate exception: it may identify a readable local source outside the destination root, including a node resolved from another live Fre instance. Fre never mutates that external source. `copy.to` and every other mutating path remain root-contained.

The same asynchronous containment check runs again immediately before each physical step that mutates filesystem state. This catches paths whose ancestry changed because an earlier operation in the same plan created, copied, or moved a symlink. Execution never uses synchronous filesystem containment, `realpath`, or `lstat`.

Symlinks are represented using `lstat`:

- A symlink is not expanded as a directory in the first implementation.
- Selection delegates the symlink path to normal Neovim file opening.
- Move, copy, and delete operate on the link itself.
- Fre does not recursively follow links during directory copy or delete.

These rules avoid expansion loops and accidental traversal outside the root.

## 36. Error Handling

Fre uses a small error model:

- Synchronous public misuse, execution lifecycle/readiness failures, and pure-Lua Plan schema errors raise a Vim/Lua error immediately, create no Execution, and start no I/O.
- Async filesystem failures are scheduled onto the main loop and reported as Vim errors.
- `on_complete` receives the same direct execution failure for programmatic composition; a function argument is shorthand for that handler.
- Parsing errors identify the buffer row and, when non-empty, its normalized retained path.
- Plan errors identify conflicting logical paths.
- Watch errors identify the watched directory.
- Executor errors identify the logical operation and underlying filesystem message.
- Progress and completion handler errors surface as Vim errors without altering terminal state or callback cardinality.
- Cancellation refresh failure and rare destroy/GC resource-closure failure surface directly; neither creates a recovery state machine or filesystem-path cleanup lane.

Fre does not add warning-only fallback behavior for unsupported adapters, invalid groups, malformed mappings, malformed columns, invalid layouts, or cancellation failures. Setup/new validation and runtime errors report these directly.

## 37. Suggested Module Boundaries

The exact filenames can change during implementation, but responsibilities should remain separated:

```text
lua/fre/init.lua                 public setup/new/lookup API
lua/fre/config.lua               defaults, merge, validation
lua/fre/manager.lua              instance indexes, process-wide directory takeover, and group GC
lua/fre/instance.lua             Instance primitive methods and active-handle reference
lua/fre/path.lua                 local path normalization and containment
lua/fre/fs.lua                   general local async filesystem operations
lua/fre/tree.lua                 nodes, child reconciliation, expansion trie
lua/fre/view.lua                 DFS projection, real row rendering, highlights, row patches
lua/fre/buffer.lua               buffer lifecycle, shared physical-row decoder, conceal, cursor autocmds
lua/fre/window.lua               layouts and window primitives
lua/fre/watch.lua                per-directory watchers and debounce
lua/fre/columns.lua              real-column constructors, renderers, and field grammars
lua/fre/actions.lua              function-based action composition and write workflow
lua/fre/progress.lua             private default write-progress float
lua/fre/mutation/prepare.lua     decoder-result occurrence interpretation and Plan construction
lua/fre/mutation/execute.lua     Execution state, serial scheduling, request cancel, terminal reconciliation
lua/fre/mutation/fs.lua          serial cancellable callback-form primitives and request-owned resource closure
lua/fre/mutation/move_graph.lua  move SCC/cycle lowering
lua/fre/gc.lua                   TTL scheduling and capacity enforcement
```

Deep modules should expose narrow interfaces:

- Tree owns node relationships and directory-local ordering.
- View owns projection, row rendering, and internal extmarks, not filesystem access or physical-row decoding.
- Buffer owns the shared physical-row decoder and cursor integration; it delegates field grammar to Columns.
- Prepare owns occurrence interpretation and Plan construction, not physical-row parsing or execution.
- Execute owns Execution state, serial scheduling, current-request cancellation, and terminal reconciliation, not presentation.
- Mutation FS owns callback-form cancellable primitives plus request-owned file-descriptor and directory-handle closure, never post-terminal filesystem-path deletion.
- Progress owns only the default `actions.write` float and terminal presentation.
- Actions own workflows, not instance mutation state.
- Manager owns lookup/lifetime indexes and the one process-wide directory takeover autocmd, not tree behavior.

## 38. Testing Strategy

Tests should use temporary real directories for filesystem integration and injectable boundaries for time and watchers.

### Pure or mostly pure unit tests

- Path normalization and root containment on POSIX and Windows-shaped paths.
- Expansion snapshot re-rooting.
- Pending expansion trie construction.
- Per-node sibling sorting.
- Flattened DFS projection from independently sorted nodes.
- Hidden-file filtering.
- Namespaced stable-marker encoding and parsing.
- Real-column dynamic width calculation from all visible rows, including UTF-8 display widths, combining marks, variation selectors, ZWJ emoji, left/right ASCII padding, center padding with `floor(total / 2)` on the left and the extra space on the right, and ordinary-space separators.
- Sequential descriptor parsing, including valid multi-word formats, grammar-consumed inter-field whitespace, strictly shorter literal suffixes, actual consumed byte ranges, independence from current and historical width vectors, and rejection of thrown errors, nil results, no progress, synthesized non-suffix results, semantic mismatches, and missing or invalid descriptor-required separators. Parseable alignment/separator whitespace changes are accepted and normalized by successful execute plus refresh rather than reported as standalone metadata edits.
- Marked suffixes and complete unmarked rows use `vim.trim()` semantics for path-boundary normalization and exact retained half-open byte ranges, including last-column padding, leading and trailing suffix whitespace, internal spaces, no-column rows, and an end-of-line zero-width repair boundary when trimming retains no path bytes.
- An exact prepare test uses an otherwise unmarked physical row whose first byte is `0x1f` and requires a row-specific reserved-prefix collision error; valid marked paths, loaded entries, marked moves, and internal path components containing `0x1f` remain accepted on this basis.
- Marked-kind tests cover retained local and foreign stable rows: directories without `/` fail, files with `/` fail, and symlinks with `/` fail, while their correctly suffixed counterparts retain their original kind.
- Same-instance stable-ID occurrence interpretation.
- Foreign-instance marker resolution without node-ID collision binding.
- Plan normalization and directory shadowing, including moving a descendant out before parent deletion.
- Ancestor move/copy normalization prioritizes implied descendant targets over line order and schedules extra copies before source-removing ancestor moves.
- Exact public plan-schema validation.
- Root containment through symlinked parent directories.
- Move dependency graphs and cycles.
- GC candidate ordering.
- Configuration precedence covers repeated `setup()` reset from exact built-ins, the first-call-only Manager `default_file_explorer` decision with later values silently discarded, rejection of that field in `new()`, wholesale sequence replacement, named-map merging, user mapping merge by mode/LHS across setup then new, `use_mapping_default` installation from a separate internal base, exact public `mapping = {}`, manager-owned setup `gc.groups`, instance-selected `gc.group`, and rejection of instance `max_instances`.
- Mutable-table snapshot isolation covers setup tables, new-option tables, columns, user mappings, named maps, `instance.config`, and already-installed mappings; caller mutation and later repeated setup do not affect existing instances.
- Recursive serializability validation for `buffer.variables`.
- Execution state tests allow exactly `running -> succeeded`, `running -> failed`, `running -> canceling -> canceled`, and `running -> canceling -> failed`; `refreshing` is asserted only as an independent phase. They also cover copied status/progress/result tables, logical completed/total accounting, current-operation copies, partial-current values, and single-use terminal handles.
- Synchronous malformed Plan and handler validation creates no handle and starts no filesystem work.
- Direct `execute()` before asynchronous initial `real_root` resolution and required root-load readiness completes synchronously raises the lifecycle/readiness Vim error, creates no Execution, acquires no lock, and starts no I/O; constructor filesystem work remains asynchronous.
- Protected-handler tests verify that a throwing `on_progress` is reported exactly once, disables only further progress delivery, and lets the executor continue through later work and completion; a throwing `on_complete` is attempted and reported exactly once without changing terminal state, request-owned resource closure, unlock, result, or completion cardinality.
- Completion ordering tests assert that execute restores/unlocks, reaches terminal state, clears the active reference, and delivers terminal progress/result before protected `on_complete`; execute has no presentation prerequisite. The `actions.write` wrapper closes, notifies/presents, and then forwards outer completion behavior exactly once.
- `cancel()` returns `false` when phase is already `refreshing`, on a repeated call after an accepted cancellation, and in every terminal state.
- Fake-request cancellation at a queued request asserts `uv_cancel = "accepted"` immediately after a successful `request:cancel()` return and before invoking the later `ECANCELED` callback; that callback is resource-closure-only and cannot revise classification, status, partial-current, exactly-once completion, scheduling, resource ownership, or any filesystem path.
- Fake-request `EBUSY` covers immediate canceled completion plus late success and late error callbacks that close only their owned resources and cannot change status, schedule work or path deletion, refresh, unlock, or complete twice.
- Fake-request cancellation at a no-request serial boundary records `no_request` and schedules no following step.
- Table-driven ordinary-operation partial-current accounting covers known untouched (`false`), known partial (`true`), and late-`EBUSY` ambiguous (`"unknown"`) cases without adding recovery arrays.
- Table-driven move-cycle accounting always reports `partial_current = "unknown"` for a partially finished cycle regardless of which private moves ran, with no per-move or residual-path recovery arrays.
- Terminal candidate scheduler tests instrument success and cancellation refreshes to assert root-first scan order and at most one outstanding scheduling request for the active Execution generation, while a separate ordinary refresh test permits concurrent reads of different directories.
- Failure/cancellation cleanup tests leave known cycle or copy temporary paths on disk, identify them only in the existing direct error or `detail` text, launch no cleanup filesystem request, expose no recovery array/state, and permit both a later Execution and later explicit destroy while an old quarantined RequestRecord closes only its owned resources.

### Headless Neovim integration tests

- First setup with `default_file_explorer = true` sets both netrw loaded globals, clears an existing `FileExplorer` augroup, installs exactly one Manager `BufEnter` takeover, and immediately checks an already-current local directory buffer.
- First setup with `default_file_explorer = false` performs none of those takeover effects and leaves a directory buffer available to netrw or another plugin.
- Later setup calls update their other defaults but silently discard both true and false `default_file_explorer` values, including values that would otherwise fail boolean validation; the first retained value and installed takeover behavior never change.
- `new({ default_file_explorer = true })` and the false equivalent both raise setup-only-field validation errors.
- Directory takeover covers startup-equivalent current-directory handling and `:edit dir/`, creates an independent no-predecessor instance from current setup defaults, and replaces only the entered window.
- Takeover ignores unnamed, non-local URI/scheme, ordinary-file, invalid, and Fre-owned buffers; replacement-triggered `BufEnter` cannot recurse or create a duplicate instance.
- A modified directory buffer raises a direct Vim error and remains unchanged. An unmodified original buffer is deleted only after no window displays it; synchronous construction failure leaves it in place, while asynchronous load failure follows the normal instance error path.
- Instance creates a hidden `acwrite` buffer immediately.
- Physical stable markers are concealed by syntax while raw buffer APIs expose marker, real columns, and path.
- Extmarks provide internal highlights and row lookup but are not copied identity or repair state and are never exposed by `get_pos()`.
- Normal and Visual mode can enter real columns while positions inside the concealed marker clamp to the first visible field.
- `InsertEnter`, `InsertCharPre`, and `CursorMovedI` use the decoder's first retained path byte rather than the raw suffix start, including the end-of-line repair boundary for an empty-after-trim marked path.
- Insert attempts on a malformed marked row report an error and insert no byte.
- Visual and characterwise yanks can copy column text.
- Same-instance `yy`/`p` preserves local identity; cross-instance `yy`/`p` resolves the live source instance/node even when numeric node IDs collide.
- Cross-instance paste works when source and destination column configurations differ.
- A source-only rerender or dynamic width-vector change after a marked row is pasted does not invalidate destination parsing.
- Destroying or releasing the foreign source instance/node before destination `prepare()` produces a row error, no Plan, and leaves the destination modified.
- Semantic read-only-column changes, descriptor-required separator failures, and malformed or unknown markers produce row errors without automatic repair; parseable alignment/separator whitespace alone is normalized after successful execution.
- Complete marker removal is presented as delete plus create rather than silently restored.
- Roots and filesystem entries containing newline bytes fail validation/loading with explicit unsupported-name errors.
- `vim.b.fre` metadata and valid configured buffer variables exist.
- Invalid or cyclic `buffer.variables` are rejected.
- Expand inserts only the requested subtree.
- Multiple branches share prefixes without duplicate nodes.
- Collapse removes one contiguous range and preserves cached state.
- Reveal expands ancestors without opening a window and uses the tuple returned by `get_pos()`.
- Reveal target is applied when the instance is later opened.
- Real columns exist in buffer text, participate in parsing, and mark the buffer modified when edited.
- Expand, collapse, filter, and refresh retain incremental row patches when the dynamic width vector is unchanged and rerender all visible rows when it changes.
- `get_pos(path)` returns the exact `{ row, col }` after dynamic columns, including UTF-8 byte offsets, no-column rows, trimmed row boundaries, and empty-path EOL repair.
- `get_pos(path)` uses the Entry lexical root-relative normalizer: `src` and `src/` select the same snapshot node, `/` separators normalize consistently, and meaningful path whitespace is not trimmed.
- `get_pos(path)` remains correct after incremental inserts and full width-change rerenders and while the buffer is modified; the old root-relative snapshot path remains a key while an unsaved renamed path does not.
- `get_pos(path)` returns `nil` for absent, collapsed, not-visible, and completely marker-removed rows, while a retained malformed marked row raises a row-specific Vim error.
- Explicit `get_pos()` operator-history tests cover `dd`/`p` self-healing when the old hint no longer matches, `yy`/`p`, a duplicate pasted before the original while the valid old hint remains authoritative, a missing hint choosing the lowest duplicate, undo rebinding, and redo rebinding.
- Table-driven `get_entry()` tests cover `nil` for out-of-range, absent, blank, unmarked-new, and completely marker-removed rows; valid local, live-foreign, and duplicate occurrences returning independent fresh tables with exactly `instance_id`, `node_id`, `absolute_path`, `relative_path`, `name`, and `kind`; positive-integer IDs; normalized absolute paths without display slashes; normalized `/` root-relative paths without display slashes; root Entry `relative_path = ""`; and row-specific Vim errors for malformed markers, reserved-prefix collisions, unknown markers, destroyed foreign sources, invalid source nodes, every descriptor-parse failure category, semantic read-only changes or equality-callback errors, and every kind/trailing-slash mismatch.
- Sort-callback tests assert exact root `parent_entry` values and that directory Entries omit `/` while directory row rendering alone appends it.
- Directory rename rewrites visible descendant prefixes using exact retained path ranges without consuming raw-suffix boundary whitespace.
- H1 operations fail while modified.
- During execution the source buffer is nonmodifiable; edits, write, prepare, another execute, projection changes, sort/filter changes, reveal, and refresh fail while navigation, open/hide/toggle/select, `get_entry()`, and `get_pos()` remain usable.
- `get_entry()` and action-context rows are 1-based; action-context columns are 0-based UTF-8 byte offsets.
- Function mappings receive action context; exact defaults install `<CR>`, `zv`, `zc`, `za`, `q`, `g.`, and `R`, install no `h` or `l`, and obey true/false `use_mapping_default` without per-key disable syntax.
- Open/hidden/toggle layouts behave per current tab.
- `actions.write` immediately opens and focuses one unlisted scratch progress float whose spinner, phase, current logical operation, detail, and counts update without writing progress text into the source buffer.
- Geometry tests cover the exact `available_width`, `available_height`, threshold errors at width below 3 or height below 6 before execute/I/O, `min(80, available_width - 2)` content width, four content rows, two-cell rounded-border additions, floor-centered editor-relative row/col, and display-cell truncation.
- Explicit `c`, `C`, `q`, `Esc`, `:close`, `<C-w>c`, and external `WinClosed` close immediately and request cancellation regardless of its return; focus loss alone does neither.
- Programmatic `cancel()` returning `true` closes only its associated default float, while a `false` return has no UI effect; success and failure auto-close, and the internal-closing guard prevents recursive cancellation.
- Canceled write emits a partial/discarded summary, success emits its execution summary, and the progress UI cannot be minimized, reopened, or restored.
- Direct `execute()` creates no UI, and a function second argument behaves exactly as `on_complete`.
- `actions.select`, `actions.tab_select`, and `actions.split_select` each reject both `opts.instance.root` and `opts.instance.inherit` before creating a child.
- Every select variant opens the snapshot source `Entry.absolute_path` for unsaved renamed and duplicated marked rows; it never opens the retained edited destination text.

### Mutation integration tests

- New file and directory creation.
- Leading and trailing path whitespace on marked and unmarked rows is silently normalized by `vim.trim()` semantics and disappears after successful write and refresh, while internal spaces remain literal; exact retained ranges cover last-column padding, leading/trailing suffix whitespace, empty-after-trim repair, and no-column rows.
- Rename within one directory.
- Move across directories under the root.
- Copy by duplicated same-instance stable ID.
- Cross-instance file and recursive directory copy from an external `copy.from` into the destination root.
- Cross-instance copy still works after source-instance destruction when destruction happens after prepare produced the absolute-path Plan.
- Recursive directory copy.
- Recursive directory delete.
- Parent move/delete shadows only operations it truly subsumes.
- Parent directory rename plus an earlier-buffer-line descendant duplicate still carries the implied descendant and copies the extra target before the parent move.
- Editing away an ancestor-copy-implied descendant target is rejected unless the implied occurrence remains and the edit is represented by an additional duplicate.
- Moving or copying a descendant outside a deleted parent is preserved and ordered first.
- Two-node and longer move cycles use temporary paths.
- Case-only rename where supported.
- Cross-device move uses a serial copy-delete fallback.
- Execution failure restores exact pre-execution text, `modified`, and `modifiable`, and does not refresh despite any completed filesystem effects.
- Successful execution refreshes exactly once, restores the configured/pre-execution `modifiable` value, and marks `nomodified`.
- Direct `execute(plan)` works without preceding prepare.
- Direct malformed plans reject synchronously with no handle or filesystem request; valid ready-instance plans perform all preflight, containment, `lstat`, `realpath`, mutations, traversal, terminal scans, and request-owned resource closure asynchronously.
- Direct plans reject malformed schemas, unknown fields, invalid display arrays, out-of-root mutating paths, parent-symlink escapes, and a directory move/copy targeting its own descendant before any mutation; the descendant-target test calls `execute(plan)` directly and verifies the filesystem is untouched.
- Direct plans permit an external absolute `copy.from` while requiring `copy.to` inside the destination root.
- Root containment is rechecked asynchronously before every mutating physical step, including a plan that first moves or copies a symlink into a later target's ancestry.
- Cancellation during asynchronous preparing performs no later preflight or mutation request; a successful terminal rescan clears edits, restores the configured/pre-execution `modifiable` value, and reports canceled.
- Cancellation during an ordinary operation stops all later Plan operations and reports the current operation as incomplete.
- Cancellation during recursive copy/delete stops the serial chain, retains partial filesystem effects, and reports a partial current operation.
- Cancellation during a move cycle stops the serial rotation, may leave its private temporary path, and reports partial completion without counting the current logical move complete.
- Cancellation results cover `accepted`, `busy`, and `no_request`; `accepted` is asserted immediately from the successful cancel return before the later cleanup-only `ECANCELED` callback, and late `EBUSY` callbacks clean resources without duplicate completion.
- A success or cancellation terminal candidate refresh failure transitions to `failed` (including `canceling -> failed`), surfaces the direct refresh error, leaves the authoritative tree/view unchanged, restores exact pre-execution text, `modified`, and `modifiable`, unlocks, and completes exactly once without a second recovery state machine.
- Success and cancellation after deleting an expanded directory scan root first, prune the missing expanded branch without an `ENOENT` failure, and commit the candidate; equivalent tests cover moving an expanded directory. Other retained-directory scan errors fail the complete candidate atomically.
- `actions.select()` defaults to `ctx.winid`, honors `opts.target_winid`, and rejects invalid windows.

### Watch tests

- Root changes refresh only root children.
- Expanded child changes refresh only that node.
- Collapsing stops inactive subtree watchers.
- Re-expanding recreates watchers.
- Modified buffers ignore events.
- Self-generated execution events are ignored while the lock is active.
- Cancellation watcher tests cover both outcomes after the point-in-time terminal rescan: a delivered late-`EBUSY` event triggers a watcher refresh after unlock, while a raced/lost event triggers no automatic reconciliation and truth returns only on a visibility-triggered rescan or explicit `refresh()`.
- Stale async generations cannot patch the buffer.

### GC tests with a fake clock

- Hidden TTL begins at creation for never-opened instances.
- Visibility resets TTL.
- `ttl_ms = 0` disables TTL.
- Group max evicts oldest hidden instance.
- Group max zero disables capacity GC.
- Visible instances cause temporary overflow.
- Modified instances with no active Execution are force-destroyed when selected.
- Explicit destruction during every nonterminal Execution state synchronously raises the direct Vim error and changes nothing.
- TTL and capacity collisions with every nonterminal Execution state receive and internally report the same error, change nothing, and drop the attempt; no pin, defer queue, retry timer, or detached state exists, and destruction occurs only after a later ordinary GC trigger or explicit destroy.
- After an Execution becomes terminal, successful destruction discards instance-owned `hidden_since`/GC state and invalidates outstanding non-Execution loads, refreshes, watcher timers, and watcher callbacks only; their late callbacks close required resources without touching Neovim state. Manager has no visibility or timestamp index.

### Inheritance tests

- Child-root inheritance retains only descendant expansion.
- Parent-root inheritance synthesizes the connecting chain.
- Same-root inheritance copies state.
- Unrelated roots inherit nothing.
- Collapsed barriers preserve dormant expanded descendants.
- Missing inherited paths drop one branch only.
- Explicit sort/hidden options beat predecessor state.
- Otherwise predecessor sort and hidden state beat setup defaults.
- Later changes do not propagate between instances.

## 39. Acceptance Criteria

The design is implemented successfully when all of the following are observable:

1. A Fre instance can be created for a local directory without opening a window.
2. Its buffer displays editable root-relative paths.
3. Arbitrary nested and branching directories can be expanded incrementally.
4. Entry values use positive-integer IDs, normalized absolute and `/` root-relative filesystem-semantic snapshot paths without display slashes, and `""` for the root relative path; only directory rows append `/`, and sort receives the exact root parent Entry.
5. `get_pos(path)` applies that same lexical root-relative normalizer, treats one display trailing slash equivalently without trimming meaningful whitespace, resolves a visible snapshot node, and returns its exact 1-based row and 0-based retained-path byte column without exposing extmarks, scanning arbitrary edited paths, or treating unsaved renamed text as a new key.
6. `get_pos(path)` handles dynamic columns, UTF-8, no-column and trim/empty row boundaries, returns `nil` for absent/collapsed/marker-removed rows, and raises a row-specific error for retained malformed marked rows.
7. Columns are real parseable buffer text, use per-render visible-row maximum widths, can be selected and yanked normally, and remain semantically read-only in the first implementation; the shared decoder parses them sequentially with descriptor-owned, width-independent grammars and exact actual-consumption ranges.
8. Every directory independently sorts direct children with the instance comparator.
9. `set_sort()` refreshes using the new comparator without a separate sort subsystem.
10. Modified buffers block projection changes but can remain hidden or be destroyed when no Execution is nonterminal.
11. New instances inherit expansion, sort, and hidden-file state with documented precedence.
12. `select`, `tab_select`, and `split_select` compose file opening or child-instance creation, reject caller root/inherit overrides, and select snapshot sources for unsaved renamed or duplicated marked rows.
13. Configuration resets from exact built-ins on every setup, replaces sequences, merges named maps, snapshots mutable tables, exposes `use_mapping_default = true` with `mapping = {}`, and derives installed mappings from the separate internal base plus user overrides. Mapping values are functions with no per-key disable syntax; exact defaults retain `<CR>`, `zv`, `zc`, `za`, `q`, `g.`, and `R` and add no `h` or `l`.
14. `prepare()` recognizes create, copy, move, and delete from ordinary buffer edits, including cross-instance copies resolved through namespaced markers, and applies the documented `vim.trim()` retained-range and marked-kind contracts.
15. Confirmation shows logical operations only.
16. `execute(plan)` rejects lifecycle-unready instances synchronously without a handle or I/O, accepts a plain plan independently of prepare provenance once ready, synchronously enforces the exact pure-Lua schema, and asynchronously enforces preflight plus per-step root/symlink safety.
17. A valid `execute()` returns a single-use Execution exposing only cancellation and copied status; state transitions are exactly the four documented paths with `refreshing` only a phase, and protected handlers support progress, exactly-once completion, function shorthand, and error reporting that cannot alter execution or callback cardinality.
18. Every Execution filesystem call, including terminal candidate refresh, uses callback-form `vim.uv`, retains at most one scheduling request per active generation, and advances recursive, cross-device, cycle, and terminal-scan work serially; ordinary refresh may read directories concurrently and quarantined resource-closure-only RequestRecords from older generations may coexist.
19. Cancellation immediately invalidates all chains, attempts active request cancellation, never counts a partial current logical operation complete, and immediately performs serial root-first reconciliation/unlocks without waiting for an `EBUSY` callback.
20. Terminal reconciliation scans root first and scans only candidate-existing expanded directories; completed deletion or movement of expanded directories prunes them normally, while other scan errors fail atomically.
21. Successful terminal refreshes after success or cancellation leave the source buffer `nomodified` and restore its configured/pre-execution `modifiable` value; any execution or terminal refresh failure leaves the authoritative tree/view unchanged as applicable and restores exact pre-execution text, `modified`, and `modifiable`, with cancellation refresh failure classified as failed.
22. Execute restores/unlocks, terminalizes, clears the active reference, and delivers terminal progress/result before protected completion, with no presentation prerequisite. Only `actions.write` creates and presents the fixed-geometry immediate progress float before forwarding outer completion behavior; its exact close/cancel semantics preserve false programmatic cancel calls as UI-inert.
23. Move cycles and cross-device moves use invisible serial physical steps. Successful logical operations finish required cycle-temporary steps before completion; failure or cancellation may leave partial state or temporary paths and launches no post-terminal path cleanup or recovery machinery.
24. Unrelated external changes do not block optimistic execution; cancellation reconciliation is point-in-time and best-effort, a watcher may observe a late `EBUSY` effect but the event can race and be lost, and visibility-triggered or explicit refresh restores truth without watcher recovery flags.
25. Actual filesystem conflicts and refresh/handler/request-resource failures surface as Vim errors under the documented rules.
26. Watch refresh is per directory node and never overwrites modified text.
27. TTL and group-capacity GC obey independent zero-disable semantics. Automatic collisions with nonterminal Execution report and drop the attempt without retry/defer/pin state; explicit collisions raise directly and change nothing.
28. `vim.b.fre`, filetype, buffer options, and lookup APIs allow user policy such as automatic cwd.
29. The first setup's `default_file_explorer` value permanently decides whether Fre disables netrw and takes over entered local directory buffers; later setup calls silently discard only that field, `new()` rejects it, and takeover creates ordinary independent Fre instances without a second directory registry.

## 40. Explicit Trade-offs

This design intentionally accepts:

- More internal tree and extmark machinery in exchange for incremental file-view performance, while keeping extmark IDs private.
- Real columns make rendered metadata part of the ordinary-space-separated physical line protocol so ordinary Vim yanks can copy it; grammar-consumed alignment/separator whitespace has no immutable visual owner and is normalized after successful execution.
- Dynamic column widths can turn a logically local projection change into a full visible-row rerender when alignment widths change.
- Oil-style `vim.trim()` path-boundary normalization means leading and trailing path whitespace is not round-trippable and is silently removed after successful write and refresh; internal spaces remain literal.
- An otherwise unmarked new path cannot begin with reserved byte `0x1f`, although valid marked paths and internal path components may contain it.
- No automatic marker or semantic read-only-column repair; destructive edits may become explicit errors or delete-plus-create plans.
- Cross-instance copy depends on the source instance and node remaining live until prepare resolves the source path, descriptors, and snapshot; no instance pinning or clipboard provenance is retained, while source width changes alone do not invalidate pasted rows.
- Asynchronous complexity and intentionally serial executor I/O in exchange for immediate handle creation, best-effort cancellation, and explicit partial-state accounting.
- Cancellation may not stop an `EBUSY` OS call, may leave a partial file/tree/cross-device move/cycle and executor temporary paths, provides only a point-in-time terminal rescan, and performs no post-terminal path deletion.
- Forced loss of unsaved edits when GC or explicit destruction succeeds, or when accepted execution cancellation completes a successful terminal refresh; a failed terminal refresh instead restores the exact pre-execution snapshot.
- No automatic merge of external changes.
- Partial filesystem mutation when execution fails or is canceled mid-plan, with no rollback.
- Errors for projection actions on modified or execution-locked buffers instead of a persistent hidden draft model.
- Local-only scope instead of carrying Oil's adapter architecture or using a worker process or external copy/delete commands.
- Re-reading root and candidate-existing expanded directories after successful or canceled execution instead of maintaining a perfect predictive cache.
- One immediate, non-reopenable default write-progress float rather than delayed, minimized, or persistent progress presentation.
- A first-setup-only process-wide file-explorer decision rather than reversible netrw restoration or runtime takeover switching; `BufEnter` creates an instance only when a directory is actually entered instead of pre-creating one for every added directory buffer.

These trade-offs preserve a small public model while keeping common expansion, refresh, lookup, selection, execution observation, and best-effort cancellation predictable.

## 41. Open Questions

There are no unresolved product or architecture questions required before implementation planning. Implementation may choose concrete helper names and test tooling while preserving the contracts in this document.
