# Fre Oil-Style Render Protocol Redesign

- Status: Draft for user review
- Date: 2026-07-27
- Project: `fre.nvim`
- Supersedes: cursor, marker, navigation-row, and first-render sections of `2026-07-27-navigation-size-cursor-design.md`
- Reference: `../oil.nvim` at `b73018b75affd13fa38e2fc94ef753b465f770d7`

## 1. Problem Statement

The current renderer has four coupled defects:

1. Selecting the synthetic `../` row reaches `entry_from()` and raises `fre: action requires an entry`.
2. Navigation and real rows serialize different-length concealed marker prefixes. Neovim vertical motions preserve physical columns, so moving from `fre-nav:...` to `fre:...` can place the cursor in the middle of the next path.
3. The cursor is continuously restricted to the path range, which prevents Oil-style traversal of visible metadata columns.
4. Directory takeover creates a hidden Fre buffer and later swaps it into a window. Marker text, syntax conceal, and window options are installed through separate lifecycle paths, so `nvim .` can paint a marked row before conceal is effective.

The accumulated `Syntax`, `BufWinEnter`, cursor-clamp, and navigation-specific branches do not establish one render protocol. This redesign replaces those branches with a paired serializer/parser, a unified navigation identity, one cursor policy, and an explicit first-paint sequence.

## 2. Goals

The redesign must provide:

- One serialized row grammar for real entries and navigation.
- Dynamic Oil-style identity widths, beginning at three decimal digits and growing when IDs grow.
- Equal marker widths for every canonical row produced by one render.
- A synthetic navigation sentinel that never enters Tree or filesystem mutations.
- One two-pass layout engine for identity, built-in columns, custom dynamic-width columns, and path.
- Initial cursor placement at the path start.
- Normal and Visual cursor access to visible metadata columns after initial placement.
- Write-time rejection of changes to read-only metadata.
- No visible marker during first `nvim .` presentation under the built-in configuration.
- Preservation of marker-based same-instance duplication and cross-instance yank/paste identity.
- Removal of superseded marker, conceal, cursor, and restoration paths.

## 3. Non-goals

This work will not:

- Move row identity exclusively to extmarks.
- Move metadata columns to virtual text.
- Add filesystem mutations for metadata columns.
- Add a general motion remapping layer for `j`, `k`, search, mouse, or plugins.
- Change Tree ownership, sorting, expansion, watcher, or mutation operation semantics.
- Overwrite modified buffers merely to update marker padding.
- Add or run tests while the existing user constraint against test work remains in effect.

## 4. Reference Behavior From Oil

Oil serializes identity and columns as ordinary buffer text. A syntax file conceals the identity prefix. The parser reconstructs ranges from the physical line, and authoritative validation occurs when the buffer is written.

Oil synthesizes parent navigation with reserved ID zero and sends it through the ordinary row formatter. Initial placement targets the name field, while the ongoing cursor constraint is only a lower bound. Visible columns remain ordinary traversable text. This separation is the model Fre will adopt.

Fre retains its root-relative tree projection and instance-local Node/Entry model. It does not copy Oil's adapter, cache, URL, or mutation architecture.

## 5. Unified Identity Protocol

### 5.1 Row grammar

Every marked row starts with the same namespace and two decimal identity fields:

```text
US fre:<padded-instance-id>:<padded-node-id> US <columns><path>
```

`US` is byte `0x1f`. The separators make the reserved prefix unambiguous even when the visible path contains spaces or punctuation.

Examples at initial width:

```text
US fre:002:000 US ... ../
US fre:002:017 US ... src/
```

The separate `fre-nav` namespace is removed.

### 5.2 Dynamic widths

The Manager owns monotonic render widths:

```lua
marker_widths = {
  instance = 3,
  node = 3,
  generation = 1,
}
```

When an instance or node ID is allocated, its decimal digit count is compared with the corresponding width. A larger count grows that width and increments `generation`. Widths never shrink during the Neovim process.

Therefore:

- IDs `0` through `999` render with width 3.
- ID `1000` grows that field to width 4.
- ID `10000` grows that field to width 5.
- There is no fixed display-width ceiling.

