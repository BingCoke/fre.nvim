# fre.nvim Navigation Row, Size Column, and Cursor Design

- Status: Approved for implementation
- Date: 2026-07-27
- Project: `fre.nvim`
- Reference implementation studied: `../oil.nvim` at `b73018b75affd13fa38e2fc94ef753b465f770d7`

## 1. Relationship to the Main Design

This document amends `2026-07-24-fre-buffer-file-manager-design.md` for four related behaviors:

1. The concealed row identity must not become visible when an instance is first displayed.
2. Every ready directory view must have a synthetic navigation row.
3. A built-in `size` column must be enabled by default.
4. The cursor must remain in the editable path field rather than metadata columns.

Where this document conflicts with the main design's default column list, select-action entry requirement, or normal/Visual cursor rules, this document takes precedence. All unrelated contracts remain unchanged.

## 2. Root Causes

The existing physical row is:

```text
<concealed real-entry marker><configured metadata columns><editable path>
```

A fresh window initially places its cursor at byte column zero. Neither opening the window nor the first asynchronous render moves it to the decoded path range. Cursor correction currently happens only after later movement or insert events, and normal mode clamps to the first visible metadata column rather than the path. This leaves the concealed identity exposed during the initial display path and makes cursor behavior depend on editor events after rendering.

The tree projection starts at the root node's children. It has no synthetic parent entry, so no current code path can render `../`.

`lstat` already supplies `stat.size`, but the column metadata whitelist, node snapshot, column context, and built-in descriptor set do not expose it.

## 3. Goals

The implementation must provide:

- One synthetic navigation row at the top of every successful projection.
- `../` when the instance has a lexical parent and `/` when it is already at a filesystem root.
- Platform-correct internal parent/root paths while using `/` as the cross-platform root display label.
- Parent navigation through the existing instance and window model.
- An Oil-compatible, right-aligned size column enabled in the default layout.
- Initial and ongoing cursor placement within the decoded path range.
- No filesystem mutation semantics for synthetic navigation rows.
- Focused regression coverage for ready, asynchronous, refresh, write, and multi-window behavior.

## 4. Non-goals

This change will not add:

- Recursive directory-size calculation.
- Target-following symlink size.
- Size-based sorting or a size field on the public `Entry` table.
- A reorderable or optional path descriptor; path remains the fixed terminal field.
- A drive or mount selector at a filesystem root.
- Oil's adapter, URL, cache, or parser architecture.
- Per-line Neovim edit protection. A user can temporarily alter physical navigation-row bytes, but valid synthetic rows have no filesystem meaning and canonical rendering restores them.

## 5. Synthetic Navigation Row

### 5.1 Model boundary

`Tree` continues to contain only real filesystem nodes. Its root remains a real directory node without a rendered real-entry row.

After real-node projection and sorting, the instance render boundary prepends one synthetic navigation item. The item is outside sibling sorting, `nodes_by_id`, `nodes_by_path`, projected deletion baselines, real-node extmark ownership, and watcher state.

The row is always first:

- If the normalized instance root has a lexical parent, its navigation kind is `parent` and its displayed path is `../`.
- If the normalized instance root has no lexical parent, its navigation kind is `root` and its displayed path is `/`.

Root detection and parent calculation use the path module's platform-aware normalized path semantics. The display label never determines a filesystem path. A POSIX root, Windows drive root, and UNC share root all display `/`, while their internal instance roots retain their real normalized forms.

Examples:

```text
instance.root = "/"                 -> navigation display "/"
instance.root = "/project"          -> navigation display "../"
instance.root = "C:/"               -> navigation display "/"
instance.root = "C:/project"        -> navigation display "../"
instance.root = "//server/share"    -> navigation display "/"
```

### 5.2 Dedicated marker namespace

The existing real-entry marker accepts only positive instance and node IDs and resolves every node ID through a live tree. No numeric node ID, including zero, can safely represent a synthetic row.

Navigation rows therefore use a distinct concealed marker:

```text
\31fre-nav:<base36-instance-id>:parent\31
\31fre-nav:<base36-instance-id>:root\31
```

