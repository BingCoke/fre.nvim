# Oil-Style Render Protocol Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Fre's split navigation/entry renderer with one Oil-style dynamic-width row protocol that aligns columns, opens `../`, never intentionally paints IDs before conceal, and initially anchors the cursor at path while leaving visible metadata traversable.

**Architecture:** Manager owns dynamic decimal marker widths and instance construction. A new `fre.row` module is the sole serializer/parser and two-pass field layout engine; `fre.buffer` owns only Neovim text commits, decoration, cursor/view restoration, and buffer autocmds. Window transitions prepare conceal/options before exposing a marked Fre buffer, and actions branch on decoded row semantics before requiring an Entry.

**Tech Stack:** LuaJIT/Neovim Lua API, Vim syntax conceal, existing Fre Tree/Instance/Manager/window APIs, local `../oil.nvim` render/parser behavior as reference.

## Global Constraints

- Work directly in `/Users/bingcoke/project/lua/fre.nvim` on the current `gpt` branch; do not create a worktree.
- Do not add, edit, or run automated tests unless the user explicitly changes that constraint.
- Preserve marker-based same-instance duplication and cross-instance real-entry yank/paste.
- Identity remains ordinary buffer text and is concealed; do not replace it with extmark-only provenance.
- Marker IDs are decimal, start at width 3, grow dynamically without a fixed display-width ceiling, and never shrink during a Manager lifetime.
- Node ID zero is the only navigation sentinel; real instance and node IDs remain positive.
- One render uses one width snapshot, so every canonical row in that projection has an equal marker length.
- Identity is an internal structural field; configured custom columns support dynamic text and `left`, `center`, or `right` projection alignment; path remains the unbounded final field.
- Projection column widths may grow or shrink. Cursor restoration must preserve the same field content position rather than a raw byte/display column or an offset into alignment padding.
- Initial display, parent navigation, and reveal anchor at path start. Later Normal, Visual, and Insert movement may enter navigable visible metadata but never the concealed identity or leading non-navigable icon.
- Read-only metadata changes are rejected at write preparation, not while the user is moving or typing.
- Do not overwrite a modified buffer to migrate marker width.
- Remove superseded `fre-nav`, manual syntax reinstall, duplicate column rendering, pseudo-ternary navigation, and path-only cursor code; do not retain compatibility branches for the just-replaced internal protocol.
- Do not stage or commit `.pi-subagents/`, `.ralph/`, `.scratch/`, `prom.md`, or generated review artifacts.

---

## File Map

- Create `lua/fre/row.lua`: unified marker codec, historical-width validation, synthetic navigation semantics, two-pass field layout, line parser, identity matching, and semantic cursor anchors.
- Create `syntax/fre.vim`: authoritative filetype conceal rule for the unified marker grammar.
- Modify `lua/fre/manager.lua`: dynamic marker widths/generation, coalesced stale-view notification, and Manager-owned instance construction.
- Modify `lua/fre/tree.lua`: report every allocated node ID to the Manager width owner.
- Modify `lua/fre/init.lua`: delegate public instance construction to `manager.default:create_instance()`.
- Modify `lua/fre/takeover.lua`: use Manager-owned construction and the prepared-window replacement path.
- Modify `lua/fre/columns.lua`: central field alignment helper, descriptor navigability validation/defaults, and retained single-render callback results.
- Modify `lua/fre/buffer.lua`: consume `fre.row`, commit text/decorations, restore semantic cursor anchors, constrain only the leading prefix, and remove marker/layout/syntax duplication.
- Modify `lua/fre/instance.lua`: marker-generation state, width-only reproject callback, raw line mutation boundary, and first-render cursor state.
- Modify `lua/fre/mapping.lua`: trust the mapped expected instance and expose decoded row semantics without default-Manager rediscovery.
- Modify `lua/fre/actions.lua`: explicit navigation/entry selection target resolver and source-Manager child construction.
- Modify `lua/fre/window.lua`: prepare options before buffer exposure, track/restore prior window options, and request initial path placement.
- Modify `lua/fre/mutation/prepare.lua`: continue excluding node-zero navigation through the new decoded protocol.
- Modify `README.md`, `docs/superpowers/specs/2026-07-24-fre-buffer-file-manager-design.md`, and `docs/superpowers/specs/2026-07-27-navigation-size-cursor-design.md`: replace superseded marker/cursor/render contracts.