A render captures one width snapshot before formatting any row. Every canonical row emitted by that render has the same marker length, so all physical column starts align.

### 5.3 Historical widths

A width increase does not invalidate already rendered or modified buffers.

The decoder accepts a canonical historical field when:

- it contains decimal digits only;
- its decoded value is a non-negative integer;
- its width is at least 3 and no greater than the Manager's current width for that field;
- any extra width consists only of required leading zeroes;
- the unpadded decimal value matches the decoded integer exactly.

Width growth is coalesced by generation rather than repainting after each allocation. At the end of the active load/reconcile allocation batch, the Manager schedules a tree-to-buffer reproject for every ready, unmodified live instance whose view generation is stale. Creating instances use the latest snapshot for their first render. Modified instances retain their current bytes and undo history. Their next successful write, reconciliation, or refresh emits the current width.

A width-only reproject uses the current in-memory Tree and does not perform filesystem I/O. Marker lookup must compare decoded identity, not construct a current-width string and assume old rows have that exact prefix.

### 5.4 Identity domains

Instance IDs remain positive. Real node IDs remain positive. Node ID zero is reserved and is never inserted into `nodes_by_id`.

The serialized instance ID preserves the source instance for cross-instance real-entry paste. A foreign navigation sentinel is display-only and non-actionable in the destination instance.

## 6. Navigation Sentinel

The first row remains outside Tree, baseline, filesystem snapshots, watcher state, and real-node extmarks.

Its identity is the current instance ID plus node ID zero. Its semantic kind is derived from the source instance root:

- a lexical parent exists: `navigation_kind = "parent"`, visible path `../`;
- no lexical parent exists: `navigation_kind = "root"`, visible path `/`.

Decoded navigation retains an explicit non-Entry result:

```lua
{
  row_kind = "navigation",
  navigation_kind = "parent" or "root",
  source_instance_id = id,
  node_id = 0,
  entry = nil,
  fields = { ... },
  path_range = { ... },
}
```

It is excluded before mutation occurrence/create/delete classification. Duplicate valid navigation rows remain mutation no-ops. Unknown, destroyed, malformed, or noncanonical source identities remain row errors.

## 7. Paired Renderer And Parser

### 7.1 Renderer

One row formatter receives a semantic row record:

```lua
{
  source_instance = instance,
  node = node_or_nil,
  navigation_kind = kind_or_nil,
  entry = callback_entry,
  path = visible_path,
}
```

It formats the unified marker, every configured metadata descriptor, separators, and the terminal path. Navigation uses the same descriptor callbacks and projection-wide column widths as real entries.

The formatter returns both line bytes and decoration templates. It does not install window state, syntax, extmarks, or cursor positions.

### 7.2 Parser

One line parser performs these stages:

1. Parse and validate the unified marker.
2. Resolve the source instance.
3. Branch on node ID zero versus a real node ID.
4. Parse each descriptor and record exact byte ranges.
5. Parse the terminal path and record its range.
6. Return semantic row identity without invoking action policy.

Lightweight callers may tolerate parse errors when only decoration or cursor recovery is being attempted. Mutation preparation and actions retain direct row errors.

### 7.3 Layout fields

Identity participates in row layout as the first internal structural field, matching Oil's `cols[1]` treatment. It is not a public descriptor, cannot be reordered, and is concealed. Its width comes from the Manager marker-width snapshot rather than user configuration.

Configured descriptors follow identity in user-specified order. Path is the final unbounded field and is not part of `config.columns`.

Layout is explicitly two-pass:

1. Render every semantic row into unpadded field chunks. Measure each configured descriptor with `nvim_strwidth()` and retain its maximum display width for this projection. Identity width comes from the render snapshot.
2. Align every chunk to its field width, join fields with one-space separators, and derive byte ranges and highlight offsets from the resulting physical line.

A custom descriptor may return different text lengths for every row. It does not declare or guess a fixed width. Its existing `align = "left" | "center" | "right"` option controls projection-wide padding; `fre.columns.custom()` continues to default to left alignment. Alignment is implemented entirely by the field layout boundary, so descriptors do not change their render/parser signatures. Wide UTF-8 text is measured in display cells while parser and Neovim API ranges remain byte offsets.

