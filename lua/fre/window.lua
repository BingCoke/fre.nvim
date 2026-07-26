local M = {}

local positions = {
  current = true,
  left = true,
  right = true,
  top = true,
  bottom = true,
  float = true,
}

local fields = {
  position = true,
  size = true,
  width = true,
  height = true,
  row = true,
  col = true,
  border = true,
}

local named_borders = {
  none = true,
  single = true,
  double = true,
  rounded = true,
  solid = true,
  shadow = true,
}

local function fail(message, level)
  error("fre.window: " .. message, level or 3)
end

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function dimension(value, path)
  if not finite(value) or value <= 0 then
    fail(path .. " must be a positive integer or a ratio greater than zero and less than one", 4)
  end
  if value < 1 then return value end
  if value % 1 ~= 0 then
    fail(path .. " absolute cell value must be an integer", 4)
  end
  return value
end

local function offset(value, path)
  if not finite(value) or value < 0 then
    fail(path .. " must be a non-negative integer or a ratio less than one", 4)
  end
  if value < 1 then return value end
  if value % 1 ~= 0 then
    fail(path .. " absolute cell value must be an integer", 4)
  end
  return value
end

local function sequence_length(value, path)
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      fail(path .. " must be an eight-item array", 4)
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then fail(path .. " must not contain nil holes", 4) end
  return maximum
end

local function validate_border(value, path)
  if type(value) == "string" then
    if not named_borders[value] then fail(path .. " is not supported", 4) end
    return value
  end
  if type(value) ~= "table" or sequence_length(value, path) ~= 8 then
    fail(path .. " must be a supported name or an eight-item array", 4)
  end
  local result = {}
  for index, item in ipairs(value) do
    if type(item) == "string" then
      result[index] = item
    elseif type(item) == "table" and sequence_length(item, path .. "[" .. index .. "]") == 2
        and type(item[1]) == "string" and type(item[2]) == "string" then
      result[index] = { item[1], item[2] }
    else
      fail(path .. "[" .. index .. "] must be a string or { text, highlight }", 4)
    end
  end
  return result
end

local function copy(value)
  return vim.deepcopy(value)
end

local function allowed_fields(position)
  if position == "current" then return { position = true } end
  if position == "left" or position == "right"
      or position == "top" or position == "bottom" then
    return { position = true, size = true }
  end
  return {
    position = true, width = true, height = true,
    row = true, col = true, border = true,
  }
end

--- Validate and copy a layout. Partial validation accepts omitted required
--- fields for configuration inheritance, but still rejects explicitly
--- position-incompatible fields.
function M.normalize(layout, opts)
  opts = opts or {}
  local path = opts.path or "layout"
  if type(layout) ~= "table" then fail(path .. " must be a table", 3) end
  for key in pairs(layout) do
    if type(key) ~= "string" or not fields[key] then
      fail(path .. " contains unknown field " .. tostring(key), 3)
    end
  end

  local result = {}
  if layout.position ~= nil then
    if type(layout.position) ~= "string" then fail(path .. ".position must be a string", 3) end
    if not positions[layout.position] then fail(path .. ".position is not supported", 3) end
    result.position = layout.position
  elseif not opts.partial then
    fail(path .. ".position is required", 3)
  end
  if layout.size ~= nil then result.size = dimension(layout.size, path .. ".size") end
  if layout.width ~= nil then result.width = dimension(layout.width, path .. ".width") end
  if layout.height ~= nil then result.height = dimension(layout.height, path .. ".height") end
  if layout.row ~= nil then result.row = offset(layout.row, path .. ".row") end
  if layout.col ~= nil then result.col = offset(layout.col, path .. ".col") end
  if layout.border ~= nil then result.border = validate_border(layout.border, path .. ".border") end
  if result.position == nil then return result end

  local allowed = allowed_fields(result.position)
  for key in pairs(result) do
    if not allowed[key] then
      fail(path .. "." .. key .. " is not valid for position " .. result.position, 3)
    end
  end
  if not opts.partial then
    if allowed.size and result.size == nil then
      fail(path .. ".size is required for split layouts", 3)
    end
    if allowed.width and result.width == nil then
      fail(path .. ".width is required for float layouts", 3)
    end
    if allowed.height and result.height == nil then
      fail(path .. ".height is required for float layouts", 3)
    end
  end
  local exact = {}
  for key in pairs(allowed) do
    if result[key] ~= nil then exact[key] = copy(result[key]) end
  end
  return exact