---

### Task 1: Manager-Owned IDs, Width Generation, And Construction

**Files:**
- Modify: `lua/fre/manager.lua`
- Modify: `lua/fre/tree.lua`
- Modify: `lua/fre/init.lua`
- Modify: `lua/fre/takeover.lua`
- Modify: `lua/fre/instance.lua`

**Interfaces:**
- Produces: `Manager:get_marker_widths() -> { instance, node, generation }` copied snapshot.
- Produces: `Manager:observe_node_id(id) -> boolean` where `true` means width grew.
- Produces: `Manager:create_instance(opts) -> Instance` as the only Manager-domain constructor.
- Produces: optional `Instance:_on_marker_width_changed(generation)` callback invoked by a coalesced Manager schedule; later tasks implement its rendering behavior.

- [ ] **Step 1: Add monotonic marker-width state and helpers to Manager**

Initialize:

```lua
_marker_widths = { instance = 3, node = 3, generation = 1 },
_marker_width_refresh_scheduled = false,
```

Add a private decimal digit helper and growth method:

```lua
local function decimal_width(id)
  return #tostring(id)
end

function Manager:_observe_marker_id(field, id)
  if type(id) ~= "number" or id < 0 or id % 1 ~= 0 then
    fail(field .. " marker ID must be a non-negative integer")
  end
  local width = math.max(3, decimal_width(id))
  if width <= self._marker_widths[field] then return false end
  self._marker_widths[field] = width
  self._marker_widths.generation = self._marker_widths.generation + 1
  self:_schedule_marker_width_refresh()
  return true
end
```

`allocate_id()` must observe the instance ID before returning it. `observe_node_id()` delegates to the node field. `get_marker_widths()` returns a detached three-field table, never the mutable Manager table.

- [ ] **Step 2: Add one coalesced stale-view notification**

Implement `_schedule_marker_width_refresh()` with one `vim.schedule()` per generation burst. The callback clears its scheduled flag, captures the current generation, and invokes `instance:_on_marker_width_changed(generation)` only when that function exists. Wrap each callback in `pcall`; route errors through `instance:_report_async_error()` when available so one instance cannot suppress the others.

Do not mutate buffer text in Manager.

- [ ] **Step 3: Report root and allocated node IDs from Tree**

In `Tree.new()`, call `instance.manager:observe_node_id(root.id)` after root creation. In `Tree:_allocate_id()`, observe the incremented value before returning it:

```lua
function Tree:_allocate_id()
  self.instance._next_node_id = self.instance._next_node_id + 1
  local id = self.instance._next_node_id
  self.instance.manager:observe_node_id(id)
  return id
end
```

Cloning retains existing IDs and does not allocate; the source Manager has already observed them.

- [ ] **Step 4: Move construction into Manager**

Add `Manager:create_instance(opts)` and move the exact public validation/root/inheritance/config path from `fre.init.new()` into it. Use lazy `require()` calls inside the method to avoid module cycles:

```lua
function Manager:create_instance(opts)
  -- validate table/root exactly as the current public constructor does
  local root = require("fre.path").absolute(opts.root)
  local inheritance = require("fre.inheritance")
  local snapshot = inheritance.snapshot(opts.inherit)
  local expansion = snapshot and inheritance.compile(snapshot, root) or nil
  local effective = self:resolve_instance_config(opts, opts.inherit)
  return require("fre.instance").new(self, root, effective, expansion)
end
```

Change `fre.new(opts)` to `return manager_module.default:create_instance(opts)`. Change takeover's local constructor to `return manager:create_instance({ root = root })`.