Renderer callbacks run exactly once per row per render. Validation, width calculation, line assembly, and highlight templates consume the retained result instead of invoking a callback again with potentially different output.

### 7.4 Parser and dynamic columns

Configured descriptor parsers remain streaming parsers, as in Oil: each parser consumes its own aligned prefix and separator and returns the literal remaining suffix. Core validation checks progress and literal-suffix preservation. This keeps custom dynamic-width formats possible without making view width state the sole source of truth for edited or foreign rows.

The parser records each descriptor ID, parsed value, byte range, separator range, alignment, and render width in the decoded row. A descriptor callback receives its existing context plus the captured projection width when the source view can supply it. Historical and foreign rows remain parseable from their own bytes even if a later projection uses wider fields.

### 7.5 Metadata and cursor capability

Metadata columns remain real, visible, yankable text. Built-in `permissions`, `size`, and `mtime` remain read-only in filesystem semantics. Temporary buffer edits are allowed. Their descriptor parser/equality contract rejects invalid or changed read-only values at write preparation.

Descriptor navigation is a prefix capability, matching Oil's lower-bound model rather than per-span cursor policing. The built-in icon is a leading non-navigable decorative field. Other built-in descriptors and custom descriptors are navigable by default. A custom descriptor may mark itself non-navigable when it belongs to a leading decorative prefix; the first navigable descriptor establishes the ongoing lower cursor bound. Path is always navigable.

This capability never determines initial placement. First display still anchors at path start.

## 8. Cursor Model

### 8.1 Initial placement

Initial placement is distinct from ongoing constraints.

The path start is used when:

- a new instance is first successfully rendered in its target window;
- a ready hidden instance is first opened without an established view target;
- navigation creates and displays a parent instance;
- reveal explicitly selects an entry;
- a placeholder loading/error row becomes the first canonical projection.

Metadata visibility does not change this initial anchor.

### 8.2 Ongoing constraint

After initial placement, Normal and Visual mode may traverse visible metadata columns. The cursor lower bound is the first navigable visible column, not the path start. The icon and concealed identity remain outside the allowed range.

Insert mode uses the same physical buffer text and the same lower prefix boundary on entry and movement. Fre does not police individual metadata spans or jump the cursor back to the path. Read-only metadata changes are rejected at write.

New unmarked rows remain editable from column zero.

### 8.3 Vertical motion

Fre does not remap `j` or `k`. A canonical render gives every row the same marker width and every configured metadata column the same projection width. Neovim's preserved physical column therefore corresponds to the same visible field.

From the path start of `../`, pressing `j` lands at the path start of the next canonical row. This is achieved by row serialization, not a `CursorMoved` snap that would make metadata inaccessible.

### 8.4 Commit restoration

Window restoration records semantic field identity and offset when a row is decodable:

- metadata descriptor ID plus byte/cell offset; or
- path plus byte/cell offset.

After a render changes marker or column widths, restoration maps that semantic position into the new ranges. If the previous position cannot be represented, it clamps to the nearest valid position. Initial windows still use the path start.

This replaces raw saved-byte restoration followed by a path-only clamp.

## 9. First-Paint Lifecycle

### 9.1 Syntax ownership

A real `syntax/fre.vim` file owns marker conceal, following Oil's filetype syntax model. The marker pattern covers the unified protocol. Buffer setup establishes `filetype=fre` and the matching syntax identity before canonical marked rows can be displayed.

The old setup-time `syntax match`, `Syntax` reinstall, and unconditional `BufWinEnter` syntax-clear/reinstall paths are removed once the filetype syntax path is authoritative.

### 9.2 Window ordering

Window replacement/open follows this order:

1. Snapshot destination buffer, view, and window-local options.
2. Apply Fre window-local options, including conceal, to the target window.
3. Install the Fre buffer whose filetype/syntax state is already prepared.
4. Commit or expose canonical marked rows.
5. Set the initial semantic cursor anchor.
6. Record Fre window ownership for later restoration.

Failure restores the destination snapshot and destroys only a child created by the failed action.