The parser validates the namespace, canonical lowercase base36 instance ID, exact navigation kind, closing separator, and live source instance. The conceal rule covers both the existing `fre` marker and the new `fre-nav` marker.

A decoded navigation row has an explicit identity separate from `Entry`:

```lua
{
  row_kind = "navigation",
  navigation_kind = "parent", -- or "root"
  synthetic = true,
  source_instance_id = instance.id,
  entry = nil,
  column_ranges = { ... },
  path_range = { start_byte = ..., end_byte = ... },
}
```

`instance:get_entry(row)` continues to return only real Entries and returns `nil` for a valid navigation row. No fake node ID or public Entry is introduced.

A navigation marker copied from another instance is never actionable in the destination instance. An unknown, destroyed, malformed, or truncated navigation marker follows the existing row-specific reserved-marker error policy.

### 5.3 Columns and path

Navigation rows use the same configured column order, projection-wide display widths, one-space separators, and terminal path field as real rows.

Column callbacks receive a callback-only directory Entry plus navigation context. Its positive `instance_id` and `node_id` come from the source root, while `name`/`relative_path` are `..` or `/` and `absolute_path` is the lexical navigation target. This keeps existing custom columns that render Entry path/name fields valid without turning the row into a public Entry:

```lua
ctx.synthetic = true
ctx.navigation_kind = "parent" -- or "root"
ctx.metadata = {
  kind = "directory",
  mode = nil,
  size = nil,
  mtime = nil,
}
```

The callback-only Entry preserves the existing positive-ID shape while allowing callbacks to identify the synthetic row. It is never returned by `instance:get_entry()` or actions. Built-in behavior is:

- `icon`: render the configured directory icon.
- `permissions`: render `-` when mode is unavailable.
- `size`: render `-` when size is unavailable.
- `mtime`: render `-` when modification time is unavailable.

Custom descriptors retain their normal render, parse, and equals contract and can branch on `ctx.synthetic`. A callback failure remains a normal column-render or row-parse error.

The path remains a mandatory, special terminal field. It is not added to `config.columns` and cannot be reordered ahead of metadata.

## 6. Navigation Actions

The mapping context exposes the decoded row kind without treating navigation as an Entry:

```lua
ctx.row_kind = "entry" | "new" | "navigation"
ctx.navigation_kind = nil | "parent" | "root"
ctx.source_instance_id = instance_id_or_nil
ctx.entry = entry_or_nil
```

For a local `parent` row:

- `actions.select` calculates the normalized lexical parent of `ctx.instance.root`.
- It creates a new instance with that parent root and `inherit = ctx.instance`, using the same override validation as ordinary directory selection.
- It replaces the resolved target window with the new instance buffer.
- `tab_select` and `split_select` retain their existing destination strategies while using the same parent-instance construction.

For a `root` row, select actions return without changing a window or creating an instance.

Actions requiring a real Entry, including expand, collapse, toggle-expand, and reveal, return without changing state when invoked on a navigation row. Ordinary real-entry behavior is unchanged.

## 7. Mutation Semantics

Navigation rows never enter the projected real-node baseline. Mutation preparation recognizes a valid navigation identity before create, occurrence, move, copy, or delete classification and excludes that row.

Consequences:

- A retained valid navigation marker cannot create, rename, move, copy, or delete a filesystem entry.
- Duplicate valid navigation rows produced by linewise yank/paste are ignored by preparation.
- Deleting the complete navigation row does not imply deletion because it has no baseline identity.
- Successful write reconciliation or refresh emits exactly one canonical navigation row at row one.
- Damaging a reserved marker remains an error.
- Completely removing a marker while retaining or replacing ordinary unmarked text follows the existing unmarked-row contract; Fre does not guess that arbitrary markerless text was formerly navigation.

This preserves the existing physical-marker editing rules without adding per-line edit interception.

## 8. Size Column

### 8.1 Descriptor

`columns.size(opts?)` is a built-in read-only descriptor with:

```lua
id = "size"
align = "right"
metadata = { "size" }
```

`size` is added to the supported metadata whitelist. Tree create, clone, reconciliation, candidate snapshot, and rollback state retain the numeric `lstat.size`, and the instance column context exposes it as `ctx.metadata.size`. Public Entry tables remain unchanged.