- [ ] **Step 5: Add marker-generation fields to Instance construction**

Initialize `_marker_width_stale = false` and `_pending_initial_cursor = {}`. Initialize `view` with `marker_generation = 0` beside the existing empty baseline. Do not implement reprojection in this task.

- [ ] **Step 6: Run static verification and commit**

Run:

```sh
luac -p lua/fre/manager.lua lua/fre/tree.lua lua/fre/init.lua lua/fre/takeover.lua lua/fre/instance.lua
git diff --check
```

Expected: both commands produce no output and exit zero.

Commit only these files:

```sh
git add lua/fre/manager.lua lua/fre/tree.lua lua/fre/init.lua lua/fre/takeover.lua lua/fre/instance.lua
git commit -m "refactor: centralize render identity state"
```

---

### Task 2: Unified Row Codec And Dynamic Column Layout

**Files:**
- Create: `lua/fre/row.lua`
- Modify: `lua/fre/columns.lua`
- Modify: `lua/fre/buffer.lua`
- Modify: `lua/fre/instance.lua`
- Modify: `lua/fre/mutation/prepare.lua`

**Interfaces:**
- Consumes: `instance.manager:get_marker_widths()` from Task 1.
- Produces: `row.marker(manager, instance_id, node_id, widths?) -> string`.
- Produces: `row.decode(instance, row_number, line, opts?) -> DecodedRow|nil`.
- Produces: `row.prepare(instance, projection, render_path, opts?) -> PreparedProjection`.
- Produces: `row.matches_identity(instance, line, instance_id, node_id) -> boolean`.
- Preserves: `buffer.marker`, `buffer.decode`, `buffer.row_has_marker`, and `buffer.find_marker_rows` as thin internal compatibility wrappers while production callers migrate to semantic identity helpers.

- [ ] **Step 1: Create the marker codec in `fre.row`**

Use one prefix:

```lua
local US = string.char(31)
local PREFIX = US .. "fre:"
```

`marker()` formats decimal IDs with zero padding from a captured Manager width snapshot. Instance IDs must be positive; node IDs may be zero. `decode_marker()` accepts historical widths from 3 through the Manager's current field width and verifies canonical zero padding by reconstructing the text at its own observed width.

Return raw marker end byte, decoded IDs, and raw marker text. Reject `fre-nav`, malformed reserved prefixes, negative/non-decimal values, under-width fields, over-current-width fields, and noncanonical padding with row-specific errors.

- [ ] **Step 2: Move synthetic navigation semantics into the unified decoder**

For `node_id == 0`, resolve the source instance from the marker's instance ID, derive `parent` versus `root` from `path.parent(source.root)`, and use the callback-only Entry already defined by the current navigation implementation. Return:

```lua
{
  kind = "navigation",
  row_kind = "navigation",
  marked = true,
  synthetic = true,
  instance_id = source.id,
  source_instance_id = source.id,
  node_id = 0,
  navigation_kind = navigation_kind,
  entry = nil,
}
```

For positive node IDs, retain `kind = "existing"` and public `row_kind = "entry"`. Unmarked lines remain `row_kind = "new"`.

- [ ] **Step 3: Centralize field alignment in `columns.lua`**

Export one helper:

```lua
function M.align(text, width, actual_width, align)
  local padding = width - actual_width
  if align == "right" then return string.rep(" ", padding) .. text, padding end
  if align == "center" then
    local left = math.floor(padding / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", padding - left), left
  end
  return text .. string.rep(" ", padding), 0
end
```

Add descriptor field `navigable` with boolean validation. Defaults are: icon `false`; permissions, size, and mtime `true`; custom `true` unless explicitly false. Keep `align = left|center|right` validation and custom's left default.

- [ ] **Step 4: Implement a single two-pass projection layout**

Move `buffer.prepare()`'s semantic row construction and layout into `row.prepare()`.

First pass:

