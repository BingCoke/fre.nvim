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

local function place_initial_cursor(instance, winid)
  return require("fre.buffer").place_initial_cursor(instance, winid)
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

local function raw_named_metadata(winid, name)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return nil end
  local ok, value = pcall(vim.api.nvim_win_get_var, winid, name)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function raw_metadata(instance, winid)
  return raw_named_metadata(winid, metadata_name(instance))
end

local function get_metadata(instance, winid)
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return nil end
  local metadata = raw_metadata(instance, winid)
  if not metadata or metadata.bufnr ~= instance.bufnr then return nil end
  return metadata
end

local function set_metadata(instance, winid, layout, effective)
  local current = raw_metadata(instance, winid) or {}
  vim.api.nvim_win_set_var(winid, metadata_name(instance), {
    bufnr = instance.bufnr,
    layout = copy(layout),
    effective = copy(effective),
    previous_options = copy(current.previous_options or {}),
  })
end

local function set_option_metadata(instance, winid, previous_options, transfer)
  local current = raw_metadata(instance, winid)
  if not current or current.bufnr ~= instance.bufnr then
    current = {}
  else
    current = copy(current)
  end
  current.bufnr = instance.bufnr
  current.previous_options = copy(previous_options)
  current.option_transfer = transfer and copy(transfer) or nil
  vim.api.nvim_win_set_var(winid, metadata_name(instance), current)
end

local function clear_named_metadata(winid, name)
  vim.api.nvim_win_del_var(winid, name)
end

local function snapshot_named_metadata(winid, name)
  local ok, value = pcall(vim.api.nvim_win_get_var, winid, name)
  return { present = ok, value = ok and copy(value) or nil }
end

local function snapshot_metadata(instance, winid)
  return snapshot_named_metadata(winid, metadata_name(instance))
end

local function restore_named_metadata(winid, name, snapshot)
  if not vim.api.nvim_win_is_valid(winid) then return end
  if snapshot.present then
    pcall(vim.api.nvim_win_set_var, winid, name, copy(snapshot.value))
  else
    pcall(vim.api.nvim_win_del_var, winid, name)
  end
end

local function restore_metadata(instance, winid, snapshot)
  restore_named_metadata(winid, metadata_name(instance), snapshot)
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

local function apply_configured_window_options(instance, winid)
  for key, value in pairs(instance.config.window.options or {}) do
    vim.api.nvim_set_option_value(key, value, { scope = "local", win = winid })
  end
end

local function option_owner(_, winid)
  if not vim.api.nvim_win_is_valid(winid) then return nil end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local ok, identity = pcall(vim.api.nvim_buf_get_var, bufnr, "fre")
  if not ok or type(identity) ~= "table" or type(identity.instance_id) ~= "number" then
    return nil
  end
  local name = "fre_layout_" .. tostring(identity.instance_id)
  local metadata = raw_named_metadata(winid, name)
  if not metadata or metadata.bufnr ~= bufnr
      or type(metadata.previous_options) ~= "table" then return nil end
  return { bufnr = bufnr, name = name }, metadata
end

local function transferred_option_owner(instance, winid)
  local owner, owner_metadata
  local source_name = metadata_name(instance)
  local variables = vim.api.nvim_win_call(winid, function()
    return vim.fn.getwinvar(0, "")
  end)
  for name, metadata in pairs(variables) do
    local transfer = type(metadata) == "table" and metadata.option_transfer or nil
    if type(name) == "string" and name:match("^fre_layout_%d+$")
        and type(metadata) == "table" and metadata.bufnr ~= instance.bufnr
        and type(metadata.previous_options) == "table"
        and type(transfer) == "table"
        and transfer.source_bufnr == instance.bufnr
        and transfer.source_name == source_name
        and vim.api.nvim_buf_is_valid(metadata.bufnr) then
      local ok, identity = pcall(vim.api.nvim_buf_get_var, metadata.bufnr, "fre")
      local exact_name = ok and type(identity) == "table"
        and type(identity.instance_id) == "number"
        and name == "fre_layout_" .. tostring(identity.instance_id)
      if exact_name then
        if owner then fail("transferred option ownership is ambiguous", 3) end
        owner = { bufnr = metadata.bufnr, name = name }
        owner_metadata = metadata
      end
    end
  end
  return owner, owner_metadata