The descriptor uses the existing deterministic render/parse/equals protocol. Parsing accepts only the descriptor's canonical displayed token and separator grammar. Equality compares parsed text with the current canonical rendering of the source snapshot size.

### 8.2 Oil-compatible formatting

Formatting uses decimal units, matching Oil's local-files adapter:

- Missing size: `-`
- `0` through `999`: integer decimal bytes with no suffix
- `1000` through `999999`: one decimal digit plus `k`
- `1000000` through `999999999`: one decimal digit plus `M`
- `1000000000` and above: one decimal digit plus `G`

Examples:

```text
0          -> 0
999        -> 999
1000       -> 1.0k
1250       -> 1.2k
1000000    -> 1.0M
1000000000 -> 1.0G
```

Real files, directories, and symlinks all display their existing `lstat.size`. Directory sizes are filesystem metadata, not recursive totals. Symlink sizes describe the link object, not its target.

### 8.3 Default order

The exact built-in default becomes:

```lua
columns = {
  columns.icon(),
  columns.permissions(),
  columns.size(),
  columns.mtime({ format = "%Y-%m-%d %H:%M" }),
}
```

The visible path follows these descriptors as the fixed final field:

```text
icon -> permissions -> size -> mtime -> path
```

## 9. Cursor Contract

### 9.1 Path-only invariant

For every decodable existing or synthetic row, all editor modes constrain the cursor byte column to the row's retained path range:

```text
path_range.start_byte <= cursor_col <= path_range.end_byte
```

The lower bound prevents entry into concealed identity or read-only metadata. The upper bound handles virtual-edit or stale columns beyond the retained path. New unmarked rows have no generated prefix and remain editable from column zero.

This rule supersedes the main design's allowance for Normal and Visual mode to enter visible metadata columns. Metadata remains ordinary yankable buffer text through explicit ranges or raw APIs, but the cursor cannot be positioned inside it during normal interaction.

### 9.2 Initial successful render

A fresh instance can be opened before or after asynchronous loading completes.

- If the new target window has no established Fre row/view target, the first successful projection places it on row one at that navigation row's `path_range.start_byte`.
- If an explicit reveal or previously established view target exists, Fre preserves its row decision and clamps only the final column to that row's path range.
- Loading and load-failed placeholder rows have no identity/path protocol and do not trigger path positioning.
- Cursor placement happens only after a successful commit has installed canonical rows and decoded ranges.

Window options and conceal syntax are installed before the committed rows become the ready view. The buffer-local syntax rules are reinstalled on `Syntax` and `BufWinEnter`, because startup syntax initialization can otherwise clear rules installed during synchronous `nvim .` takeover. The post-commit path placement therefore removes the first-display identity exposure rather than relying on a later `CursorMoved` event.

### 9.3 Ongoing enforcement

The shared path-clamp helper is used by:

- `CursorMoved`
- `CursorMovedI`
- `InsertEnter`
- `InsertCharPre`
- successful window open or replacement
- successful render, refresh, reconciliation, and rollback view restoration

The helper changes only the byte column unless the existing row is outside the new line-count bounds. It uses decoded ranges and never recomputes a column offset from configured widths or searches for path text.

### 9.4 Multiple windows

Initial opening positions only the newly opened target window, matching Oil's user-visible behavior.

A later commit already captures and restores every valid window displaying the buffer, including windows in other tabs. After each window's row and topline are restored, Fre clamps that window's column against the newly decoded path range for its resolved row. Each window keeps its independent row and view; no refresh moves every window to row one.

This is not a new multi-window subsystem. It extends the existing all-window restoration loop so dynamic width changes, including size-width changes, cannot leave an inactive view's cursor inside metadata.

## 10. Failure and Atomicity Rules

- Initial-load failure does not attempt navigation-row or cursor placement.
- A failed refresh preserves the old text, navigation row, widths, cursor rows, columns, and views.
- A failed commit or rollback follows existing atomic snapshot behavior.
- Size formatter, descriptor, custom column, or navigation marker errors surface through existing direct row/render errors.
- No failure path changes the Tree or baseline to include the synthetic row.
- A root-row selection is a deliberate no-op, not an error notification.

