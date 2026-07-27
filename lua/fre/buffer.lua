local columns = require("fre.columns")
local path = require("fre.path")
local window = require("fre.window")

local M = {}

local unit_separator = string.char(31)
local marker_prefix = unit_separator .. "fre:"
local navigation_marker_prefix = unit_separator .. "fre-nav:"
local max_exact_integer = 9007199254740991
local row_namespace = vim.api.nvim_create_namespace("fre-row-identity")
local highlight_namespace = vim.api.nvim_create_namespace("fre-column-highlights")

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function fail_row(row, message, level)
  fail("row " .. tostring(row) .. ": " .. message, level or 4)
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
    and value <= max_exact_integer
end

local function encode_base36(value)
  if not positive_integer(value) then fail("stable IDs must be positive integers", 4) end
  local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  local result = {}
  repeat
    local digit = value % 36
    result[#result + 1] = digits:sub(digit + 1, digit + 1)
    value = math.floor(value / 36)
  until value == 0
  local encoded = {}
  for index = #result, 1, -1 do encoded[#encoded + 1] = result[index] end
  return table.concat(encoded)
end

local function decode_base36(value, row, label)
  if value == "" or value:find("[^0-9a-z]") or (#value > 1 and value:sub(1, 1) == "0") then
    fail_row(row, "invalid " .. label .. " base36 ID")
  end
  local result = 0
  for index = 1, #value do
    local byte = value:byte(index)
    local digit = byte >= 48 and byte <= 57 and byte - 48 or byte - 87
    if result > math.floor((max_exact_integer - digit) / 36) then
      fail_row(row, label .. " ID is too large")
    end
    result = result * 36 + digit
  end
  if not positive_integer(result) or encode_base36(result) ~= value then
    fail_row(row, "invalid " .. label .. " base36 ID")
  end
  return result
end

local function trim_range(text, offset)
  local trimmed = vim.trim(text)
  if trimmed == "" then
    local boundary = offset + #text
    return trimmed, { start_byte = boundary, end_byte = boundary }
  end
  local leading = #(text:match("^%s*") or "")
  local trailing = #(text:match("%s*$") or "")
  return trimmed, {
    start_byte = offset + leading,
    end_byte = offset + #text - trailing,
  }
end

local function get_line(instance, row)
  if type(row) ~= "number" or row % 1 ~= 0 then fail("row must be a 1-based integer", 4) end
  if row < 1 or not vim.api.nvim_buf_is_valid(instance.bufnr) then return nil end
  local count = vim.api.nvim_buf_line_count(instance.bufnr)
  if row > count then return nil end
  return vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1]
end

local function set_node_extmark(instance, node, row)
  if node.row_extmark then
    pcall(vim.api.nvim_buf_del_extmark, instance.bufnr, row_namespace, node.row_extmark)
  end
  node.row_extmark = vim.api.nvim_buf_set_extmark(instance.bufnr, row_namespace, row - 1, 0, {
    right_gravity = true,
  })
end

local function clamp_cursor(instance, winid)
  winid = winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row = cursor[1]
  local ok, decoded = pcall(M.decode, instance, row, { allow_empty_path = true })
  if not ok or not decoded or not decoded.marked then return end
  local lower = decoded.path_range.start_byte
  local upper = math.max(lower, decoded.path_range.end_byte)
  local col = math.max(lower, math.min(cursor[2], upper))
  if cursor[2] ~= col then vim.api.nvim_win_set_cursor(winid, { row, col }) end
end

local function navigation_context(ctx, navigation_kind)
  ctx.synthetic = true
  ctx.navigation_kind = navigation_kind
  ctx.metadata = {
    kind = "directory",
    mode = nil,
    size = nil,
    mtime = nil,
  }
  return ctx
end

local function navigation_callback_entry(source, node, navigation_kind)
  local entry = source:_entry(node)
  local label = navigation_kind == "parent" and ".." or "/"
  entry.absolute_path = navigation_kind == "parent"
    and path.parent(source.root) or source.root
  entry.relative_path = label
  entry.name = label
  return entry
end

local function parse_columns(row, source, node, suffix, marker_end, navigation_kind)
  local descriptors = source.config.columns or {}
  local values, ranges, separators, fields = {}, {}, {}, {}
  local consumed = 0
  for index, descriptor in ipairs(descriptors) do
    local unconsumed = suffix:sub(consumed + 1)
    local callback_entry = navigation_kind
      and navigation_callback_entry(source, node, navigation_kind)
      or source:_entry(node)
    local ctx = source:_column_context(
      node, callback_entry, descriptor, index, index == #descriptors
    )
    if navigation_kind then ctx = navigation_context(ctx, navigation_kind) end
    local ok, value, remaining = pcall(descriptor.parse, unconsumed, ctx)
    if not ok then
      fail_row(row, "column " .. descriptor.id .. " parser failed: " .. tostring(value))
    end
    if value == nil then fail_row(row, "column " .. descriptor.id .. " parser returned no value") end
    if type(remaining) ~= "string" then
      fail_row(row, "column " .. descriptor.id .. " parser must return a suffix string")
    end
    if #remaining >= #unconsumed then
      fail_row(row, "column " .. descriptor.id .. " parser made no progress")
    end
    local amount = #unconsumed - #remaining
    if unconsumed:sub(amount + 1) ~= remaining then
      fail_row(row, "column " .. descriptor.id .. " parser returned a non-literal suffix")
    end
    local consumed_text = unconsumed:sub(1, amount)
    local separator = consumed_text:match("( +)$")
    if not separator then
      fail_row(row, "column " .. descriptor.id .. " parser did not consume its separator")
    end
    local start_byte = marker_end + consumed
    local end_byte = start_byte + amount
    ranges[index] = { start_byte = start_byte, end_byte = end_byte }
    separators[index] = {
      start_byte = end_byte - #separator,
      end_byte = end_byte,
    }
    fields[index] = {
      id = descriptor.id,
      value = value,
      range = { start_byte = start_byte, end_byte = end_byte },
      separator_range = {
        start_byte = end_byte - #separator,
        end_byte = end_byte,
      },
    }
    values[index] = value
    values[descriptor.id] = value
    local equals_ok, equal = pcall(descriptor.equals, callback_entry, value, ctx)
    if not equals_ok then
      fail_row(row, "column " .. descriptor.id .. " equals callback failed: " .. tostring(equal))
    end
    if not equal then fail_row(row, "column " .. descriptor.id .. " metadata changed") end
    consumed = consumed + amount
  end
  return values, ranges, separators, fields, suffix:sub(consumed + 1), marker_end + consumed
end

function M.marker(instance_id, node_id)
  return marker_prefix .. encode_base36(instance_id) .. ":" .. encode_base36(node_id)
    .. unit_separator
end

function M.navigation_marker(instance_id, navigation_kind)
  if navigation_kind ~= "parent" and navigation_kind ~= "root" then
    fail("navigation marker kind must be parent or root", 3)
  end
  return navigation_marker_prefix .. encode_base36(instance_id) .. ":"
    .. navigation_kind .. unit_separator
end

local function marker_source(instance, instance_id, row)
  if instance_id == instance.id then return instance end
  local source = instance.manager:find_by_id(instance_id)
  if not source then
    fail_row(row, "marker references unknown instance " .. tostring(instance_id))
  end
  if source._destroyed or source.state == "destroying" or source.state == "destroyed" then
    fail_row(row, "marker references destroyed instance " .. tostring(instance_id))
  end
  return source
end

local function decode_line(instance, row, line, opts)
  opts = opts or {}
  if line == nil then return nil end

  if line:sub(1, 1) ~= unit_separator then
    local proposed_path, path_range = trim_range(line, 0)
    return {
      kind = "new", row_kind = "new", marked = false, line = line,
      proposed_path = proposed_path, path = proposed_path,
      marker_range = nil, column_ranges = {}, separator_ranges = {}, fields = {},
      path_range = path_range, visible_range = path_range,
    }
  end

  local nav_instance_text, navigation_kind, nav_suffix_index = line:match(
    "^" .. unit_separator .. "fre%-nav:([0-9a-z]+):([a-z]+)"
      .. unit_separator .. "()"
  )
  if nav_suffix_index then
    if navigation_kind ~= "parent" and navigation_kind ~= "root" then
      fail_row(row, "invalid navigation marker kind " .. tostring(navigation_kind))
    end
    local instance_id = decode_base36(nav_instance_text, row, "instance")
    local marker_end = nav_suffix_index - 1
    local marker = line:sub(1, marker_end)
    if marker ~= M.navigation_marker(instance_id, navigation_kind) then
      fail_row(row, "non-canonical navigation marker")
    end
    local source = marker_source(instance, instance_id, row)
    local node = source.root_node
    if not node then fail_row(row, "navigation marker references an invalid instance") end
    local suffix = line:sub(nav_suffix_index)
    local values, column_ranges, separator_ranges, fields, path_suffix, path_offset =
      parse_columns(row, source, node, suffix, marker_end, navigation_kind)
    local proposed_path, path_range = trim_range(path_suffix, path_offset)
    return {
      kind = "navigation", row_kind = "navigation",
      marked = true, synthetic = true, line = line, marker = marker,
      instance_id = instance_id, source_instance_id = instance_id,
      source_instance = source, source_node = nil,
      foreign = source ~= instance, entry = nil, navigation_kind = navigation_kind,
      proposed_path = proposed_path, path = proposed_path,
      marker_range = { start_byte = 0, end_byte = marker_end },
      column_values = values, column_ranges = column_ranges,
      separator_ranges = separator_ranges, fields = fields,
      path_range = path_range,
      visible_range = { start_byte = marker_end, end_byte = path_range.end_byte },
    }
  end

  local instance_text, node_text, suffix_index = line:match(
    "^" .. unit_separator .. "fre:([0-9a-z]+):([0-9a-z]+)" .. unit_separator .. "()"
  )
  if not suffix_index then fail_row(row, "malformed reserved row marker") end

  local instance_id = decode_base36(instance_text, row, "instance")
  local node_id = decode_base36(node_text, row, "node")
  local marker_end = suffix_index - 1
  local marker = line:sub(1, marker_end)
  if marker ~= M.marker(instance_id, node_id) then fail_row(row, "non-canonical row marker") end
  local source = marker_source(instance, instance_id, row)

  local node = source.nodes_by_id[node_id]
  if not node then
    if source == instance then
      fail_row(row, "marker references unknown local node " .. tostring(node_id))
    end
    fail_row(row, "marker references unknown node " .. tostring(node_id)
      .. " in instance " .. tostring(instance_id))
  end
  if source ~= instance and (node.id ~= node_id or type(node.path) ~= "string"
      or type(source.nodes_by_path) ~= "table" or source.nodes_by_path[node.path] ~= node) then
    fail_row(row, "marker references invalid node " .. tostring(node_id)
      .. " in instance " .. tostring(instance_id))
  end

  local entry
  if source == instance then
    entry = source:_entry(node)
  else
    local entry_ok, entry_or_error = pcall(source._entry, source, node)
    if not entry_ok then
      fail_row(row, "marker references invalid node " .. tostring(node_id)
        .. " in instance " .. tostring(instance_id) .. ": " .. tostring(entry_or_error))
    end
    entry = entry_or_error
  end
  local suffix = line:sub(suffix_index)
  local values, column_ranges, separator_ranges, fields, path_suffix, path_offset =
    parse_columns(row, source, node, suffix, marker_end)
  local proposed_path, path_range = trim_range(path_suffix, path_offset)
  local has_trailing_slash = proposed_path:sub(-1) == "/"
  if node.kind == "directory" and not has_trailing_slash
      and not (opts.allow_empty_path and proposed_path == "") then
    fail_row(row, "directory path must end in /")
  end
  if node.kind ~= "directory" and has_trailing_slash then
    fail_row(row, node.kind .. " path must not end in /")
  end
  return {
    kind = "existing", row_kind = "entry", marked = true, line = line, marker = marker,
    instance_id = instance_id, source_instance_id = instance_id, node_id = node_id,
    source_instance = source, source_node = node, foreign = source ~= instance,
    entry = entry,
    proposed_path = proposed_path, path = proposed_path,
    marker_range = { start_byte = 0, end_byte = marker_end },
    column_values = values, column_ranges = column_ranges,
    separator_ranges = separator_ranges, fields = fields,
    path_range = path_range,
    visible_range = { start_byte = marker_end, end_byte = path_range.end_byte },
  }
end

function M.decode(instance, row, opts)
  return decode_line(instance, row, get_line(instance, row), opts)
end

function M.row_has_marker(instance, row, marker)
  local line = get_line(instance, row)
  return line ~= nil and line:sub(1, #marker) == marker
end

function M.find_marker_rows(instance, marker)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return {} end
  local result = {}
  local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:sub(1, #marker) == marker then result[#result + 1] = index end
  end
  return result
end

function M.rebind(instance, node, row) set_node_extmark(instance, node, row) end

function M.hint_row(instance, node)
  if not node.row_extmark or not vim.api.nvim_buf_is_valid(instance.bufnr) then return nil end
  local position = vim.api.nvim_buf_get_extmark_by_id(
    instance.bufnr, row_namespace, node.row_extmark, {}
  )
  if #position == 0 then return nil end
  return position[1] + 1
end

local function aligned(text, width, actual, align)
  local padding = width - actual
  if align == "right" then return string.rep(" ", padding) .. text, padding end
  if align == "center" then
    local left = math.floor(padding / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", padding - left), left
  end
  return text .. string.rep(" ", padding), 0
end

local function same_widths(left, right)
  if not left or not right or #left ~= #right then return false end
  for index = 1, #left do
    if left[index] ~= right[index] then return false end
  end
  return true
end

function M.prepare(instance, projection, render_path, opts)
  opts = opts or {}
  render_path = render_path or function(node)
    return node.kind == "directory" and node.name .. "/" or node.name
  end
  local nodes = projection.nodes or projection
  local descriptors = instance.config.columns or {}
  local rendered, widths = {}, {}
  for index = 1, #descriptors do widths[index] = 1 end

  local function add_rendered(node, rendered_path, navigation_kind)
    local fields = {}
    for index, descriptor in ipairs(descriptors) do
      local entry = navigation_kind
        and navigation_callback_entry(instance, node, navigation_kind)
        or instance:_entry(node)
      local ctx = instance:_column_context(node, entry, descriptor, index, index == #descriptors)
      if navigation_kind then ctx = navigation_context(ctx, navigation_kind) end
      local text, highlight, width = columns.render_text(descriptor, entry, ctx)
      fields[index] = { text = text, highlight = highlight, width = width }
      widths[index] = math.max(widths[index], width)
    end
    rendered[#rendered + 1] = {
      node = node,
      fields = fields,
      path = rendered_path,
      synthetic = navigation_kind ~= nil,
      navigation_kind = navigation_kind,
    }
  end

  local navigation_kind = path.parent(instance.root) and "parent" or "root"
  add_rendered(instance.root_node, navigation_kind == "parent" and "../" or "/", navigation_kind)
  for _, node in ipairs(nodes) do add_rendered(node, render_path(node), nil) end

  local lines = {}
  local baseline = {}
  local highlights = {}
  local highlight_templates = {}
  local navigation_highlight_templates = {}
  for row, item in ipairs(rendered) do
    local marker = item.synthetic
      and M.navigation_marker(instance.id, item.navigation_kind)
      or M.marker(instance.id, item.node.id)
    local physical = {}
    local templates = {}
    local offset = #marker
    for index, field in ipairs(item.fields) do
      local text, left = aligned(
        field.text, widths[index], field.width, descriptors[index].align
      )
      physical[index] = text
      if field.highlight and #field.text > 0 then
        local start_col = offset + left
        highlights[#highlights + 1] = {
          row = row - 1,
          start_col = start_col,
          end_col = start_col + #field.text,
          hl_group = field.highlight,
        }
        templates[#templates + 1] = {
          start_col = start_col,
          end_col = start_col + #field.text,
          text = field.text,
          hl_group = field.highlight,
        }
      end
      offset = offset + #text + 1
    end
    if item.synthetic then
      navigation_highlight_templates = templates
    elseif #templates > 0 then
      highlight_templates[item.node.id] = templates
    end
    local suffix = item.path
    if #physical > 0 then suffix = table.concat(physical, " ") .. " " .. suffix end
    lines[row] = marker .. suffix
    if not item.synthetic then baseline[item.node.id] = item.node.path end
  end

  if opts.validate then
    local navigation = decode_line(instance, 1, lines[1])
    if not navigation.synthetic or navigation.navigation_kind ~= navigation_kind
        or navigation.proposed_path ~= (navigation_kind == "parent" and "../" or "/") then
      fail_row(1, "rendered navigation row failed semantic validation")
    end
    for index, node in ipairs(nodes) do
      local row = index + 1
      local decoded = decode_line(instance, row, lines[row])
      if not decoded.marked or decoded.synthetic or decoded.node_id ~= node.id
          or decoded.proposed_path ~= render_path(node) then
        fail_row(row, "rendered projection failed semantic validation")
      end
    end
  end

  return {
    lines = lines,
    baseline = baseline,
    column_widths = widths,
    highlights = highlights,
    highlight_templates = highlight_templates,
    navigation_highlight_templates = navigation_highlight_templates,
    projection = projection.nodes and projection or { nodes = nodes },
    visible_nodes = nodes,
    row_offset = 1,
  }
end

local function capture_windows(instance)
  local windows = {}
  for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      local view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
      local cursor = vim.api.nvim_win_get_cursor(winid)
      local line = get_line(instance, cursor[1]) or ""
      local instance_text, node_text = line:match(
        "^" .. unit_separator .. "fre:([0-9a-z]+):([0-9a-z]+)" .. unit_separator
      )
      local node_id
      if instance_text and tonumber(instance_text, 36) == instance.id then
        node_id = tonumber(node_text, 36)
      end
      windows[winid] = { view = view, cursor = cursor, node_id = node_id }
    end
  end
  return windows
end

local function restore_windows(instance, windows, rows_by_id, exact, clamp_path)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return end
  local count = vim.api.nvim_buf_line_count(instance.bufnr)
  for winid, saved in pairs(windows or {}) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      local row = saved.cursor[1]
      if not exact and saved.node_id and rows_by_id[saved.node_id] then
        row = rows_by_id[saved.node_id]
      end
      row = math.max(1, math.min(row, count))
      local line = vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1] or ""
      local col = math.max(0, math.min(saved.cursor[2], #line))
      local view = vim.deepcopy(saved.view)
      local delta = row - saved.cursor[1]
      view.lnum = row
      view.col = col
      if not exact then view.topline = (view.topline or 1) + delta end
      view.topline = math.max(1, math.min(view.topline or 1, count))
      pcall(vim.api.nvim_win_call, winid, vim.fn.winrestview, view)
      pcall(vim.api.nvim_win_set_cursor, winid, { row, col })
      if clamp_path then clamp_cursor(instance, winid) end
    end
  end
end

function M.snapshot(instance)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return nil end
  local node_extmarks = {}
  for _, node in pairs(instance.nodes_by_id or {}) do
    node_extmarks[node] = node.row_extmark
  end
  return {
    lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false),
    modified = vim.bo[instance.bufnr].modified,
    modifiable = vim.bo[instance.bufnr].modifiable,
    extmarks = vim.api.nvim_buf_get_extmarks(
      instance.bufnr, row_namespace, 0, -1, { details = true }
    ),
    highlights = vim.api.nvim_buf_get_extmarks(
      instance.bufnr, highlight_namespace, 0, -1, { details = true }
    ),
    node_extmarks = node_extmarks,
    windows = capture_windows(instance),
  }
end

function M.restore(instance, snapshot)
  if not snapshot or not vim.api.nvim_buf_is_valid(instance.bufnr) then return false end
  local current_modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, snapshot.lines)
  vim.api.nvim_buf_clear_namespace(instance.bufnr, row_namespace, 0, -1)
  for _, node in pairs(instance.nodes_by_id or {}) do node.row_extmark = nil end
  for _, mark in ipairs(snapshot.extmarks) do
    local details = mark[4] or {}
    vim.api.nvim_buf_set_extmark(instance.bufnr, row_namespace, mark[2], mark[3], {
      id = mark[1],
      right_gravity = details.right_gravity ~= false,
    })
  end
  vim.api.nvim_buf_clear_namespace(instance.bufnr, highlight_namespace, 0, -1)
  for _, mark in ipairs(snapshot.highlights or {}) do
    local details = mark[4] or {}
    vim.api.nvim_buf_set_extmark(instance.bufnr, highlight_namespace, mark[2], mark[3], {
      end_row = details.end_row,
      end_col = details.end_col,
      hl_group = details.hl_group,
      priority = details.priority,
      undo_restore = false,
    })
  end
  for node, mark in pairs(snapshot.node_extmarks) do node.row_extmark = mark end
  vim.bo[instance.bufnr].modified = snapshot.modified
  vim.bo[instance.bufnr].modifiable = snapshot.modifiable
  restore_windows(instance, snapshot.windows, nil, true, true)
  if current_modifiable ~= snapshot.modifiable then
    vim.bo[instance.bufnr].modifiable = snapshot.modifiable
  end
  return true
end

function M.commit(instance, prepared)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return false end
  local snapshot = M.snapshot(instance)
  local previous_view = instance.view or {}
  local old_nodes = {}
  for _, node in pairs(instance.nodes_by_id or {}) do old_nodes[#old_nodes + 1] = node end
  local ok, result = pcall(function()
    local previous_widths = previous_view.column_widths
    local current = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
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
        if not instance:_replace_lines(prefix, #current - suffix, replacement) then return false end
        patch = {
          kind = "interval", start_row = prefix + 1,
          old_end_row = #current - suffix, new_end_row = #prepared.lines - suffix,
        }
      end
    else
      if not instance:_set_lines(prepared.lines) then return false end
      patch = { kind = "full", start_row = 1, old_end_row = -1, new_end_row = #prepared.lines }
    end

    vim.api.nvim_buf_clear_namespace(instance.bufnr, row_namespace, 0, -1)
    for _, node in ipairs(old_nodes) do node.row_extmark = nil end
    local rows_by_id = {}
    local row_offset = prepared.row_offset or 0
    for row, node in ipairs(prepared.visible_nodes) do
      local buffer_row = row + row_offset
      set_node_extmark(instance, node, buffer_row)
      rows_by_id[node.id] = buffer_row
    end
    vim.api.nvim_buf_clear_namespace(instance.bufnr, highlight_namespace, 0, -1)
    for _, highlight in ipairs(prepared.highlights or {}) do
      vim.api.nvim_buf_set_extmark(
        instance.bufnr, highlight_namespace, highlight.row, highlight.start_col, {
          end_col = highlight.end_col,
          hl_group = highlight.hl_group,
          priority = 100,
          undo_restore = false,
        }
      )
    end
    instance.view = {
      baseline = prepared.baseline,
      column_widths = prepared.column_widths,
      highlight_templates = prepared.highlight_templates,
      navigation_highlight_templates = prepared.navigation_highlight_templates,
      projection = prepared.projection,
      visible_nodes = prepared.visible_nodes,
      row_offset = prepared.row_offset,
      last_patch = patch,
      projection_generation = (previous_view.projection_generation or 0) + 1,
    }
    vim.bo[instance.bufnr].modified = false
    restore_windows(instance, snapshot.windows, rows_by_id, false, true)
    return true
  end)
  if not ok or result == false then
    local restore_ok, restore_err = pcall(M.restore, instance, snapshot)
    instance.view = previous_view
    if not restore_ok then
      error(tostring(result) .. "; rollback failed: " .. tostring(restore_err), 0)
    end
    if not ok then error(result, 0) end
    return false
  end
  return true
end

function M.project(instance, projection, render_path)
  local prepared = M.prepare(instance, projection, render_path)
  return M.commit(instance, prepared)
end

function M.apply_window_options(instance)
  window.apply_all(instance)
end

local function row_highlight_templates(instance, line)
  local nav_instance_text, navigation_kind = line:match(
    "^" .. unit_separator .. "fre%-nav:([0-9a-z]+):([a-z]+)" .. unit_separator
  )
  if nav_instance_text then
    if navigation_kind ~= "parent" and navigation_kind ~= "root" then return nil end
    local instance_id = tonumber(nav_instance_text, 36)
    if not positive_integer(instance_id) then return nil end
    local source = instance_id == instance.id and instance
      or instance.manager:find_by_id(instance_id)
    if not source or source._destroyed then return nil end
    local marker = M.navigation_marker(instance_id, navigation_kind)
    if line:sub(1, #marker) ~= marker then return nil end
    return source.view and source.view.navigation_highlight_templates or nil
  end

  local instance_text, node_text = line:match(
    "^" .. unit_separator .. "fre:([0-9a-z]+):([0-9a-z]+)" .. unit_separator
  )
  if not instance_text then return nil end
  local instance_id = tonumber(instance_text, 36)
  local node_id = tonumber(node_text, 36)
  if not positive_integer(instance_id) or not positive_integer(node_id) then return nil end
  local source = instance_id == instance.id and instance
    or instance.manager:find_by_id(instance_id)
  if not source or source._destroyed or not source.nodes_by_id
      or not source.nodes_by_id[node_id] then
    return nil
  end
  local marker = M.marker(instance_id, node_id)
  if line:sub(1, #marker) ~= marker then return nil end
  local templates = source.view and source.view.highlight_templates
  return templates and templates[node_id] or nil
end

local function redecorate_rows(instance, first_row, last_row)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) or last_row < first_row then return end
  local count = vim.api.nvim_buf_line_count(instance.bufnr)
  first_row = math.max(1, first_row)
  last_row = math.min(count, last_row)
  if last_row < first_row then return end
  vim.api.nvim_buf_clear_namespace(
    instance.bufnr, highlight_namespace, first_row - 1, last_row
  )
  local lines = vim.api.nvim_buf_get_lines(
    instance.bufnr, first_row - 1, last_row, false
  )
  for offset, line in ipairs(lines) do
    local templates = row_highlight_templates(instance, line)
    for _, template in ipairs(templates or {}) do
      if line:sub(template.start_col + 1, template.end_col) == template.text then
        vim.api.nvim_buf_set_extmark(
          instance.bufnr, highlight_namespace, first_row + offset - 2,
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

local function apply_pending_highlight_update(instance)
  instance._highlight_update_scheduled = false
  local pending = instance._highlight_pending
  instance._highlight_pending = nil
  if not pending or instance._highlight_disabled or instance._destroyed
      or instance.state == "destroying" or instance.state == "destroyed"
      or not vim.api.nvim_buf_is_valid(instance.bufnr) then
    return
  end

  local ok, err = pcall(function()
    if pending.full then
      vim.api.nvim_buf_clear_namespace(instance.bufnr, highlight_namespace, 0, -1)
      redecorate_rows(
        instance, 1, vim.api.nvim_buf_line_count(instance.bufnr)
      )
    else
      redecorate_rows(instance, pending.first_row, pending.last_row)
    end
  end)
  if ok then
    instance._highlight_error_reported = nil
  elseif not instance._highlight_error_reported then
    instance._highlight_error_reported = true
    instance:_report_async_error("column highlight update failed: " .. tostring(err))
  end
end

local function queue_highlight_update(instance, first_line, old_last_line, new_last_line)
  local pending = instance._highlight_pending
  if pending then
    -- Multiple edits before the scheduled pass can shift every prior range.
    pending.full = true
  else
    instance._highlight_pending = {
      full = old_last_line > new_last_line,
      first_row = first_line + 1,
      last_row = new_last_line,
    }
  end
  if instance._highlight_update_scheduled then return end
  instance._highlight_update_scheduled = true
  vim.schedule(function() apply_pending_highlight_update(instance) end)
end

local function attach_highlight_updates(instance)
  instance._highlight_disabled = false
  instance._highlight_pending = nil
  instance._highlight_update_scheduled = false
  local attached = vim.api.nvim_buf_attach(instance.bufnr, false, {
    on_lines = function(_, bufnr, _, first_line, old_last_line, new_last_line)
      if instance._highlight_disabled or instance._destroyed
          or instance.state == "destroying" or instance.state == "destroyed" then
        return true
      end
      if bufnr ~= instance.bufnr then return true end
      queue_highlight_update(instance, first_line, old_last_line, new_last_line)
    end,
    on_detach = function()
      instance._highlight_attached = false
      instance._highlight_pending = nil
      instance._highlight_update_scheduled = false
    end,
  })
  if not attached then fail("could not attach column highlight updates", 3) end
  instance._highlight_attached = true
end

local function install_syntax(instance)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return end
  vim.api.nvim_buf_call(instance.bufnr, function()
    vim.cmd("syntax clear FreStableMarker")
    vim.cmd([[syntax match FreStableMarker /^\%x1ffre:[0-9a-z]\+:[0-9a-z]\+\%x1f/ conceal]])
    vim.cmd([[syntax match FreStableMarker /^\%x1ffre-nav:[0-9a-z]\+:\%(parent\|root\)\%x1f/ conceal]])
  end)
end

function M.setup(instance)
  vim.api.nvim_set_hl(0, "FreStableMarker", { default = true, link = "Conceal" })
  vim.api.nvim_set_hl(0, "FreDirectoryIcon", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "FreSymlinkIcon", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "FreFileIcon", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "FreUnsupportedIcon", { default = true, link = "DiagnosticWarn" })
  install_syntax(instance)
  attach_highlight_updates(instance)

  local group_name = "FreBuffer" .. tostring(instance.id)
  instance._buffer_augroup = vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd("Syntax", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function() install_syntax(instance) end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function(args)
      local winid = vim.api.nvim_get_current_win()
      local row, col = 1, 0
      if vim.api.nvim_get_current_buf() == args.buf then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        row, col = cursor[1], cursor[2]
      end
      require("fre.actions").write({
        instance = instance,
        bufnr = args.buf,
        winid = winid,
        tabpage = vim.api.nvim_get_current_tabpage(),
        mode = vim.api.nvim_get_mode().mode,
        row = row,
        col = col,
      })
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      if not instance._window_transition then instance:_on_visibility_enter() end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      install_syntax(instance)
      window.apply_all(instance)
      clamp_cursor(instance, winid)
      if instance._window_transition then return end
      instance:_on_visibility_enter()
      if instance._pending_reveal then instance:_apply_pending_reveal(winid) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      vim.schedule(function() window.sync_visibility(instance) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufModifiedSet", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      if not instance._destroyed then instance.manager:gc_reconsider(instance, true) end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function() clamp_cursor(instance) end,
  })
  for _, event in ipairs({ "InsertEnter", "InsertCharPre", "CursorMovedI" }) do
    vim.api.nvim_create_autocmd(event, {
      group = instance._buffer_augroup, buffer = instance.bufnr,
      callback = function() clamp_cursor(instance) end,
    })
  end
end

function M.teardown(instance)
  instance._highlight_disabled = true
  instance._highlight_pending = nil
  if instance._buffer_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, instance._buffer_augroup)
    instance._buffer_augroup = nil
  end
end

M.namespace = row_namespace
return M