- capture one Manager marker-width snapshot;
- synthesize node-zero navigation before real projected nodes;
- create callback Entry/context once per semantic row;
- invoke each descriptor's `render` exactly once and retain `{ text, highlight, display_width }`;
- compute projection maximum width per descriptor.

Second pass:

- format the unified marker;
- call `columns.align()` for each retained chunk;
- join one-space separators and final path;
- derive highlights and per-identity row templates from the final bytes;
- record each aligned field's physical range, exact rendered-content range, leading padding, trailing padding, and separator range in that row template;
- use template key `0` for navigation instead of a separate navigation template table;
- retain `marker_widths`, `marker_generation`, `column_widths`, `row_templates`, `row_offset = 1`, baseline, projection, and visible nodes in the prepared result.

- [ ] **Step 5: Implement the inverse streaming parser**

Move column parsing out of `buffer.lua` into `row.decode()`. Preserve parser progress and literal-suffix checks. Add `opts.validate_metadata`, defaulting to `true`; when false, parse ranges and values but skip descriptor `equals()` checks.

Record each field as:

```lua
{
  id = descriptor.id,
  value = value,
  range = { start_byte = ..., end_byte = ... },
  content_range = { start_byte = ..., end_byte = ... },
  separator_range = { start_byte = ..., end_byte = ... },
  navigable = descriptor.navigable,
  align = descriptor.align,
  width = source.view and source.view.column_widths[index] or nil,
}
```

For canonical marked rows, source `content_range` from the identity's prepared row template after verifying that its physical field range matches the parsed field range. This preserves intentional content versus alignment padding without re-running render callbacks. If no matching template exists (for example, a hand-edited malformed row), fall back to the parsed physical range. Set `navigable_range.start_byte` to the first navigable configured field, or path start when every descriptor is non-navigable. Set its end to path end.

- [ ] **Step 6: Reduce `buffer.lua` to integration wrappers**

Delete `encode_base36`, `decode_base36`, both marker-prefix constants, navigation marker functions, callback Entry/context duplication, local alignment, and local projection preparation. Require `fre.row` and delegate:

```lua
function M.marker(instance_id, node_id, manager)
  return row.marker(manager or require("fre.manager").default, instance_id, node_id)
end

function M.decode(instance, row_number, opts)
  return row.decode(instance, row_number, get_line(instance, row_number), opts)
end

function M.prepare(instance, projection, render_path, opts)
  return row.prepare(instance, projection, render_path, opts)
end
```

Replace raw current-width marker comparisons with decoded identity matching. Update `Instance:get_pos()` to search by `(instance_id,node_id)` semantics, not a reconstructed current-width string.

- [ ] **Step 7: Keep mutation exclusion semantic**

In `mutation/prepare.lua`, keep the early `decoded.synthetic` exclusion. Remove any marker-namespace assumption; node zero/navigation is excluded solely from decoded semantics.

- [ ] **Step 8: Run static verification and commit**

Run:

```sh
luac -p lua/fre/row.lua lua/fre/columns.lua lua/fre/buffer.lua lua/fre/instance.lua lua/fre/mutation/prepare.lua
git diff --check
rg -n "fre-nav|navigation_marker|encode_base36|decode_base36" lua/fre
```

Expected: syntax/diff checks produce no output; the `rg` command finds no production references.

Commit:

```sh
git add lua/fre/row.lua lua/fre/columns.lua lua/fre/buffer.lua lua/fre/instance.lua lua/fre/mutation/prepare.lua
git commit -m "refactor: unify row rendering and parsing"
```

---

### Task 3: Semantic Selection And Source-Manager Navigation

**Files:**
- Modify: `lua/fre/actions.lua`
- Modify: `lua/fre/mapping.lua`

**Interfaces:**
- Consumes: `Manager:create_instance(opts)` from Task 1.
- Consumes: decoded `row_kind`, `navigation_kind`, and `source_instance_id` from Task 2.
- Produces: one internal `selection_target(ctx, instance)` record used by select, tab-select, and split-select.