## 11. Test Strategy

Implementation follows red-green-refactor. Each behavior receives a failing regression test before production code changes.

### 11.1 Navigation protocol and projection

Tests assert:

- A non-root instance renders exactly one `../` navigation row before sorted real children.
- A filesystem root renders exactly one `/` navigation row.
- Windows drive and UNC roots use `/` as display only while retaining platform-correct internal roots.
- Navigation identity uses the dedicated namespace and never appears in Tree indexes or the projected deletion baseline.
- Canonical local, copied foreign, malformed, and destroyed-source navigation markers have the specified decode/action behavior.
- Refresh restores one canonical first row after valid navigation-row deletion or duplication.

### 11.2 Actions and writes

Tests assert:

- Selecting `../` creates an inherited parent-root instance and replaces the current target window.
- Tab and split selection retain their existing destination behavior.
- Selecting `/` is a no-op.
- Entry-only actions are no-ops on navigation rows.
- Canonical and duplicate valid navigation markers produce no create, copy, move, or delete operations.
- Existing real-row mutation and cross-instance copy behavior is unchanged apart from row offsets and the added default column.

### 11.3 Size

Tests cover:

- Descriptor ID, metadata requirement, right alignment, parsing, equality, and option validation.
- `0`, `999`, `1000`, representative `k`, `M`, and `G` values.
- Real file, directory, and symlink `lstat.size` values.
- Missing synthetic metadata rendering as `-`.
- Projection-wide right-aligned widths and exact path byte ranges.
- The exact default column order.

### 11.4 Cursor and conceal

Tests cover:

- Opening an already-ready hidden instance positions the new window at row one and the decoded path start without displaying marker text.
- Opening while the filesystem adapter is deferred positions the cursor only after the first successful commit.
- Normal, Visual, and Insert mode movement cannot enter identity or metadata columns.
- New unmarked rows remain editable from column zero.
- Refresh with changed size width preserves each window's row and topline while recalculating its path-clamped column.
- Same-buffer windows in splits and other tabs retain independent views.
- Failed initial load and failed refresh preserve their previous cursor/view contract.

### 11.5 Commands

Focused verification uses:

```sh
sh scripts/test.sh tests/columns_spec.lua
sh scripts/test.sh tests/instance_spec.lua
sh scripts/test.sh tests/actions_mappings_spec.lua
sh scripts/test.sh tests/metadata_buffer_spec.lua
sh scripts/test.sh tests/prepare_spec.lua
sh scripts/test.sh tests/window_layout_spec.lua
sh scripts/test.sh tests/atomic_refresh_spec.lua
sh scripts/test.sh tests/cross_instance_copy_spec.lua
```

Final verification uses:

```sh
sh scripts/test.sh
```

## 12. Documentation

README documentation must describe:

- The always-present first navigation row.
- `../` parent navigation and cross-platform `/` root labeling.
- The default `size` column, decimal unit formatting, and directory/symlink semantics.
- The exact default column order.
- Metadata columns as read-only text and path as the fixed terminal editable field.
- Path-only cursor behavior.

## 13. Acceptance Criteria

The change is complete when:

1. A fresh successful instance display never exposes its physical identity marker under the built-in window options.
2. Every successful ready projection starts with exactly one canonical navigation row: `../` below a filesystem root and `/` at a filesystem root.
3. Parent selection opens a new inherited parent instance in the requested destination, while root selection changes nothing.
4. Navigation rows never become Tree nodes, baseline IDs, or filesystem mutation operations.
5. The built-in size descriptor renders Oil-compatible decimal values from `lstat.size`, is right-aligned, and is enabled between permissions and mtime by default.
6. Path remains the fixed final field and the cursor cannot enter identity or metadata in any editor mode.
7. First render, reopen, refresh, rollback, and same-buffer multi-window restoration all use decoded path ranges rather than width arithmetic or text search.
8. Focused tests and the complete test suite pass without weakening existing real-entry, mutation, atomicity, or window-layout behavior.