A ready hidden Fre buffer may already contain marked rows. Its filetype syntax exists before it is placed in a window, and target conceal options are applied before the buffer swap.

### 9.3 Directory takeover

`nvim .` uses the same ordering. The original directory buffer remains visible until the replacement Fre buffer has filetype/syntax state and the target window has Fre options. Marked rows are not intentionally exposed in an unprepared target window.

This fixes first paint at the transition boundary instead of reinstalling conceal after `BufWinEnter`.

## 10. Action And Manager Boundaries

Actions resolve row semantics before requiring an Entry:

```text
navigation parent -> create inherited parent instance
navigation root   -> no-op
real directory    -> create inherited child instance
real file/link    -> open normal buffer
new row           -> entry-required error where applicable
```

No Lua `a and nil or b` pseudo-ternary is permitted for optional navigation entries.

Instance creation belongs to the source instance's Manager. Public `fre.new()` delegates to the default Manager, while navigation and directory selection call the source Manager's creation path. Mapping context validates the expected mapped instance directly and does not rediscover it exclusively through `manager.default`.

This keeps adapters, GC groups, setup defaults, and identity-width generation in one Manager domain.

## 11. Transaction And Cleanup Boundaries

The refactor assigns one owner to each concern:

- Tree candidate code owns candidate tree state.
- Buffer commit owns text, decorations, row extmarks, view metadata, and semantic window restoration.
- Window code owns destination buffer/options/view transitions.
- Filetype syntax owns conceal rules.
- Mutation preparation owns authoritative write validation.

The implementation removes code made obsolete by these boundaries, including:

- the `fre-nav` marker encoder/decoder and highlight branch;
- separate identity/column formatting paths and repeated column render callbacks;
- path-only cursor clamping on every movement event;
- manual syntax clear/reinstall loops;
- all-window option application from one window's enter callback;
- exact current-width marker string assumptions;
- duplicate view restoration where a lower-level raw line setter can be used safely;
- navigation action branches that construct a nil Entry.

Removal of rollback code is allowed only after confirming which layer restores Tree ownership as well as buffer text.

## 12. Error Handling

- Malformed reserved markers remain direct row errors.
- Historical valid padding is accepted; invalid leading zeroes or widths are rejected.
- Navigation parent construction failures leave the source window and instance intact.
- Root navigation is a deliberate no-op.
- Read-only metadata changes fail during write preparation, not during ordinary cursor movement.
- Width growth never overwrites a modified buffer.
- Syntax or window transition failure prevents marked first presentation and restores the previous target state.

## 13. Verification Under Current Constraint

No tests will be added or run unless the user changes the existing constraint.

Implementation verification will use:

- `luac -p` for every changed Lua module;
- `git diff --check`;
- static review of serializer/parser inverse behavior;
- manual Neovim reproduction for `nvim .`, `../` select, first cursor placement, metadata traversal, `j`/`k`, width growth, refresh, and modified-buffer preservation;
- an independent read-only architectural review before completion.

Known existing tests may require migration from `fre-nav` and path-only cursor assumptions later.

## 14. Acceptance Criteria

1. Initial marker widths are three decimal digits and grow dynamically without a fixed ceiling.
2. One render emits equal-length markers for navigation and all real rows.
3. `../` selection enters the lexical parent without requiring an Entry.
4. `/` at a filesystem root remains a no-op.
5. From the `../` path start, `j` lands at the next row's path start.
6. First display places the cursor at path start, while later Normal/Visual movement can enter visible metadata except icon.
7. Metadata edits are allowed as draft text and rejected at write when read-only values change.
8. `nvim .` does not intentionally paint marker text before conceal under built-in settings.
9. Cross-instance real-entry paste continues to resolve source identity.
10. A custom column with row-dependent text length is projection-aligned according to its configured alignment, parses from its own bytes, and does not change the initial path cursor anchor.
11. Modified buffers survive identity-width growth unchanged and normalize on their next successful render boundary.
12. Superseded `fre-nav`, manual syntax reinstall, duplicate column rendering, and path-only cursor enforcement code is removed.
13. Static verification and manual reproductions complete without unresolved material review findings.