end

local function snapshot_window_options(instance, winid, previous_options)
  local names = {}
  for key in pairs(instance.config.window.options or {}) do names[key] = true end
  for key in pairs(previous_options or {}) do names[key] = true end
  local result = {}
  for key in pairs(names) do
    result[key] = vim.api.nvim_get_option_value(
      key, { scope = "local", win = winid }
    )
  end
  return result
end

local function inherited_options(winid)
  local _, metadata = option_owner(nil, winid)
  return metadata and copy(metadata.previous_options) or nil
end

function M.prepare(instance, winid, inherited_previous)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return false end
  local prepared = raw_metadata(instance, winid)
  if prepared and prepared.bufnr == instance.bufnr
      and type(prepared.previous_options) == "table" then return false end
  local owner, owner_metadata = option_owner(instance, winid)

  local previous_options = owner_metadata and copy(owner_metadata.previous_options)
    or copy(inherited_previous or {})
  local active_options = snapshot_window_options(instance, winid, previous_options)
  for key in pairs(instance.config.window.options or {}) do
    if previous_options[key] == nil then previous_options[key] = active_options[key] end
  end
  local target_name = metadata_name(instance)
  local target_metadata = snapshot_metadata(instance, winid)
  local owner_snapshot = owner and owner.name ~= target_name
    and snapshot_named_metadata(winid, owner.name) or nil
  local transfer = owner and owner.bufnr ~= instance.bufnr and {
    source_bufnr = owner.bufnr,
    source_name = owner.name,
  } or nil
  local ok, err = pcall(function()
    if owner and owner.name ~= target_name then clear_named_metadata(winid, owner.name) end
    set_option_metadata(instance, winid, previous_options, transfer)
  end)
  if not ok then
    restore_metadata(instance, winid, target_metadata)
    if owner_snapshot then restore_named_metadata(winid, owner.name, owner_snapshot) end
    error(err, 0)
  end
  return true
end

