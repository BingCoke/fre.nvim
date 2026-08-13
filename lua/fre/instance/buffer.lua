local columns = require("fre.columns")
local row = require("fre.instance.row")
local path = require("fre.path")
local window = require("fre.window")
local View = require("fre.instance.view")

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local Buffer = {}
local M = {}
Buffer.__index = M
setmetatable(M, { __index = Buffer })

local function marker_column_context(
    source, node, entry, descriptor, index, is_last, navigation_kind, draft
)
  local mtime = node.mtime
  if type(mtime) == "table" then
    mtime = { sec = tonumber(mtime.sec) or 0, nsec = tonumber(mtime.nsec) or 0 }
  else
    mtime = { sec = tonumber(mtime) or 0, nsec = 0 }
  end
  for enabled_index, enabled in ipairs(source.enabled_columns or {}) do
    if enabled.id == descriptor.id then
      index = enabled_index
      is_last = enabled_index == #source.enabled_columns
      break
    end
  end
  local context = {
    entry = entry, descriptor = descriptor, config = descriptor,
    column_index = index, is_last = is_last,
    instance = { id = source.id, bufnr = source.bufnr, root = source.root },
    metadata = {
      kind = node.kind, mode = tonumber(node.mode) or 0,
      size = node.stat and tonumber(node.stat.size) or nil, mtime = mtime,
    },
  }
  if draft then
    context.synthetic = true
    context.draft = true
    context.metadata = { kind = node.kind, mode = nil, size = nil, mtime = nil }
  elseif navigation_kind then
    context.synthetic = true
    context.navigation_kind = navigation_kind
    context.metadata = { kind = "directory", mode = nil, size = nil, mtime = nil }
  end
  return context
end

local function marker_tree_contract(tree)
  return {
    root_node = function() return tree:root_node() end,
    node_by_id = function(_, id) return tree:node_by_id(id) end,
    node_by_path = function(_, node_path) return tree:node_by_path(node_path) end,
    entry = function(_, node) return tree:entry(node) end,
  }
end