- [ ] **Step 1: Replace optional Entry pseudo-ternaries with one target resolver**

Implement explicit control flow:

```lua
local function selection_target(ctx, instance)
  if ctx.row_kind == "navigation" then
    if ctx.source_instance_id ~= instance.id or ctx.navigation_kind == "root" then
      return { kind = "noop" }
    end
    return { kind = "directory", root = assert(path.parent(instance.root)) }
  end
  local entry = entry_from(ctx)
  if entry.kind == "directory" then
    return { kind = "directory", root = entry.absolute_path, entry = entry }
  end
  return { kind = "file", path = entry.absolute_path, entry = entry }
end
```

Do not use `a and nil or b`. Unknown `row_kind` values continue through `entry_from()` and produce the existing direct action error.

- [ ] **Step 2: Make all selection actions consume the same target record**

`select`, `tab_select`, and `split_select` must:

- return `nil` for `noop`;
- open normal buffers for `file`;
- call `child_options(instance, opts.instance, target.root)` and then `instance.manager:create_instance(prepared)` for `directory`;
- retain their existing destination-window/tab/split rollback behavior.

`child_options()` only copies overrides and installs action-owned `root`/`inherit`; remove its eager discarded `resolve_instance_config()` call because `Manager:create_instance()` performs the authoritative resolution exactly once before any window mutation. Remove direct `require("fre").new()` calls from actions.

- [ ] **Step 3: Stop mapped contexts from rediscovering through the default Manager**

When `mapping.context(expected_instance)` receives the mapped instance, validate that the current buffer equals `expected_instance.bufnr`, that it is live, and that `expected_instance.manager:find_by_buf(bufnr) == expected_instance`. Only the public no-argument `actions.context()` path may discover through `manager.default`.

Keep decoded context fields unchanged.

- [ ] **Step 4: Run static verification and commit**

Run:

```sh
luac -p lua/fre/actions.lua lua/fre/mapping.lua
rg -n "navigation and nil|require\(\"fre\"\)\.new" lua/fre/actions.lua
git diff --check
```

Expected: no syntax/diff output and no forbidden action pattern match.

Commit:

```sh
git add lua/fre/actions.lua lua/fre/mapping.lua
git commit -m "fix: route navigation by row semantics"
```

---

### Task 4: Initial Path Anchor And Traversable Metadata Cursor

**Files:**
- Modify: `lua/fre/row.lua`
- Modify: `lua/fre/buffer.lua`
- Modify: `lua/fre/instance.lua`
- Modify: `lua/fre/window.lua`

**Interfaces:**
- Consumes: decoded `fields`, `path_range`, and `navigable_range` from Task 2.
- Produces: `row.cursor_anchor(decoded, col) -> { field_id, zone, display_offset }`.
- Produces: `row.cursor_column(decoded, anchor) -> byte_col`, preserving content-relative position across column growth and shrinkage.
- Produces: `buffer.place_initial_cursor(instance, winid) -> boolean`.
- Produces: `buffer.constrain_cursor(instance, winid) -> nil` using the first navigable field, not path-only enforcement.

- [ ] **Step 1: Add semantic cursor anchor helpers to `row.lua`**

Map a byte column to descriptor ID or `path`, a zone (`content`, `leading_padding`, or `trailing_padding`), and a display-cell offset. For `content`, measure from `content_range.start_byte`; for leading padding, measure backward from content start; for trailing padding, measure forward from content end. Separators map to the nearest preceding navigable field's content end.

Map the anchor back through the new row template by scanning UTF-8 byte boundaries. This is required for projection widths that grow or shrink: a cursor on a right- or center-aligned value must remain on the same content character even when leading padding changes.

Fallbacks are deterministic:

- missing descriptor after reconfiguration -> path start;
- content offset wider than the new rendered content -> content end;
- vanished leading/trailing padding -> nearest content boundary;
- row template unavailable -> physical field range with a clamped offset;
- undecodable row -> raw row/column fallback owned by buffer.