end

function M.merge_layout(base, override, opts)
  opts = opts or {}
  local path = opts.path or "layout"
  local inherited = M.normalize(base, { path = path })
  if override == nil then return inherited end
  local patch = M.normalize(override, { path = path, partial = true })
  local position = patch.position or inherited.position
  local allowed = allowed_fields(position)
  for key in pairs(patch) do
    if not allowed[key] then
      fail(path .. "." .. key .. " is not valid for position " .. position, 3)
    end
  end
  local result
  local inherited_split = inherited.position == "left" or inherited.position == "right"
    or inherited.position == "top" or inherited.position == "bottom"
  local patch_split = position == "left" or position == "right"
    or position == "top" or position == "bottom"
  local same_family = inherited.position == position or (inherited_split and patch_split)
  if patch.position ~= nil and not same_family then
    result = { position = position }
  else
    result = copy(inherited)
    result.position = position
  end
  for key, value in pairs(patch) do result[key] = copy(value) end
  return M.normalize(result, { path = path })
end

local function resolve_cells(value, total)
  if value < 1 then return math.max(1, math.floor(total * value)) end
  return value
end

local function resolve_offset(value, total, extent)
  if value == nil then return math.max(0, math.floor((total - extent) / 2)) end
  if value < 1 then return math.floor(total * value) end
  return value
end