local function resolve_columns(configured, requested_hidden)
  configured = vim.deepcopy(configured or {})
  local enabled = {}
  for _, descriptor in ipairs(configured) do
    local value = descriptor.enable
    if type(value) == "function" then
      local ok, result = pcall(value)
      if not ok then
        fail(
          "enable predicate for column " .. descriptor.id
            .. " failed: " .. tostring(result), 3
        )
      end
      if type(result) ~= "boolean" then
        fail(
          "enable predicate for column " .. descriptor.id
            .. " must return a boolean", 3
        )
      end
      value = result
    end
    if value then enabled[#enabled + 1] = descriptor end
  end

  local requested = {}
  for _, id in ipairs(requested_hidden or {}) do requested[id] = true end
  local hidden, visible, visible_ids = {}, {}, {}
  for _, descriptor in ipairs(enabled) do
    if requested[descriptor.id] then
      hidden[#hidden + 1] = descriptor.id
    else
      visible[#visible + 1] = descriptor
      visible_ids[descriptor.id] = true
    end
  end
  return configured, enabled, hidden, visible, visible_ids
end

function Buffer.new(options)
  if type(options) ~= "table" then fail("buffer options are required", 2) end
  local configured, enabled, hidden, visible, visible_ids = resolve_columns(
    options.columns, options.hidden_columns
  )
  local self = setmetatable({
    id = options.id,
    root = options.root,
    bufnr = options.bufnr,
    configured_columns = configured,
    enabled_columns = enabled,
    hidden_columns = hidden,
    visible_columns = visible,
    visible_column_ids = visible_ids,
    tree = assert(options.tree),
    lifecycle = assert(options.lifecycle),
    _resolve_marker_source = options.resolve_marker_source,
    report_async_error = assert(options.report_async_error),
    view = { baseline = {} },
    hidden_file = options.hidden_file == true,
    row_extmarks = {},
    projection_ranges = {},
    pending_initial_cursor = {},
    render_cache = {},
  }, Buffer)
  self.marker_source = {
    id = self.id,
    root = self.root,
    bufnr = self.bufnr,
    visible_columns = self.visible_columns,
    enabled_columns = self.enabled_columns,
    tree = marker_tree_contract(self.tree),
    view = self.view,
    _column_context = marker_column_context,
  }
  return self
end

M.new = Buffer.new

function M.attach(buffer, view, sync, work, request_destroy)
  buffer.view_owner = assert(view)
  buffer.sync = assert(sync)
  buffer.work = assert(work)
  buffer.request_destroy = assert(request_destroy)
end


function Buffer:resolve_marker_source(instance_id)
  if instance_id == self.id then return self.marker_source end
  if type(self._resolve_marker_source) ~= "function" then return nil end
  return self._resolve_marker_source(instance_id)
end

function M:clear_initial_cursors()
  self.pending_initial_cursor = {}
end

function M:hidden_files()
  return self.hidden_file
end

function M:get_columns()
  return vim.deepcopy(self.configured_columns)
end

function M:get_hidden_columns()
  return vim.deepcopy(self.hidden_columns)
end

function M:is_column_visible(id)
  return self.visible_column_ids[id] == true
end

local function visibility_candidate(buffer, mode, ids)
  local enabled_ids = {}
  for _, descriptor in ipairs(buffer.enabled_columns) do
    enabled_ids[descriptor.id] = true
  end
  local targets = {}
  for _, id in ipairs(ids) do
    if enabled_ids[id] then targets[id] = true end
  end
  if next(targets) == nil then return nil end

  local hidden_ids = {}
  for _, id in ipairs(buffer.hidden_columns) do hidden_ids[id] = true end
  local hide = mode == "hide"
  if mode == "toggle" then
    hide = false
    for id in pairs(targets) do
      if not hidden_ids[id] then
        hide = true
        break
      end
    end
  end
  for id in pairs(targets) do hidden_ids[id] = hide or nil end

  local hidden, visible, visible_ids = {}, {}, {}
  for _, descriptor in ipairs(buffer.enabled_columns) do
    if hidden_ids[descriptor.id] then
      hidden[#hidden + 1] = descriptor.id
    else
      visible[#visible + 1] = descriptor
      visible_ids[descriptor.id] = true
    end
  end
  if #hidden == #buffer.hidden_columns then
    local equal = true
    for index, id in ipairs(hidden) do
      if buffer.hidden_columns[index] ~= id then
        equal = false
        break
      end
    end
    if equal then return nil end
  end
  return {
    hidden_columns = hidden,
    visible_columns = visible,
    visible_column_ids = visible_ids,
  }
end

function M:change_column_visibility(mode, ids)
  local candidate = visibility_candidate(self, mode, ids)
  if not candidate then return true end
  local prepared = self:prepare_projection(false, self.tree, {
    descriptors = candidate.visible_columns,
    render_cache = self.render_cache,
  })
  prepared.column_state = candidate
  if not self:commit(prepared) then fail("buffer projection commit failed", 2) end
  return true
end

function M:set_hidden_files(enabled)
  enabled = enabled == true
  if self.hidden_file == enabled then return true end
  local previous = self.hidden_file
  self.hidden_file = enabled
  local ok, result = pcall(self.render, self)
  if ok and result ~= false then return true end
  self.hidden_file = previous
  self:projection()
  if not ok then error(result, 0) end
  fail("buffer projection commit failed", 2)
end

function M:committed_entries()
  return {
    baseline = self.view.baseline or {},
    visible_nodes = self.view.visible_nodes or {},
  }
end

function M:position(node)
  if type(node) ~= "table" then node = self.tree:node_by_id(node) end
  if not node or not self.view.baseline or self.view.baseline[node.id] == nil then return nil end
  local hint = self:hint_row(node)
  if hint and self:row_matches_identity(hint, self.id, node.id) then
    local decoded = self:decode(hint)
    return { hint, decoded.path_range.start_byte }
  end
  local matches = self:find_identity_rows(self.id, node.id)
  if #matches == 0 then return nil end
  local row_number = matches[1]
  self:rebind(node, row_number)
  local decoded = self:decode(row_number)
  return { row_number, decoded.path_range.start_byte }
end

function M:_column_context(node, entry, descriptor, index, is_last, navigation_kind, draft)
  return marker_column_context(
    self, node, entry, descriptor, index, is_last, navigation_kind, draft
  )
end

function M:replace_lines(first, last, lines)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return false end
  local views = {}
  for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      views[winid] = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
    end
  end
  local was_modifiable = vim.bo[self.bufnr].modifiable
  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, first, last, false, lines)
  vim.bo[self.bufnr].modified = false
  vim.bo[self.bufnr].modifiable = was_modifiable
  for winid, saved in pairs(views) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == self.bufnr then
      pcall(vim.api.nvim_win_call, winid, vim.fn.winrestview, saved)
    end
  end
  return true
end

function M:set_lines(lines)
  return self:replace_lines(0, -1, lines)
end

function M:display_name(node)
  local relative = assert(path.relative(self.root, node.path))
  if node.kind == "directory" then return relative .. "/" end
  return relative
end

function M:projection(tree)
  tree = tree or self.tree
  return tree:project(function(node)
    return self.hidden_file or node.name:sub(1, 1) ~= "."
  end)
end

function M:prepare_projection(validate, tree, opts)
  tree = tree or self.tree
  opts = opts or {}
  opts.validate = validate == true
  opts.tree = tree
  local projection = self:projection(tree)
  return self:prepare(
    projection, function(node) return self:display_name(node) end, opts
  )
end

function M:render(tree)
  local projection = self:projection(tree)
  return self:project(projection, function(node) return self:display_name(node) end)
end


local row_namespace = vim.api.nvim_create_namespace("fre-row-identity")
local highlight_namespace = vim.api.nvim_create_namespace("fre-column-highlights")


local function get_line(buffer, row)
  if type(row) ~= "number" or row % 1 ~= 0 then fail("row must be a 1-based integer", 4) end
  if row < 1 or not vim.api.nvim_buf_is_valid(buffer.bufnr) then return nil end
  local count = vim.api.nvim_buf_line_count(buffer.bufnr)
  if row > count then return nil end
  return vim.api.nvim_buf_get_lines(buffer.bufnr, row - 1, row, false)[1]
end

local function extmark_state(buffer)
  return buffer.row_extmarks
end

local function set_node_extmark(buffer, node, row)
  local marks = extmark_state(buffer)
  local previous = marks[node.id]
  if previous then pcall(vim.api.nvim_buf_del_extmark, buffer.bufnr, row_namespace, previous) end
  marks[node.id] = vim.api.nvim_buf_set_extmark(buffer.bufnr, row_namespace, row - 1, 0, {
    right_gravity = true,
  })
end

function M.constrain_cursor(buffer, winid, tree)
  winid = winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= buffer.bufnr then return end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row_number = cursor[1]
  local ok, decoded = pcall(M.decode, buffer, row_number, {
    allow_empty_path = true,
    validate_metadata = false,
    tree = tree,
  })
  if not ok or not decoded or not decoded.marked then return end
  local lower = decoded.navigable_range.start_byte
  local upper = math.max(lower, decoded.path_range.end_byte)
  local col = math.max(lower, math.min(cursor[2], upper))
  if cursor[2] ~= col then vim.api.nvim_win_set_cursor(winid, { row_number, col }) end
end

function M.place_initial_cursor(buffer, winid)
  if not buffer.pending_initial_cursor then buffer.pending_initial_cursor = {} end
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= buffer.bufnr then
    if winid then buffer.pending_initial_cursor[winid] = nil end
    return false
  end
  local ok, decoded = pcall(M.decode, buffer, 1, {
    allow_empty_path = true,
    validate_metadata = false,
  })
  if ok and decoded and decoded.marked and decoded.synthetic
      and decoded.instance_id == buffer.id and decoded.node_id == 0 then
    vim.api.nvim_win_set_cursor(winid, { 1, decoded.path_range.start_byte })
    buffer.pending_initial_cursor[winid] = nil
    return true
  end
  buffer.pending_initial_cursor[winid] = true
  return false
end

function M.decode(buffer, row_number, opts)
  return row.decode(buffer, row_number, get_line(buffer, row_number), opts)
end

local function copy_render_cache(source)
  local copied = {}
  for node_id, fields in pairs(source or {}) do
    local copied_fields = {}
    for id, field in pairs(fields) do copied_fields[id] = field end
    copied[node_id] = copied_fields
  end
  return copied
end

function M.prepare(buffer, projection, render_path, opts)
  opts = opts or {}
  local tree = opts.tree or buffer.tree
  local descriptors = opts.descriptors or buffer.visible_columns
  local source_cache = opts.render_cache
  if source_cache == nil then
    source_cache = tree == buffer.tree and buffer.render_cache or {}
  end
  local candidate_cache = copy_render_cache(source_cache)
  local rendered, nodes = row.project_items(buffer, projection, render_path, tree)
  local widths = {}
  for index = 1, #descriptors do widths[index] = 0 end
  for _, item in ipairs(rendered) do
    local fields = {}
    local cached = candidate_cache[item.node_id] or {}
    candidate_cache[item.node_id] = cached
    for index, descriptor in ipairs(descriptors) do
      local field = cached[descriptor.id]
      if not field then
        local ctx = buffer:_column_context(
          item.node, item.callback_entry, descriptor, index, index == #descriptors,
          item.navigation_kind
        )
        local text, highlight, display_width = columns.render_text(
          descriptor, item.callback_entry, ctx
        )
        field = {
          text = text, highlight = highlight, display_width = display_width,
        }
        cached[descriptor.id] = field
      end
      fields[index] = field
      widths[index] = math.max(widths[index], field.display_width)
    end
    item.fields = fields
  end
  local prepared = row.prepare(buffer, projection, rendered, descriptors, widths, {
    validate = opts.validate, tree = tree, nodes = nodes,
  })
  prepared.render_cache = candidate_cache
  prepared.tree = tree
  return prepared
end

function M:insert_draft(opts)
  if type(opts) ~= "table" then fail("draft options are required", 3) end
  local after_row = opts.after_row
  local proposed_path = opts.proposed_path
  local winid = opts.winid
  if type(after_row) ~= "number" or after_row % 1 ~= 0 then
    fail("draft insertion row must be a 1-based integer", 3)
  end
  if type(proposed_path) ~= "string" then fail("draft path must be a string", 3) end
  if proposed_path:find("[\r\n]") then fail("draft path must be a single line", 3) end
  if not vim.api.nvim_buf_is_valid(self.bufnr) then fail("instance buffer is not valid", 3) end
  local line_count = vim.api.nvim_buf_line_count(self.bufnr)
  if after_row < 1 or after_row > line_count then fail("draft insertion row is out of range", 3) end
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
    fail("draft target window is not valid", 3)
  end

  local item = row.draft_item(self, proposed_path, opts.projection_kind)
  local descriptors = self.visible_columns
  local widths = self.view.column_widths or {}
  if #widths ~= #descriptors then fail("draft columns require a committed layout", 3) end
  local fields = {}
  for index, descriptor in ipairs(descriptors) do
    local ctx = self:_column_context(
      item.node, item.callback_entry, descriptor, index, index == #descriptors, nil, true
    )
    local text, highlight, display_width = columns.render_text(
      descriptor, item.callback_entry, ctx
    )
    if display_width > widths[index] then
      fail("draft column " .. descriptor.id .. " exceeds the committed width", 3)
    end
    fields[index] = {
      text = text, highlight = highlight, display_width = display_width,
    }
  end
  item.fields = fields
  local prepared = row.prepare(
    self, { nodes = {} }, { item }, descriptors, widths, {
      validate = true, tree = self.tree, nodes = {},
    }
  )
  local inserted_row = after_row + 1
  local was_modifiable = vim.bo[self.bufnr].modifiable
  local ok, err = pcall(function()
    vim.bo[self.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(self.bufnr, after_row, after_row, false, prepared.lines)
  end)
  local restore_ok, restore_err = pcall(function()
    vim.bo[self.bufnr].modifiable = was_modifiable
  end)
  if not ok then error(err, 0) end
  if not restore_ok then error(restore_err, 0) end

  for _, highlight in ipairs(prepared.highlights or {}) do
    vim.api.nvim_buf_set_extmark(
      self.bufnr, highlight_namespace, after_row + highlight.row, highlight.start_col, {
        end_col = highlight.end_col,
        hl_group = highlight.hl_group,
        priority = 100,
        undo_restore = false,
      }
    )
  end
  local decoded = self:decode(inserted_row)
  local cursor_col = math.max(decoded.path_range.start_byte, decoded.path_range.end_byte - 1)
  vim.api.nvim_win_set_cursor(winid, { inserted_row, cursor_col })
  return { row = inserted_row, col = cursor_col }
end

local function descriptor_depends_on(descriptor, changed)
  if not descriptor._metadata_declared then return next(changed) ~= nil end
  for _, field in ipairs(descriptor.metadata or {}) do
    if changed[field] then return true end
  end
  return false
end

function M.prepare_watch_projection(buffer, tree, change)
  local candidate_cache = copy_render_cache(buffer.render_cache)
  for node_id in pairs(change.created or {}) do candidate_cache[node_id] = nil end
  for node_id in pairs(change.deleted or {}) do candidate_cache[node_id] = nil end
  for node_id, changed in pairs(change.metadata or {}) do
    local cached = candidate_cache[node_id]
    if cached then
      for _, descriptor in ipairs(buffer.enabled_columns) do
        if descriptor_depends_on(descriptor, changed) then
          cached[descriptor.id] = nil
        end
      end
    end
  end
  return buffer:prepare_projection(false, tree, { render_cache = candidate_cache })
end

function M.row_matches_identity(buffer, row_number, instance_id, node_id)
  local line = get_line(buffer, row_number)
  return line ~= nil and row.matches_identity(buffer, line, instance_id, node_id)
end

function M.find_identity_rows(buffer, instance_id, node_id)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) then return {} end
  local result = {}
  local lines = vim.api.nvim_buf_get_lines(buffer.bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    if row.matches_identity(buffer, line, instance_id, node_id) then
      result[#result + 1] = index
    end
  end
  return result
end

function M.rebind(buffer, node, row) set_node_extmark(buffer, node, row) end

function M.hint_row(buffer, node)
  local mark = extmark_state(buffer)[node.id]
  if not mark or not vim.api.nvim_buf_is_valid(buffer.bufnr) then return nil end
  local position = vim.api.nvim_buf_get_extmark_by_id(buffer.bufnr, row_namespace, mark, {})
  if #position == 0 then return nil end
  return position[1] + 1
end

local function same_widths(left, right)
  if not left or not right or #left ~= #right then return false end
  for index = 1, #left do
    if left[index] ~= right[index] then return false end
  end
  return true
end

local function set_lines_raw(buffer, first, last, lines)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) then return false end
  local was_modifiable = vim.bo[buffer.bufnr].modifiable
  vim.bo[buffer.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(buffer.bufnr, first, last, false, lines)
  vim.bo[buffer.bufnr].modified = false
  vim.bo[buffer.bufnr].modifiable = was_modifiable
  return true
end

local function clear_undo_history(buffer)
  local bufnr = buffer.bufnr
  local was_modifiable = vim.bo[bufnr].modifiable
  local undolevels = vim.bo[bufnr].undolevels
  local ok, err = pcall(function()
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].undolevels = -1
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, { "" })
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count + 1, false, {})
    vim.bo[bufnr].modified = false
  end)
  local undo_ok, undo_err = pcall(function()
    vim.bo[bufnr].undolevels = undolevels
  end)
  local modifiable_ok, modifiable_err = pcall(function()
    vim.bo[bufnr].modifiable = was_modifiable
  end)
  if not ok then error(err, 0) end
  if not undo_ok then error(undo_err, 0) end
  if not modifiable_ok then error(modifiable_err, 0) end
end

local function managed_windows(buffer)
  local windows = {}
  for _, inspected in ipairs(View.list(buffer.view_owner)) do
    windows[inspected.winid] = inspected.tabpage
  end
  return windows
end

local function capture_windows(buffer)
  local windows = {}
  for winid in pairs(managed_windows(buffer)) do
    pcall(function()
      local saved_view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
      local cursor = vim.api.nvim_win_get_cursor(winid)
      windows[winid] = { view = saved_view, cursor = cursor }
    end)
  end
  return windows
end

local function navigation_path(buffer)
  return path.parent(buffer.root) or buffer.root
end

local function ancestor_paths(buffer, absolute_path)
  local result = { absolute_path }
  local current = absolute_path
  while path.contains(buffer.root, current) and not path.equal(current, buffer.root) do
    current = path.parent(current)
    if not current then break end
    result[#result + 1] = current
  end
  return result
end

local function capture_view_cursors(buffer)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) then return {} end
  local baseline = buffer.view and buffer.view.baseline or {}
  local snapshots = {}
  for winid, tabpage in pairs(managed_windows(buffer)) do
    pcall(function()
      local saved_view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
      local cursor = vim.api.nvim_win_get_cursor(winid)
      local line = get_line(buffer, cursor[1])
      local decoded = row.decode_marker(buffer, cursor[1], line)
      if decoded.instance_id ~= buffer.id then return end
      local semantic_ok, semantic = pcall(row.decode, buffer, cursor[1], line, {
        allow_empty_path = true,
        validate_metadata = false,
      })
      local anchor
      if semantic_ok and semantic and semantic.marked then
        anchor = row.cursor_anchor(semantic, cursor[2])
      end
      local is_navigation = decoded.node_id == 0
      local absolute_path = is_navigation
        and navigation_path(buffer) or baseline[decoded.node_id]
      if type(absolute_path) ~= "string" or absolute_path == "" then return end
      snapshots[#snapshots + 1] = {
        winid = winid,
        tabpage = tabpage,
        navigation = is_navigation,
        paths = ancestor_paths(buffer, absolute_path),
        old_row = cursor[1],
        old_topline = saved_view.topline,
        column = cursor[2],
        anchor = anchor,
        view = saved_view,
      }
    end)
  end
  return snapshots
end

local function restore_view_cursors(buffer, snapshots, prepared)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) then return end
  local count = vim.api.nvim_buf_line_count(buffer.bufnr)
  if count < 1 then return end
  local rows_by_path = {}
  local row_offset = prepared.row_offset or 0
  local visible_nodes = prepared.visible_nodes or {}
  for index, node in ipairs(visible_nodes) do
    if type(node.path) == "string" and rows_by_path[node.path] == nil then
      rows_by_path[node.path] = index + row_offset
    end
  end
  local first_entry_row
  if visible_nodes[1] then
    local candidate = row_offset + 1
    local decoded_ok, decoded = pcall(M.decode, buffer, candidate, { tree = prepared.tree })
    if decoded_ok and decoded and decoded.row_kind == "entry"
        and decoded.instance_id == buffer.id then
      first_entry_row = candidate
    end
  end
  local navigation_row
  if row_offset > 0 then
    local decoded_ok, decoded = pcall(M.decode, buffer, 1, { tree = prepared.tree })
    if decoded_ok and decoded and decoded.row_kind == "navigation"
        and decoded.instance_id == buffer.id then
      navigation_row = 1
    end
  end
  for _, saved in ipairs(snapshots or {}) do
    local natural_view
    local ok = pcall(function()
      if not vim.api.nvim_win_is_valid(saved.winid)
          or vim.api.nvim_win_get_buf(saved.winid) ~= buffer.bufnr then return end
      local row_number
      if saved.navigation then
        row_number = navigation_row
      else
        for _, absolute_path in ipairs(saved.paths or {}) do
          row_number = rows_by_path[absolute_path]
          if row_number then break end
        end
        row_number = row_number or first_entry_row
      end
      if not row_number then return end
      row_number = math.max(1, math.min(row_number, count))
      local line = vim.api.nvim_buf_get_lines(
        buffer.bufnr, row_number - 1, row_number, false
      )[1] or ""
      local col = math.max(0, math.min(saved.column or 0, #line))
      local semantic_mapped = false
      if saved.anchor then
        local decoded_ok, decoded = pcall(row.decode, buffer, row_number, line, {
          allow_empty_path = true,
          validate_metadata = false,
          tree = prepared.tree,
        })
        if decoded_ok and decoded and decoded.marked then
          local mapped_col = row.cursor_column(
            decoded, saved.anchor, buffer.enabled_columns
          )
          if mapped_col ~= nil then
            col = mapped_col
            semantic_mapped = true
          end
        end
      end
      col = math.max(0, math.min(col, #line))
      vim.api.nvim_win_call(saved.winid, function()
        natural_view = vim.fn.winsaveview()
        vim.api.nvim_win_set_cursor(0, { row_number, col })
        local restored = vim.deepcopy(saved.view)
        restored.lnum = row_number
        restored.col = col
        restored.topline = math.max(1, math.min(
          (saved.old_topline or 1) + row_number - saved.old_row, count
        ))
        if semantic_mapped then
          restored.coladd = 0
          restored.curswant = vim.fn.winsaveview().curswant
        end
        vim.fn.winrestview(restored)
        M.constrain_cursor(buffer, saved.winid, prepared.tree)
      end)
    end)
    if not ok and natural_view then
      pcall(vim.api.nvim_win_call, saved.winid, function()
        vim.fn.winrestview(natural_view)
      end)
    end
  end
end

local function restore_windows(buffer, windows)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) then return end
  for winid, saved in pairs(windows or {}) do
    pcall(function()
      if not vim.api.nvim_win_is_valid(winid)
          or vim.api.nvim_win_get_buf(winid) ~= buffer.bufnr then return end
      local count = vim.api.nvim_buf_line_count(buffer.bufnr)
      local row_number = math.max(1, math.min(saved.cursor[1], count))
      local line = vim.api.nvim_buf_get_lines(
        buffer.bufnr, row_number - 1, row_number, false
      )[1] or ""
      local restored = vim.deepcopy(saved.view)
      restored.lnum = row_number
      restored.col = math.max(0, math.min(saved.cursor[2], #line))
      restored.topline = math.max(1, math.min(restored.topline or 1, count))
      vim.api.nvim_win_call(winid, function() vim.fn.winrestview(restored) end)
    end)
  end
end

local function snapshot(buffer)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) then return nil end
  local node_extmarks = {}
  for _, node in buffer.tree:iter_nodes() do
    node_extmarks[node.id] = buffer.row_extmarks[node.id]
  end
  return {
    lines = vim.api.nvim_buf_get_lines(buffer.bufnr, 0, -1, false),
    modified = vim.bo[buffer.bufnr].modified,
    modifiable = vim.bo[buffer.bufnr].modifiable,
    extmarks = vim.api.nvim_buf_get_extmarks(
      buffer.bufnr, row_namespace, 0, -1, { details = true }
    ),
    highlights = vim.api.nvim_buf_get_extmarks(
      buffer.bufnr, highlight_namespace, 0, -1, { details = true }
    ),
    node_extmarks = node_extmarks,
    windows = capture_windows(buffer),
    projection_ranges = buffer.projection_ranges,
    pending_initial_cursor = vim.deepcopy(buffer.pending_initial_cursor),
  }
end

local function restore(buffer, snapshot)
  if not snapshot or not vim.api.nvim_buf_is_valid(buffer.bufnr) then return false end
  vim.bo[buffer.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(buffer.bufnr, 0, -1, false, snapshot.lines)
  vim.api.nvim_buf_clear_namespace(buffer.bufnr, row_namespace, 0, -1)
  buffer.row_extmarks = {}
  for _, mark in ipairs(snapshot.extmarks) do
    local details = mark[4] or {}
    vim.api.nvim_buf_set_extmark(buffer.bufnr, row_namespace, mark[2], mark[3], {
      id = mark[1],
      right_gravity = details.right_gravity ~= false,
    })
  end
  vim.api.nvim_buf_clear_namespace(buffer.bufnr, highlight_namespace, 0, -1)
  for _, mark in ipairs(snapshot.highlights or {}) do
    local details = mark[4] or {}
    vim.api.nvim_buf_set_extmark(buffer.bufnr, highlight_namespace, mark[2], mark[3], {
      end_row = details.end_row,
      end_col = details.end_col,
      hl_group = details.hl_group,
      priority = details.priority,
      undo_restore = false,
    })
  end
  for id, mark in pairs(snapshot.node_extmarks or {}) do buffer.row_extmarks[id] = mark end
  buffer.projection_ranges = snapshot.projection_ranges
  buffer.pending_initial_cursor = snapshot.pending_initial_cursor
  vim.bo[buffer.bufnr].modified = snapshot.modified
  vim.bo[buffer.bufnr].modifiable = snapshot.modifiable
  restore_windows(buffer, snapshot.windows)
  return true
end

function M.commit(buffer, prepared)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) then return false end
  local captured, cursor_snapshots = pcall(capture_view_cursors, buffer)
  if not captured then cursor_snapshots = {} end
  local snapshot = snapshot(buffer)
  local previous_view = buffer.view or {}
  local previous_render_cache = buffer.render_cache
  local previous_hidden_columns = buffer.hidden_columns
  local previous_visible_columns = buffer.visible_columns
  local previous_visible_column_ids = buffer.visible_column_ids
  local ok, result = pcall(function()
    local previous_widths = previous_view.column_widths
    local current = vim.api.nvim_buf_get_lines(buffer.bufnr, 0, -1, false)
    local patch
    if same_widths(previous_widths, prepared.column_widths) then
      local prefix = 0
      while prefix < #current and prefix < #prepared.lines
          and current[prefix + 1] == prepared.lines[prefix + 1] do
        prefix = prefix + 1
      end
      local suffix = 0
      while suffix < #current - prefix and suffix < #prepared.lines - prefix
          and current[#current - suffix] == prepared.lines[#prepared.lines - suffix] do
        suffix = suffix + 1
      end
      if prefix == #current and prefix == #prepared.lines then
        patch = { kind = "none" }
      else
        local replacement = {}
        for index = prefix + 1, #prepared.lines - suffix do
          replacement[#replacement + 1] = prepared.lines[index]
        end
        if not set_lines_raw(buffer, prefix, #current - suffix, replacement) then
          return false
        end
        patch = {
          kind = "interval", start_row = prefix + 1,
          old_end_row = #current - suffix, new_end_row = #prepared.lines - suffix,
        }
      end
    else
      if not set_lines_raw(buffer, 0, -1, prepared.lines) then return false end
      patch = { kind = "full", start_row = 1, old_end_row = -1, new_end_row = #prepared.lines }
    end

    vim.api.nvim_buf_clear_namespace(buffer.bufnr, row_namespace, 0, -1)
    buffer.row_extmarks = {}
    local row_offset = prepared.row_offset or 0
    for row, node in ipairs(prepared.visible_nodes) do
      local buffer_row = row + row_offset
      set_node_extmark(buffer, node, buffer_row)
    end
    vim.api.nvim_buf_clear_namespace(buffer.bufnr, highlight_namespace, 0, -1)
    for _, highlight in ipairs(prepared.highlights or {}) do
      vim.api.nvim_buf_set_extmark(
        buffer.bufnr, highlight_namespace, highlight.row, highlight.start_col, {
          end_col = highlight.end_col,
          hl_group = highlight.hl_group,
          priority = 100,
          undo_restore = false,
        }
      )
    end
    buffer.render_cache = prepared.render_cache or buffer.render_cache
    if prepared.column_state then
      buffer.hidden_columns = prepared.column_state.hidden_columns
      buffer.visible_columns = prepared.column_state.visible_columns
      buffer.visible_column_ids = prepared.column_state.visible_column_ids
      buffer.marker_source.visible_columns = buffer.visible_columns
    end
    buffer.view = {
      baseline = prepared.baseline,
      column_widths = prepared.column_widths,
      row_templates = prepared.row_templates,
      projection = prepared.projection,
      visible_nodes = prepared.visible_nodes,
      row_offset = prepared.row_offset,
      last_patch = patch,
      projection_generation = (previous_view.projection_generation or 0) + 1,
    }
    buffer.marker_source.view = buffer.view
    buffer.projection_ranges = prepared.projection and prepared.projection.ranges or {}
    vim.bo[buffer.bufnr].modified = false
    pcall(restore_view_cursors, buffer, cursor_snapshots, prepared)
    local pending = {}
    for winid in pairs(buffer.pending_initial_cursor or {}) do
      pending[#pending + 1] = winid
    end
    for _, winid in ipairs(pending) do M.place_initial_cursor(buffer, winid) end
    clear_undo_history(buffer)
    return true
  end)
  if not ok or result == false then
    buffer.view = previous_view
    buffer.marker_source.view = buffer.view
    buffer.render_cache = previous_render_cache
    buffer.hidden_columns = previous_hidden_columns
    buffer.visible_columns = previous_visible_columns
    buffer.visible_column_ids = previous_visible_column_ids
    buffer.marker_source.visible_columns = buffer.visible_columns
    local restore_ok, restore_err = pcall(restore, buffer, snapshot)
    if not restore_ok then
      error(tostring(result) .. "; rollback failed: " .. tostring(restore_err), 0)
    end
    local history_ok, history_err = pcall(clear_undo_history, buffer)
    if not history_ok then
      error(tostring(result) .. "; rollback undo cleanup failed: " .. tostring(history_err), 0)
    end
    if not ok then error(result, 0) end
    return false
  end
  return true
end

function M.project(buffer, projection, render_path)
  local prepared = M.prepare(buffer, projection, render_path)
  return M.commit(buffer, prepared)
end

local function redecorate_rows(buffer, first_row, last_row)
  if not vim.api.nvim_buf_is_valid(buffer.bufnr) or last_row < first_row then return end
  local count = vim.api.nvim_buf_line_count(buffer.bufnr)
  first_row = math.max(1, first_row)
  last_row = math.min(count, last_row)
  if last_row < first_row then return end
  vim.api.nvim_buf_clear_namespace(
    buffer.bufnr, highlight_namespace, first_row - 1, last_row
  )
  local lines = vim.api.nvim_buf_get_lines(
    buffer.bufnr, first_row - 1, last_row, false
  )
  for offset, line in ipairs(lines) do
    local row_number = first_row + offset - 1
    local ok, decorations = pcall(row.decorations, buffer, row_number, line)
    for _, template in ipairs(ok and decorations or {}) do
      if line:sub(template.start_col + 1, template.end_col) == template.text then
        vim.api.nvim_buf_set_extmark(
          buffer.bufnr, highlight_namespace, first_row + offset - 2,
          template.start_col, {
            end_col = template.end_col,
            hl_group = template.hl_group,
            priority = 100,
            undo_restore = false,
          }
        )
      end
    end
  end
end

local function apply_pending_highlight_update(buffer)
  buffer.highlight_update_scheduled = false
  local pending = buffer.highlight_pending
  buffer.highlight_pending = nil
  if not pending or buffer.highlight_disabled or buffer.lifecycle:is_destroyed()
      or buffer.lifecycle:is_destroying()
      or not vim.api.nvim_buf_is_valid(buffer.bufnr) then
    return
  end

  local ok, err = pcall(function()
    if pending.full then
      vim.api.nvim_buf_clear_namespace(buffer.bufnr, highlight_namespace, 0, -1)
      redecorate_rows(
        buffer, 1, vim.api.nvim_buf_line_count(buffer.bufnr)
      )
    else
      redecorate_rows(buffer, pending.first_row, pending.last_row)
    end
  end)
  if ok then
    buffer.highlight_error_reported = nil
  elseif not buffer.highlight_error_reported then
    buffer.highlight_error_reported = true
    buffer.report_async_error("column highlight update failed: " .. tostring(err))
  end
end

local function queue_highlight_update(buffer, first_line, old_last_line, new_last_line)
  local pending = buffer.highlight_pending
  if pending then
    -- Multiple edits before the scheduled pass can shift every prior range.
    pending.full = true
  else
    buffer.highlight_pending = {
      full = old_last_line > new_last_line,
      first_row = first_line + 1,
      last_row = new_last_line,
    }
  end
  if buffer.highlight_update_scheduled then return end
  buffer.highlight_update_scheduled = true
  vim.schedule(function() apply_pending_highlight_update(buffer) end)
end

local function attach_highlight_updates(buffer)
  buffer.highlight_disabled = false
  buffer.highlight_pending = nil
  buffer.highlight_update_scheduled = false
  local attached = vim.api.nvim_buf_attach(buffer.bufnr, false, {
    on_lines = function(_, bufnr, _, first_line, old_last_line, new_last_line)
      if buffer.highlight_disabled or buffer.lifecycle:is_destroyed()
          or buffer.lifecycle:is_destroying() then
        return true
      end
      if bufnr ~= buffer.bufnr then return true end
      queue_highlight_update(buffer, first_line, old_last_line, new_last_line)
    end,
    on_detach = function()
      buffer.highlight_attached = false
      buffer.highlight_pending = nil
      buffer.highlight_update_scheduled = false
    end,
  })
  if not attached then fail("could not attach column highlight updates", 3) end
  buffer.highlight_attached = true
end

local function externally_deleted(buffer)
  if buffer.lifecycle:is_destroyed() or buffer.external_delete_cleanup_scheduled then return end
  buffer.external_delete_cleanup_scheduled = true
  local ok, err = pcall(vim.schedule, function()
    if buffer.lifecycle:is_destroyed() then
      buffer.external_delete_cleanup_scheduled = nil
      return
    end
    local was_destroying = buffer.lifecycle:is_destroying()
    local destroy_ok, destroy_err = pcall(buffer.request_destroy)
    if not destroy_ok and not was_destroying and buffer.lifecycle:is_destroying() then
      buffer.report_async_error(
        "external buffer deletion cleanup failed: " .. tostring(destroy_err)
      )
      local finish_ok, finish_err = pcall(buffer.request_destroy)
      if not finish_ok then
        buffer.report_async_error(
          "external buffer deletion cleanup failed: " .. tostring(finish_err)
        )
      end
    elseif not destroy_ok then
      buffer.report_async_error(
        "external buffer deletion cleanup failed: " .. tostring(destroy_err)
      )
    end
    buffer.external_delete_cleanup_scheduled = nil
  end)
  if not ok then
    buffer.external_delete_cleanup_scheduled = nil
    buffer.report_async_error(
      "external buffer deletion cleanup scheduling failed: " .. tostring(err)
    )
  end
end

function M.setup(buffer)
  vim.api.nvim_set_hl(0, "FreStableMarker", { default = true, link = "Conceal" })
  vim.api.nvim_set_hl(0, "FreDirectoryIcon", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "FreSymlinkIcon", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "FreFileIcon", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "FreUnsupportedIcon", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "FreDirectoryPath", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "FreHiddenPath", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "FreDirectoryPrefix", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "FreHiddenDirectoryPrefix", { default = true, fg = "#707868" })
  vim.api.nvim_set_hl(0, "FrePathSeparator", { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, "FreHiddenPathSeparator", { default = true, fg = "#596054" })
  vim.api.nvim_set_hl(0, "FreHiddenFile", { default = true, fg = "#b8c0a9" })
  vim.api.nvim_set_hl(0, "FreHiddenDirectory", { default = true, fg = "#b8c0a9" })
  vim.api.nvim_buf_call(buffer.bufnr, function()
    vim.cmd("runtime! syntax/fre.vim")
  end)
  attach_highlight_updates(buffer)

  local group_name = "FreBuffer" .. tostring(buffer.bufnr)
  buffer.buffer_augroup = vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = buffer.buffer_augroup, buffer = buffer.bufnr,
    callback = function() externally_deleted(buffer) end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = buffer.buffer_augroup, buffer = buffer.bufnr,
    callback = function(args)
      local winid = vim.api.nvim_get_current_win()
      local row, col = 1, 0
      if vim.api.nvim_get_current_buf() == args.buf then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        row, col = cursor[1], cursor[2]
      end
      buffer.work:write({
        bufnr = args.buf,
        winid = winid,
        tabpage = vim.api.nvim_get_current_tabpage(),
        mode = vim.api.nvim_get_mode().mode,
        row = row,
        col = col,
      })
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = buffer.buffer_augroup, buffer = buffer.bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      View.apply_window(buffer.view_owner, winid)
      View.sync(buffer.view_owner, { report = true })
      M.place_initial_cursor(buffer, winid)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWinLeave", "BufHidden" }, {
    group = buffer.buffer_augroup, buffer = buffer.bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if buffer.pending_initial_cursor then
        buffer.pending_initial_cursor[winid] = nil
      end
      vim.schedule(function()
        if buffer.lifecycle:is_destroyed() then return end
        View.sync(buffer.view_owner, { report = true })
      end)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = buffer.buffer_augroup, buffer = buffer.bufnr,
    callback = function() M.constrain_cursor(buffer) end,
  })
  for _, event in ipairs({ "InsertEnter", "InsertCharPre", "CursorMovedI" }) do
    vim.api.nvim_create_autocmd(event, {
      group = buffer.buffer_augroup, buffer = buffer.bufnr,
      callback = function() M.constrain_cursor(buffer) end,
    })
  end
end

function M.teardown(buffer)
  buffer.highlight_disabled = true
  buffer.highlight_pending = nil
  if buffer.buffer_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buffer.buffer_augroup)
    buffer.buffer_augroup = nil
  end
end

M.namespace = row_namespace
return M