function M.activate(instance, winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    fail("target window is not valid for option activation", 2)
  end
  if vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then
    fail("target window does not display the instance buffer", 2)
  end
  local metadata = raw_metadata(instance, winid)
  if not metadata or metadata.bufnr ~= instance.bufnr
      or type(metadata.previous_options) ~= "table" then
    fail("target window option ownership was not prepared", 2)
  end

  local active_options = snapshot_window_options(instance, winid, metadata.previous_options)
  local ok, err = pcall(function()
    for key, value in pairs(metadata.previous_options) do
      vim.api.nvim_set_option_value(key, value, { scope = "local", win = winid })
    end
    apply_configured_window_options(instance, winid)
  end)
  if not ok then
    local rollback_errors = {}
    for key, value in pairs(active_options) do
      local restored, restore_err = pcall(vim.api.nvim_set_option_value, key, value, {
        scope = "local", win = winid,
      })
      if not restored then
        rollback_errors[#rollback_errors + 1] = key .. ": " .. tostring(restore_err)
      end
    end
    if #rollback_errors > 0 then
      error(tostring(err) .. "; option rollback failed: "
        .. table.concat(rollback_errors, "; "), 0)
    end
    error(err, 0)
  end
  return true
end

local function assert_installed_buffer(winid, bufnr)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    fail("target window was invalidated during buffer installation", 4)
  end
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    fail("target window redirected buffer during installation", 4)
  end
end

function M.release(instance, winid)
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return false end
  local name = metadata_name(instance)
  local metadata = raw_metadata(instance, winid)
  local clear_metadata = metadata and metadata.bufnr == instance.bufnr
    and type(metadata.previous_options) == "table"
  if not clear_metadata then
    local owner
    owner, metadata = transferred_option_owner(instance, winid)
    if not owner then return false end
    name = owner.name
  end

  local active_options = snapshot_window_options(instance, winid, metadata.previous_options)
  local metadata_snapshot = snapshot_named_metadata(winid, name)
  local ok, err = pcall(function()
    for key, value in pairs(metadata.previous_options) do
      vim.api.nvim_set_option_value(key, value, { scope = "local", win = winid })
    end
    if clear_metadata then
      clear_named_metadata(winid, name)
    else
      local retained = copy(metadata)
      retained.option_transfer = nil
      vim.api.nvim_win_set_var(winid, name, retained)
    end
  end)
  if not ok then
    local rollback_errors = {}
    for key, value in pairs(active_options) do
      local restored, restore_err = pcall(vim.api.nvim_set_option_value, key, value, {
        scope = "local", win = winid,
      })
      if not restored then
        rollback_errors[#rollback_errors + 1] = key .. ": " .. tostring(restore_err)
      end
    end
    if metadata_snapshot then
      local restored, restore_err = pcall(function()
        vim.api.nvim_win_set_var(winid, name, copy(metadata_snapshot.value))
      end)
      if not restored then
        rollback_errors[#rollback_errors + 1] = "ownership metadata: " .. tostring(restore_err)
      end
    end
    if #rollback_errors > 0 then
      error(tostring(err) .. "; release rollback failed: "
        .. table.concat(rollback_errors, "; "), 0)
    end
    error(err, 0)
  end
  return true
end

local function observe_visibility(instance)
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
  if instance.manager then instance.manager:gc_visibility_changed(instance) end
  return visible
end

function M.sync_visibility(instance)
  return observe_visibility(instance)
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
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  local owner, owner_metadata = option_owner(instance, winid)
  return {
    winid = winid,
    bufnr = bufnr,
    tabpage = tabpage,
    bufhidden = vim.api.nvim_get_option_value("bufhidden", { buf = bufnr }),
    view = save_view(winid),
    options = snapshot_window_options(
      instance, winid, owner_metadata and owner_metadata.previous_options
    ),
    metadata = snapshot_metadata(instance, winid),
    owner = owner and owner.bufnr ~= instance.bufnr
      and owner.name ~= metadata_name(instance) and owner or nil,
    owner_metadata = owner and owner.bufnr ~= instance.bufnr
      and owner.name ~= metadata_name(instance)
      and snapshot_named_metadata(winid, owner.name) or nil,
    focus = vim.api.nvim_get_current_win(),
    instance_state = instance.state,
    layout_history_present = instance._last_layout_by_tab ~= nil,
    layout_history = instance._last_layout_by_tab and copy(instance._last_layout_by_tab) or nil,
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
  local errors = {}
  local function attempt(label, callback)
    local ok, err = pcall(callback)
    if not ok then errors[#errors + 1] = label .. ": " .. tostring(err) end
    return ok
  end
  local function restore_snapshot_metadata(name, metadata_snapshot)
    if metadata_snapshot.present then
      vim.api.nvim_win_set_var(snapshot.winid, name, copy(metadata_snapshot.value))
    elseif pcall(vim.api.nvim_win_get_var, snapshot.winid, name) then
      vim.api.nvim_win_del_var(snapshot.winid, name)
    end
  end

  local winid = snapshot.winid
  local exact_source = false
  if vim.api.nvim_win_is_valid(winid) then
    attempt("ownership metadata rollback failed", function()
      restore_snapshot_metadata(metadata_name(instance), snapshot.metadata)
    end)
    if snapshot.owner and snapshot.owner_metadata then
      attempt("displaced ownership metadata rollback failed", function()
        restore_snapshot_metadata(snapshot.owner.name, snapshot.owner_metadata)
      end)
    end

    if not vim.api.nvim_buf_is_valid(snapshot.bufnr) then
      errors[#errors + 1] = "source buffer rollback failed: snapshot buffer is invalid"
    else
      local current_ok, current = pcall(vim.api.nvim_win_get_buf, winid)
      if not current_ok then
        errors[#errors + 1] = "source buffer rollback failed: " .. tostring(current)
      elseif current ~= snapshot.bufnr then
        attempt("source buffer rollback failed", function()
          vim.api.nvim_win_set_buf(winid, snapshot.bufnr)
        end)
      end
      local restored_ok, restored = pcall(vim.api.nvim_win_get_buf, winid)
      if vim.api.nvim_win_is_valid(winid)
          and (not restored_ok or restored ~= snapshot.bufnr) then
        attempt("noautocmd source buffer fallback failed", function()
          vim.api.nvim_win_call(winid, function()
            vim.cmd("noautocmd buffer " .. tostring(snapshot.bufnr))
          end)
        end)
      end
      restored_ok, restored = pcall(vim.api.nvim_win_get_buf, winid)
      exact_source = vim.api.nvim_win_is_valid(winid)
        and restored_ok and restored == snapshot.bufnr
      if not exact_source then
        errors[#errors + 1] = "source buffer rollback failed: target window does not display "
          .. "snapshot buffer after noautocmd fallback"
      end
    end

    if exact_source then
      for key, value in pairs(snapshot.options or {}) do
        attempt("source option rollback failed for " .. key, function()
          vim.api.nvim_set_option_value(key, value, { scope = "local", win = winid })
        end)
      end
    end
    if exact_source then
      if snapshot.protected and vim.api.nvim_buf_is_valid(snapshot.bufnr) then
        if attempt("source protection rollback failed", function()
          vim.api.nvim_set_option_value(
            "bufhidden", snapshot.bufhidden, { buf = snapshot.bufnr }
          )
        end) then
          snapshot.protected = nil
        end
      end
      restore_view(winid, snapshot.view)
      if snapshot.layout_history_present then
        instance._last_layout_by_tab = copy(snapshot.layout_history)
      else
        instance._last_layout_by_tab = nil
      end
      instance.state = snapshot.instance_state
      if vim.api.nvim_win_is_valid(snapshot.focus) then
        attempt("focus rollback failed", function()
          vim.api.nvim_set_current_win(snapshot.focus)
        end)
      end
    end
  else
    errors[#errors + 1] = "source window rollback failed: target window is invalid"
  end
  if #errors > 0 then error(table.concat(errors, "; "), 0) end
end

local function transition_error(instance, snapshot, err)
  local restored, restore_err = pcall(restore_destination, instance, snapshot)
  if not restored then
    return tostring(err) .. "; rollback failed: " .. tostring(restore_err)
  end
  return err
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
  local snapshot
  local ok, err = pcall(function()
    if is_float(winid) then
      vim.api.nvim_win_close(winid, true)
      return
    end
    local tabpage = vim.api.nvim_win_get_tabpage(winid)
    if preserve_normal or #normal_windows(tabpage) == 1 then
      scratch = scratch_buffer()
      snapshot = snapshot_destination(instance, winid)
      M.release(instance, winid)
      vim.api.nvim_win_set_buf(winid, scratch)
    else
      vim.api.nvim_win_close(winid, true)
    end
  end)
  local removed = not vim.api.nvim_win_is_valid(winid)
    or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr
  if removed then return true end
  local remove_err = ok and "failed to remove selected Fre view" or err
  if snapshot then remove_err = transition_error(instance, snapshot, remove_err) end
  if scratch and vim.api.nvim_buf_is_valid(scratch) and #vim.fn.win_findbuf(scratch) == 0 then
    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end
  return false, remove_err
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
  vim.api.nvim_set_option_value(option, value, { scope = "local", win = winid })
end

local function create_split(layout, effective, preferred, noautocmd)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local anchor = assert(split_anchor(tabpage, preferred), "current tab has no ordinary window")
  local previous_options = inherited_options(anchor)
  vim.api.nvim_set_current_win(anchor)
  local commands = {
    left = "topleft vertical split",
    right = "botright vertical split",
    top = "topleft split",
    bottom = "botright split",
  }
  local command = commands[layout.position]
  vim.cmd(noautocmd and ("noautocmd " .. command) or command)
  local winid = vim.api.nvim_get_current_win()
  resize_split(winid, layout, effective.size)
  return winid, previous_options
end

local function build_split_buffer(bufnr, layout, effective, preferred)
  local winid, previous_options = create_split(layout, effective, preferred, true)
  for key, value in pairs(previous_options or {}) do
    vim.api.nvim_set_option_value(key, value, { scope = "local", win = winid })
  end
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

local function build_float(layout, effective, scratch)
  local config = {
    relative = "editor",
    style = "minimal",
    width = effective.width,
    height = effective.height,
    row = effective.row,
    col = effective.col,
  }
  if layout.border ~= nil then config.border = copy(layout.border) end
  return vim.api.nvim_open_win(scratch, true, config)
end

local function build_current(preferred)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local winid = preferred
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_tabpage(winid) ~= tabpage then
    winid = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(winid)
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
  local previous_transition = instance._window_transition
  instance._window_transition = true
  local ok, err = pcall(function()
    protect_destination_buffer(instance, snapshot)
    M.prepare(instance, winid)
    vim.api.nvim_win_set_buf(winid, instance.bufnr)
    assert_installed_buffer(winid, instance.bufnr)
    M.activate(instance, winid)
    restore_destination_buffer(snapshot)
    if not is_float(winid) then
      local current = { position = "current" }
      set_metadata(instance, winid, current, current)
      instance._last_layout_by_tab = instance._last_layout_by_tab or {}
      instance._last_layout_by_tab[snapshot.tabpage] = current
    end
    M.sync_visibility(instance)
  end)
  instance._window_transition = previous_transition
  if not ok then
    err = transition_error(instance, snapshot, err)
    pcall(observe_visibility, instance)
    error(err, 0)
  end
  if snapshot.bufnr ~= instance.bufnr then place_initial_cursor(instance, winid) end
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
    M.release(instance, winid)
    vim.api.nvim_win_set_buf(winid, bufnr)
    assert_installed_buffer(winid, bufnr)
    restore_destination_buffer(snapshot)
  end)
  if not ok then
    err = transition_error(instance, snapshot, err)
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
  local newly_presented = false
  if selected and M.same_layout(instance, selected, effective) then
    local ok, result = pcall(function()
      vim.api.nvim_set_current_win(selected)
      M.prepare(instance, selected)
      M.activate(instance, selected)
    end)
    if not ok then
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
      winid = build_current(destination)
      M.prepare(instance, winid)
      vim.api.nvim_win_set_buf(winid, instance.bufnr)
      assert_installed_buffer(winid, instance.bufnr)
      M.activate(instance, winid)
      newly_presented = snapshot.bufnr ~= instance.bufnr
      restore_destination_buffer(snapshot)
      restore_view(winid, saved)
      set_metadata(instance, winid, layout, effective)
    end)
    if not ok then
      error(transition_error(instance, snapshot, result), 0)
    end
    if selected and selected ~= winid then
      local preserve = not is_float(selected) and #normal_windows(tabpage) == 1
      local removed, remove_err = remove_view(instance, selected, preserve)
      if not removed then
        error(transition_error(instance, snapshot, remove_err), 0)
      end
    end
  else
    local before = snapshot_windows(tabpage)
    local preserve_normal = selected and not is_float(selected)
      and #normal_windows(tabpage) == 1
    local fix_option, fixed_before
    local scratch
    local ok, result = pcall(function()
      if layout.position == "float" then
        scratch = scratch_buffer()
        winid = build_float(layout, effective, scratch)
        M.prepare(instance, winid)
      else
        local previous_options
        winid, previous_options = create_split(layout, effective, caller_win, true)
        M.prepare(instance, winid, previous_options)
      end
      vim.api.nvim_win_set_buf(winid, instance.bufnr)
      assert_installed_buffer(winid, instance.bufnr)
      M.activate(instance, winid)
      if scratch and vim.api.nvim_buf_is_valid(scratch)
          and #vim.fn.win_findbuf(scratch) == 0 then
        vim.api.nvim_buf_delete(scratch, { force = true })
      end
      newly_presented = true
      restore_view(winid, saved)
      set_metadata(instance, winid, layout, effective)
      if layout.position ~= "float" and split_size(winid, layout) ~= effective.size then
        fail("layout.size could not be materialized exactly", 4)
      end
      if selected and layout.position ~= "float" and not is_float(selected) then
        fix_option = split_fix_option(layout)
        fixed_before = vim.api.nvim_get_option_value(
          fix_option, { scope = "local", win = winid }
        )
        set_split_fixed(winid, fix_option, true)
      end
    end)
    if not ok then
      rollback_created_windows(tabpage, before, caller_win)
      if scratch and vim.api.nvim_buf_is_valid(scratch)
          and #vim.fn.win_findbuf(scratch) == 0 then
        pcall(vim.api.nvim_buf_delete, scratch, { force = true })
      end
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
    if fix_option then pcall(set_split_fixed, winid, fix_option, fixed_before) end
  end
  if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_get_current_win() ~= winid then
    pcall(vim.api.nvim_set_current_win, winid)
  end
  if newly_presented then place_initial_cursor(instance, winid) end
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