local function layout_extent(node, axis, minimum)
  if node[1] == "leaf" then
    local actual = axis == "width"
      and vim.api.nvim_win_get_width(node[2]) or vim.api.nvim_win_get_height(node[2])
    if not minimum then return actual end
    local configured = axis == "width" and vim.o.winminwidth or vim.o.winminheight
    return math.min(actual, configured)
  end
  local children = node[2] or {}
  local parallel = (axis == "width" and node[1] == "row")
    or (axis == "height" and node[1] == "col")
  local extent = parallel and math.max(0, #children - 1) or 0
  for _, child in ipairs(children) do
    local child_extent = layout_extent(child, axis, minimum)
    if parallel then
      extent = extent + child_extent
    else
      extent = math.max(extent, child_extent)
    end
  end
  return extent
end

local function split_capacity(position)
  local axis = (position == "left" or position == "right") and "width" or "height"
  local root = vim.fn.winlayout()
  local usable = layout_extent(root, axis, false)
  local remaining = layout_extent(root, axis, true)
  return usable - remaining - 1
end

local function border_text(item)
  if type(item) == "table" then item = item[1] end
  return type(item) == "string" and item or ""
end

local function border_extents(border)
  if border == nil or border == "none" then return 0, 0, 0, 0 end
  if type(border) == "string" then
    if border == "shadow" then return 0, 1, 1, 0 end
    return 1, 1, 1, 1
  end
  local present = {}
  for index = 1, 8 do present[index] = border_text(border[index]) ~= "" end
  local top = (present[1] or present[2] or present[3]) and 1 or 0
  local right = (present[3] or present[4] or present[5]) and 1 or 0
  local bottom = (present[5] or present[6] or present[7]) and 1 or 0
  local left = (present[7] or present[8] or present[1]) and 1 or 0
  return top, right, bottom, left
end

function M.materialize(layout)
  local position = layout.position
  if position == "current" then return { position = position } end
  if position ~= "float" then
    local total = (position == "left" or position == "right") and vim.o.columns or vim.o.lines
    local size = resolve_cells(layout.size, total)
    if size >= total then fail("layout.size does not leave room for another split", 3) end
    return { position = position, size = size }
  end

  local width = resolve_cells(layout.width, vim.o.columns)
  local height = resolve_cells(layout.height, vim.o.lines)
  local row = resolve_offset(layout.row, vim.o.lines, height)
  local col = resolve_offset(layout.col, vim.o.columns, width)
  local top, right, bottom, left = border_extents(layout.border)
  if row + height + top + bottom > vim.o.lines then
    fail("layout.row places the bordered float outside the editor", 3)
  end
  if col + width + left + right > vim.o.columns then
    fail("layout.col places the bordered float outside the editor", 3)
  end
  return {
    position = position,
    width = width,
    height = height,
    row = row,
    col = col,
    border = copy(layout.border),
  }
end

local function validate_split_fit(effective)
  if effective.position ~= "current" and effective.position ~= "float"
      and effective.size > split_capacity(effective.position) then
    fail("layout.size cannot be materialized exactly in the current tab", 4)
  end
end

local function current_tab_windows(instance)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local result = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      result[#result + 1] = winid
    end
  end
  table.sort(result)
  return result
end

function M.select(instance)
  local windows = current_tab_windows(instance)
  local current = vim.api.nvim_get_current_win()
  for _, winid in ipairs(windows) do
    if winid == current then return winid end
  end
  return windows[1]
end

local function metadata_name(instance)
  return "fre_layout_" .. tostring(instance.id)
end

local function get_metadata(instance, winid)
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return nil end
  local ok, value = pcall(vim.api.nvim_win_get_var, winid, metadata_name(instance))
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function set_metadata(instance, winid, layout, effective)
  vim.api.nvim_win_set_var(winid, metadata_name(instance), {
    layout = copy(layout),
    effective = copy(effective),
  })
end

local function clear_metadata(instance, winid)
  if vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_del_var, winid, metadata_name(instance))
  end
end

local function snapshot_metadata(instance, winid)
  local ok, value = pcall(vim.api.nvim_win_get_var, winid, metadata_name(instance))
  return { present = ok, value = ok and copy(value) or nil }
end

local function restore_metadata(instance, winid, snapshot)
  if not vim.api.nvim_win_is_valid(winid) then return end
  if snapshot.present then
    pcall(vim.api.nvim_win_set_var, winid, metadata_name(instance), copy(snapshot.value))
  else
    pcall(vim.api.nvim_win_del_var, winid, metadata_name(instance))
  end
end

local function effective_layout(instance, winid)
  local metadata = get_metadata(instance, winid)
  if metadata and type(metadata.effective) == "table" then return metadata.effective end
  -- A manually-created ordinary view has current-window semantics until Fre
  -- explicitly gives it another layout.
  local config = vim.api.nvim_win_get_config(winid)
  if config.relative == "" then return { position = "current" } end
  return nil
end

function M.same_layout(instance, winid, effective)
  local actual = effective_layout(instance, winid)
  return actual ~= nil and vim.deep_equal(actual, effective)
end

function M.apply_window_options(instance, winid)
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return false end
  for key, value in pairs(instance.config.window.options or {}) do
    vim.api.nvim_set_option_value(key, value, { win = winid })
  end
  return true
end

function M.apply_all(instance)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return end
  for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
    M.apply_window_options(instance, winid)
  end
end

local function snapshot_window_options(instance, winid)
  local result = {}
  for key in pairs(instance.config.window.options or {}) do
    result[key] = vim.api.nvim_get_option_value(key, { win = winid })
  end
  return result
end

local function restore_window_options(winid, snapshot)
  if not vim.api.nvim_win_is_valid(winid) then return end
  for key, value in pairs(snapshot) do
    pcall(vim.api.nvim_set_option_value, key, value, { win = winid })
  end
end

function M.sync_visibility(instance)
  if instance._destroyed then return end
  local visible = false
  if vim.api.nvim_buf_is_valid(instance.bufnr) then
    for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
      if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
        visible = true
        break
      end
    end
  end
  if visible and instance.state == "ready-hidden" then
    instance.state = "ready-visible"
  elseif not visible and instance.state == "ready-visible" then
    instance.state = "ready-hidden"
  end
  return visible
end

local function save_view(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return nil end
  return {
    cursor = vim.api.nvim_win_get_cursor(winid),
    view = vim.api.nvim_win_call(winid, vim.fn.winsaveview),
  }
end

local function restore_view(winid, saved)
  if not saved or not vim.api.nvim_win_is_valid(winid) then return end
  pcall(vim.api.nvim_win_call, winid, vim.fn.winrestview, saved.view)
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
  local row = math.max(1, math.min(saved.cursor[1], count))
  local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), row - 1, row, false)[1] or ""
  local col = math.max(0, math.min(saved.cursor[2], #line))
  pcall(vim.api.nvim_win_set_cursor, winid, { row, col })
end

local function snapshot_destination(instance, winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return {
    winid = winid,
    bufnr = bufnr,
    bufhidden = vim.api.nvim_get_option_value("bufhidden", { buf = bufnr }),
    view = save_view(winid),
    options = snapshot_window_options(instance, winid),
    metadata = snapshot_metadata(instance, winid),
    focus = vim.api.nvim_get_current_win(),
  }
end

local function protect_destination_buffer(instance, snapshot)
  if snapshot.bufnr == instance.bufnr then return end
  if snapshot.bufhidden == "wipe" or snapshot.bufhidden == "delete"
      or snapshot.bufhidden == "unload" then
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = snapshot.bufnr })
    snapshot.protected = true
  end
end

local function restore_destination_buffer(snapshot)
  if snapshot.protected and vim.api.nvim_buf_is_valid(snapshot.bufnr) then
    vim.api.nvim_set_option_value("bufhidden", snapshot.bufhidden, { buf = snapshot.bufnr })
    snapshot.protected = nil
  end
end

local function restore_destination(instance, snapshot)
  local winid = snapshot.winid
  if vim.api.nvim_win_is_valid(winid) then
    if vim.api.nvim_buf_is_valid(snapshot.bufnr)
        and vim.api.nvim_win_get_buf(winid) ~= snapshot.bufnr then
      pcall(vim.api.nvim_win_set_buf, winid, snapshot.bufnr)
    end
    if snapshot.protected and vim.api.nvim_buf_is_valid(snapshot.bufnr) then
      pcall(vim.api.nvim_set_option_value, "bufhidden", snapshot.bufhidden, { buf = snapshot.bufnr })
      snapshot.protected = nil
    end
    restore_window_options(winid, snapshot.options)
    restore_metadata(instance, winid, snapshot.metadata)
    restore_view(winid, snapshot.view)
  end
  if vim.api.nvim_win_is_valid(snapshot.focus) then
    pcall(vim.api.nvim_set_current_win, snapshot.focus)
  end
end

local function is_float(winid)
  return vim.api.nvim_win_get_config(winid).relative ~= ""
end

local function normal_windows(tabpage)
  local result = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(winid) and not is_float(winid) then
      result[#result + 1] = winid
    end
  end
  table.sort(result)
  return result
end

local function scratch_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(vim.api.nvim_set_option_value, "bufhidden", "wipe", { buf = bufnr })
  if not ok then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    error(err, 0)
  end
  return bufnr
end

local function remove_view(instance, winid, preserve_normal)
  if not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return true end
  local scratch
  local ok, err = pcall(function()
    if is_float(winid) then
      vim.api.nvim_win_close(winid, true)
      return
    end
    local tabpage = vim.api.nvim_win_get_tabpage(winid)
    if preserve_normal or #normal_windows(tabpage) == 1 then
      scratch = scratch_buffer()
      vim.api.nvim_win_set_buf(winid, scratch)
    else
      vim.api.nvim_win_close(winid, true)
    end
  end)
  local removed = not vim.api.nvim_win_is_valid(winid)
    or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr
  if removed then
    if vim.api.nvim_win_is_valid(winid) then clear_metadata(instance, winid) end
    return true
  end
  if scratch and vim.api.nvim_buf_is_valid(scratch) and #vim.fn.win_findbuf(scratch) == 0 then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  return false, ok and "failed to remove selected Fre view" or err
end

local function split_anchor(tabpage, preferred)
  if preferred and vim.api.nvim_win_is_valid(preferred)
      and vim.api.nvim_win_get_tabpage(preferred) == tabpage and not is_float(preferred) then
    return preferred
  end
  return normal_windows(tabpage)[1]
end

local function resize_split(winid, layout, size)
  if layout.position == "left" or layout.position == "right" then
    vim.api.nvim_win_set_width(winid, size)
  else
    vim.api.nvim_win_set_height(winid, size)
  end
end

local function split_size(winid, layout)
  if layout.position == "left" or layout.position == "right" then
    return vim.api.nvim_win_get_width(winid)
  end
  return vim.api.nvim_win_get_height(winid)
end

local function split_fix_option(layout)
  if layout.position == "left" or layout.position == "right" then return "winfixwidth" end
  return "winfixheight"
end

local function set_split_fixed(winid, option, value)
  vim.api.nvim_win_call(winid, function()
    vim.cmd("noautocmd setlocal " .. (value and "" or "no") .. option)
  end)
end

local function build_split_buffer(bufnr, layout, effective, preferred)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local anchor = assert(split_anchor(tabpage, preferred), "current tab has no ordinary window")
  vim.api.nvim_set_current_win(anchor)
  local commands = {
    left = "topleft vertical split",
    right = "botright vertical split",
    top = "topleft split",
    bottom = "botright split",
  }
  vim.cmd(commands[layout.position])
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  resize_split(winid, layout, effective.size)
  return winid
end

local function build_float(instance, layout, effective)
  local config = {
    relative = "editor",
    style = "minimal",
    width = effective.width,
    height = effective.height,
    row = effective.row,
    col = effective.col,
  }
  if layout.border ~= nil then config.border = copy(layout.border) end
  return vim.api.nvim_open_win(instance.bufnr, true, config)
end

local function build_current(instance, preferred)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local winid = preferred
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_tabpage(winid) ~= tabpage then
    winid = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_buf(winid, instance.bufnr)
  return winid
end

local function snapshot_windows(tabpage)
  local result = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do result[winid] = true end
  return result
end

local function rollback_created_windows(tabpage, before, caller_win)
  local created = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if not before[winid] then created[#created + 1] = winid end
  end
  table.sort(created, function(left, right) return left > right end)
  for _, winid in ipairs(created) do
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
      if vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_call, winid, function() vim.cmd("noautocmd close!") end)
      end
    end
  end
  if vim.api.nvim_win_is_valid(caller_win)
      and vim.api.nvim_win_get_tabpage(caller_win) == tabpage then
    pcall(vim.api.nvim_set_current_win, caller_win)
  end
end

function M.replace(instance, winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    fail("target window is not valid", 2)
  end
  local snapshot = snapshot_destination(instance, winid)
  local ok, err = pcall(function()
    protect_destination_buffer(instance, snapshot)
    vim.api.nvim_win_set_buf(winid, instance.bufnr)
    restore_destination_buffer(snapshot)
    M.apply_window_options(instance, winid)
    if not is_float(winid) then
      local current = { position = "current" }
      set_metadata(instance, winid, current, current)
      instance._last_layout_by_tab = instance._last_layout_by_tab or {}
      instance._last_layout_by_tab[vim.api.nvim_win_get_tabpage(winid)] = current
    end
  end)
  if not ok then
    restore_destination(instance, snapshot)
    error(err, 0)
  end
  M.sync_visibility(instance)
  return winid
end

function M.replace_buffer(instance, winid, bufnr)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    fail("target window is not valid", 2)
  end
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    fail("replacement buffer is not valid", 2)
  end
  local snapshot = snapshot_destination(instance, winid)
  local ok, err = pcall(function()
    protect_destination_buffer(instance, snapshot)
    vim.api.nvim_win_set_buf(winid, bufnr)
    restore_destination_buffer(snapshot)
    clear_metadata(instance, winid)
  end)
  if not ok then
    restore_destination(instance, snapshot)
    pcall(M.sync_visibility, instance)
    error(err, 0)
  end
  M.sync_visibility(instance)
  return winid
end

function M.prepare_split(requested)
  local layout = M.normalize(requested, { path = "layout" })
  if layout.position ~= "left" and layout.position ~= "right"
      and layout.position ~= "top" and layout.position ~= "bottom" then
    fail("layout.position must be left, right, top, or bottom", 2)
  end
  local effective = M.materialize(layout)
  validate_split_fit(effective)
  return copy(layout), copy(effective)
end

function M.split_buffer(bufnr, requested)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    fail("split buffer is not valid", 2)
  end
  local layout, effective = M.prepare_split(requested)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local caller_win = vim.api.nvim_get_current_win()
  local before = snapshot_windows(tabpage)
  local winid
  local ok, err = pcall(function()
    winid = build_split_buffer(bufnr, layout, effective, caller_win)
    if split_size(winid, layout) ~= effective.size then
      fail("layout.size could not be materialized exactly", 4)
    end
  end)
  if not ok then
    rollback_created_windows(tabpage, before, caller_win)
    error(err, 0)
  end
  return winid
end

local function resolve(instance, layout, tabpage)
  if layout ~= nil then return M.normalize(layout) end
  local remembered = instance._last_layout_by_tab and instance._last_layout_by_tab[tabpage]
  if remembered ~= nil then return M.normalize(remembered) end
  return M.normalize(instance.config.layout)
end

local function remember(instance, tabpage, layout)
  instance._last_layout_by_tab = instance._last_layout_by_tab or {}
  instance._last_layout_by_tab[tabpage] = layout
end

local function open_prepared(instance, tabpage, layout, effective, selected, caller_win)
  local remembered = copy(layout)
  if selected and M.same_layout(instance, selected, effective) then
    local previous_options = snapshot_window_options(instance, selected)
    local ok, result = pcall(function()
      vim.api.nvim_set_current_win(selected)
      M.apply_window_options(instance, selected)
    end)
    if not ok then
      restore_window_options(selected, previous_options)
      if vim.api.nvim_win_is_valid(caller_win) then
        pcall(vim.api.nvim_set_current_win, caller_win)
      end
      error(result, 0)
    end
    remember(instance, tabpage, remembered)
    pcall(M.sync_visibility, instance)
    return selected
  end

  local saved = save_view(selected)
  local winid
  if layout.position == "current" then
    local destination = selected == caller_win and selected or caller_win
    local snapshot = snapshot_destination(instance, destination)
    local ok, result = pcall(function()
      protect_destination_buffer(instance, snapshot)
      winid = build_current(instance, destination)
      restore_destination_buffer(snapshot)
      restore_view(winid, saved)
      M.apply_window_options(instance, winid)
      set_metadata(instance, winid, layout, effective)
    end)
    if not ok then
      restore_destination(instance, snapshot)
      error(result, 0)
    end
    if selected and selected ~= winid then
      local preserve = not is_float(selected) and #normal_windows(tabpage) == 1
      local removed, remove_err = remove_view(instance, selected, preserve)
      if not removed then
        restore_destination(instance, snapshot)
        error(remove_err, 0)
      end
    end
  else
    local before = snapshot_windows(tabpage)
    local preserve_normal = selected and not is_float(selected)
      and #normal_windows(tabpage) == 1
    local fix_option, fixed_before
    local ok, result = pcall(function()
      if layout.position == "float" then
        winid = build_float(instance, layout, effective)
      else
        winid = build_split_buffer(instance.bufnr, layout, effective, caller_win)
      end
      restore_view(winid, saved)
      M.apply_window_options(instance, winid)
      set_metadata(instance, winid, layout, effective)
      if layout.position ~= "float" and split_size(winid, layout) ~= effective.size then
        fail("layout.size could not be materialized exactly", 4)
      end
      if selected and layout.position ~= "float" and not is_float(selected) then
        fix_option = split_fix_option(layout)
        fixed_before = vim.api.nvim_get_option_value(fix_option, { win = winid })
        set_split_fixed(winid, fix_option, true)
      end
    end)
    if not ok then
      rollback_created_windows(tabpage, before, caller_win)
      pcall(M.sync_visibility, instance)
      error(result, 0)
    end
    if selected then
      local removed, remove_err = remove_view(instance, selected, preserve_normal)
      if not removed then
        if fix_option then pcall(set_split_fixed, winid, fix_option, fixed_before) end
        rollback_created_windows(tabpage, before, caller_win)
        pcall(M.sync_visibility, instance)
        error(remove_err, 0)
      end
    end
    if fix_option then
      local restored = pcall(set_split_fixed, winid, fix_option, fixed_before)
      if not restored then pcall(set_split_fixed, winid, fix_option, fixed_before) end
    end
  end
  if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_get_current_win() ~= winid then
    pcall(vim.api.nvim_set_current_win, winid)
  end
  remember(instance, tabpage, remembered)
  pcall(M.sync_visibility, instance)
  return winid
end

function M.open(instance, requested)
  local tabpage = vim.api.nvim_get_current_tabpage()
  -- Parsing and geometry checks precede the transition guard and editor state.
  local layout = resolve(instance, requested, tabpage)
  local effective = M.materialize(layout)
  local selected = M.select(instance)
  if not (selected and M.same_layout(instance, selected, effective)) then
    validate_split_fit(effective)
  end
  local caller_win = vim.api.nvim_get_current_win()
  local previous_transition = instance._window_transition
  instance._window_transition = true
  local ok, result = pcall(open_prepared, instance, tabpage, layout, effective, selected, caller_win)
  instance._window_transition = previous_transition
  if not ok then error(result, 0) end
  return result
end

function M.hidden(instance)
  local windows = current_tab_windows(instance)
  for _, winid in ipairs(windows) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      local removed, err = remove_view(instance, winid)
      if not removed then error(err, 0) end
    end
  end
  M.sync_visibility(instance)
  return true
end

function M.toggle(instance, requested)
  local tabpage = vim.api.nvim_get_current_tabpage()
  -- Toggle validates even when it will hide, preserving the same atomic
  -- invalid-input contract as open().
  local layout = resolve(instance, requested, tabpage)
  local effective = M.materialize(layout)
  local selected = M.select(instance)
  if not selected then return M.open(instance, layout) end
  if M.same_layout(instance, selected, effective) then return M.hidden(instance) end
  return M.open(instance, layout)
end

return M