- [ ] **Step 2: Capture and restore semantic positions in buffer commits**

`capture_windows()` must decode with `{ allow_empty_path = true, validate_metadata = false }` under `pcall`. Store node identity plus semantic anchor when possible.

`restore_windows()` must:

- remap row by stable local node ID when available;
- decode the new row tolerantly;
- map the saved semantic anchor through `row.cursor_column()`;
- restore topline/view once;
- apply only the ongoing lower-prefix constraint.

Delete raw-column restoration followed by `clamp_cursor(path_range)`.

- [ ] **Step 3: Separate initial placement from ongoing constraint**

Replace `clamp_cursor()` with:

```lua
function M.constrain_cursor(instance, winid)
  -- tolerant decode
  -- clamp to decoded.navigable_range.start_byte .. decoded.path_range.end_byte
end

function M.place_initial_cursor(instance, winid)
  -- if canonical row 1 exists, set row 1/path_range.start_byte and clear pending
  -- otherwise mark instance._pending_initial_cursor[winid] = true
end
```

A successful commit consumes pending initial windows after canonical rows and decorations are installed. Reveal continues to use the selected row's path start.

- [ ] **Step 4: Mark first window presentation from window transitions**

Every path that newly puts an instance buffer in a window calls `buffer.place_initial_cursor(instance, winid)`. Reusing an already displayed same-instance window preserves its semantic cursor. A newly created child on a loading row remains pending until its first successful projection.

- [ ] **Step 5: Update cursor autocmd policy**

`CursorMoved`, `CursorMovedI`, `InsertEnter`, and `InsertCharPre` call the tolerant ongoing constraint. They never force a valid metadata position back to path. New unmarked rows remain unconstrained.

Remove any mode-independent path-only comments and helpers.

- [ ] **Step 6: Run static verification and commit**

Run:

```sh
luac -p lua/fre/row.lua lua/fre/buffer.lua lua/fre/instance.lua lua/fre/window.lua
rg -n "clamp_cursor|clamp_path" lua/fre
git diff --check
```

Expected: no syntax/diff output and no obsolete path-clamp references.

Commit:

```sh
git add lua/fre/row.lua lua/fre/buffer.lua lua/fre/instance.lua lua/fre/window.lua
git commit -m "refactor: restore cursors by rendered field"
```

---

### Task 5: Syntax-Owned Conceal And Prepared Window First Paint

**Files:**
- Create: `syntax/fre.vim`
- Modify: `lua/fre/buffer.lua`
- Modify: `lua/fre/instance.lua`
- Modify: `lua/fre/window.lua`
- Modify: `lua/fre/takeover.lua`

**Interfaces:**
- Produces: formal `fre` syntax conceal for the unified decimal marker.
- Produces: one window activation path that snapshots prior options, applies Fre options before buffer installation, stores ownership metadata, and restores prior options on exit.

- [ ] **Step 1: Add the authoritative syntax file**

Create `syntax/fre.vim`:

```vim
if exists('b:current_syntax')
  finish
endif

syntax match FreStableMarker /^\%x1ffre:\d\{3,}:\d\{3,}\%x1f/ conceal
let b:current_syntax = 'fre'
```

Keep the existing `FreStableMarker` highlight link in Lua setup. Do not add a `fre-nav` rule.

- [ ] **Step 2: Establish buffer syntax before marked rows**

Instance construction sets `filetype=fre` and `syntax=fre` before Tree load or canonical projection. Buffer setup may explicitly `runtime! syntax/fre.vim` once inside `nvim_buf_call()` to support hidden-first buffers, but it must not clear/reinstall syntax from lifecycle autocmds.

Delete `install_syntax()`, the `Syntax` autocmd, and `BufWinEnter` syntax installation.

- [ ] **Step 3: Create one window-option ownership record**

Extend window metadata with `previous_options` captured before the first Fre option application. When transitioning Fre A -> Fre B in one window, carry the underlying pre-Fre option snapshot instead of treating A's active options as B's baseline. When leaving Fre for a normal/scratch buffer, restore that snapshot and clear Fre ownership metadata.

Use explicit `{ scope = "local", win = winid }` for every read/write.

- [ ] **Step 4: Apply Fre options before exposing the Fre buffer**

Refactor current, split, float, and replace paths:

- current/replace: capture ownership, apply Fre options to target window, then call `nvim_win_set_buf()`;
- split: create the split with its inherited/current buffer, apply Fre options, then install the Fre buffer;
- float: open with a scratch buffer, apply Fre options, then install the Fre buffer and delete the now-hidden scratch;
- rollback: restore prior buffer, prior options, metadata, view, focus, and child ownership.

`M.apply_window_options()` must be able to apply to a valid target before that window displays `instance.bufnr`; public callers still use the prepared transition path.

- [ ] **Step 5: Tighten `BufWinEnter` ownership**

`BufWinEnter` applies options only to the entered `winid` if it was not already prepared, then runs ongoing cursor constraint/visibility handling. Delete `window.apply_all(instance)` and its call sites.

Takeover continues to create a child before replacement, but `window.replace()` now guarantees target options and buffer syntax precede marked-buffer exposure.

- [ ] **Step 6: Run static verification and commit**

Run:

```sh
luac -p lua/fre/buffer.lua lua/fre/instance.lua lua/fre/window.lua lua/fre/takeover.lua
rg -n "install_syntax|navigation_marker|apply_all" lua/fre syntax
git diff --check
```

Expected: syntax/diff checks succeed; the obsolete Lua helpers have no matches.

Commit:

```sh
git add syntax/fre.vim lua/fre/buffer.lua lua/fre/instance.lua lua/fre/window.lua lua/fre/takeover.lua
git commit -m "fix: prepare conceal before first render"
```

---

### Task 6: Width-Generation Reprojection And Proven Dead-Code Removal

**Files:**
- Modify: `lua/fre/manager.lua`
- Modify: `lua/fre/instance.lua`
- Modify: `lua/fre/buffer.lua`
- Modify: `lua/fre/window.lua`

**Interfaces:**
- Consumes: Manager generation schedule from Task 1 and prepared `marker_generation` from Task 2.
- Produces: `Instance:_on_marker_width_changed(generation)` with modified/in-flight safety.

- [ ] **Step 1: Implement safe stale-generation handling**

`Instance:_on_marker_width_changed(generation)` returns without rendering when destroyed, creating/load-failed, modified, write-locked, refreshing, watch-refreshing, or executing. It records `_marker_width_stale = true` in every deferred case.

For a ready, unmodified, idle instance whose `view.marker_generation < generation`, call `_render_success()` under `pcall`. On success clear stale state. On failure retain stale state and report asynchronously.

Every successful normal projection stores the prepared marker generation and clears stale state when current. Successful write reconciliation and refresh naturally normalize deferred buffers.

- [ ] **Step 2: Ensure width-only projection does no filesystem I/O**

The callback may call only `_projection()` plus `buffer.project()`. It must not call `refresh()`, filesystem adapters, watcher scans, or mutation preparation.

- [ ] **Step 3: Split raw commit line mutation from standalone status-line mutation**

Add an internal raw setter used only while buffer commit already owns all-window snapshots. Keep view-preserving behavior for loading/error standalone lines. This removes the nested `winsaveview()/winrestview()` cycle inside `buffer.commit()` without changing loading/error behavior.

- [ ] **Step 4: Remove only proven redundant branches**

Remove:

- `current_modifiable`'s duplicate final assignment in `buffer.restore()`;
- the identical second `set_split_fixed()` retry after the first `pcall` fails;
- stale separate navigation highlight-template state;
- current-width raw marker equality paths replaced by semantic identity.

Do not remove candidate Tree rollback or buffer snapshots unless the remaining single owner can restore both old Tree node extmarks and buffer text atomically.

- [ ] **Step 5: Run static verification and commit**

Run:

```sh
luac -p lua/fre/manager.lua lua/fre/instance.lua lua/fre/buffer.lua lua/fre/window.lua
git diff --check
```

Expected: no output.

Commit:

```sh
git add lua/fre/manager.lua lua/fre/instance.lua lua/fre/buffer.lua lua/fre/window.lua
git commit -m "refactor: reproject dynamic marker widths"
```

---

### Task 7: Documentation, Manual Reproduction, And Final Review

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-24-fre-buffer-file-manager-design.md`
- Modify: `docs/superpowers/specs/2026-07-27-navigation-size-cursor-design.md`
- Modify: `docs/superpowers/specs/2026-07-27-oil-render-protocol-redesign.md`

**Interfaces:**
- Documents the final protocol and removes superseded public/internal descriptions.

- [ ] **Step 1: Synchronize documentation**

Document:

- unified `fre:<instance>:<node>` decimal marker and node-zero navigation;
- initial width 3 and monotonic dynamic growth;
- identity as an internal layout field rather than a configurable column;
- two-pass custom dynamic-column alignment with left/center/right;
- initial path cursor versus ongoing metadata traversal;
- write-time read-only metadata validation;
- source-Manager parent navigation and root no-op;
- formal syntax/first-paint ordering.

Mark the redesign spec `Implemented` only after source work and review complete. In the older navigation spec, replace conflicting sections with a short superseded reference instead of keeping two active contracts.

- [ ] **Step 2: Run complete static verification**

Run:

```sh
luac -p lua/fre/*.lua lua/fre/mutation/*.lua
git diff --check
rg -n "fre-nav|navigation_marker|encode_base36|decode_base36|clamp_cursor|apply_all|install_syntax" lua/fre syntax README.md docs/superpowers/specs
```

Expected: Lua/diff checks produce no output. The final `rg` may find only historical/superseded explanatory text; it must find no active production symbol or current-contract claim.

- [ ] **Step 3: Perform manual Neovim reproductions without the automated test suite**

Use the current working tree in a real Neovim session and verify these exact interactions:

1. `nvim .` shows no literal `fre:` text on first ready display.
2. Initial cursor is at the `../` or `/` path start.
3. From `../` path start, `j` lands on the next row's path start.
4. Moving left can enter permissions/size/mtime but not icon or identity.
5. Editing a read-only metadata token is allowed as draft text and `:write` reports the row/column metadata error.
6. `<CR>` on `../` opens the lexical parent; `<CR>` on `/` is a no-op.
7. A custom dynamic-width column aligns left, center, and right according to its descriptor while initial cursor remains at path.
8. With the cursor on a metadata content character, adding/removing a wider row grows/shrinks the projection column without moving the cursor into padding or onto another content character.
9. Creating enough IDs to grow a field width changes clean projections uniformly; a modified buffer retains its old marker bytes until its next successful write/refresh.
10. Leaving Fre for a normal file restores prior window-local options.

Record exact failures before changing code; do not layer additional fixes without tracing them back to the responsible task boundary.

- [ ] **Step 4: Request independent read-only review**

Review the complete branch diff against `docs/superpowers/specs/2026-07-27-oil-render-protocol-redesign.md` with separate lenses for:

- serializer/parser and dynamic-width correctness;
- Neovim first-paint/window/cursor lifecycle;
- action/Manager behavior and code removal/maintainability.

Resolve every material finding through one writer and rerun the static/manual checks affected by that finding.

- [ ] **Step 5: Commit documentation and verified cleanup**

```sh
git add README.md docs/superpowers/specs/2026-07-24-fre-buffer-file-manager-design.md docs/superpowers/specs/2026-07-27-navigation-size-cursor-design.md docs/superpowers/specs/2026-07-27-oil-render-protocol-redesign.md
git commit -m "docs: describe unified render protocol"
```

Then verify `git status --short` contains only the pre-existing excluded artifact directories/files.
