local columns = require("fre.columns")
local path = require("fre.path")

local M = {}

local US = string.char(31)
local PREFIX = US .. "fre:"
local MAX_EXACT_INTEGER = 9007199254740991

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function fail_row(row_number, message, level)
  fail("row " .. tostring(row_number) .. ": " .. message, level or 4)
end

local function valid_integer(value, allow_zero)
  return type(value) == "number" and value % 1 == 0
    and value <= MAX_EXACT_INTEGER and (allow_zero and value >= 0 or value > 0)
end

local function validate_width(width, name)
  if type(width) ~= "number" or width < 3 or width % 1 ~= 0 then
    fail(name .. " marker width must be an integer of at least 3", 4)
  end
end

local function format_id(value, width)
  return string.format("%0" .. tostring(width) .. "d", value)
end

function M.marker(manager, instance_id, node_id, widths)
  if not valid_integer(instance_id, false) then
    fail("instance marker ID must be a positive integer", 3)
  end
  if not valid_integer(node_id, true) then
    fail("node marker ID must be a non-negative integer", 3)
  end
  widths = widths or manager:get_marker_widths()
  validate_width(widths.instance, "instance")
  validate_width(widths.node, "node")
  if #tostring(instance_id) > widths.instance then
    fail("instance marker ID exceeds captured width", 3)
  end
  if #tostring(node_id) > widths.node then
    fail("node marker ID exceeds captured width", 3)
  end
  return PREFIX .. format_id(instance_id, widths.instance) .. ":"
    .. format_id(node_id, widths.node) .. US
end

local function decode_decimal(text, row_number, label, allow_zero, current_width)
  if text == "" or text:find("[^0-9]") then
    fail_row(row_number, "invalid " .. label .. " decimal ID")
  end
  local width = #text
  if width < 3 then fail_row(row_number, label .. " marker field is under-width") end
  if width > current_width then fail_row(row_number, label .. " marker field is over-width") end
  local value = tonumber(text)
  if not valid_integer(value, allow_zero) then
    fail_row(row_number, "invalid " .. label .. " decimal ID")
  end
  if format_id(value, width) ~= text then
    fail_row(row_number, "non-canonical " .. label .. " marker padding")
  end
  return value
end

function M.decode_marker(manager, row_number, line, widths)
  widths = widths or manager:get_marker_widths()
  validate_width(widths.instance, "instance")
  validate_width(widths.node, "node")
  local instance_text, node_text, suffix_index = line:match(
    "^" .. US .. "fre:([0-9]+):([0-9]+)" .. US .. "()"
  )
  if not suffix_index then fail_row(row_number, "malformed reserved row marker") end
  local instance_id = decode_decimal(
    instance_text, row_number, "instance", false, widths.instance
  )
  local node_id = decode_decimal(node_text, row_number, "node", true, widths.node)
  local marker_end = suffix_index - 1
  local marker_text = line:sub(1, marker_end)
  local observed_widths = { instance = #instance_text, node = #node_text }
  if marker_text ~= M.marker(manager, instance_id, node_id, observed_widths) then
    fail_row(row_number, "non-canonical row marker")
  end
  return {
    marker_end = marker_end,
    instance_id = instance_id,
    node_id = node_id,
    marker = marker_text,
    raw_marker_text = marker_text,
    widths = observed_widths,
  }
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

local function marker_source(instance, instance_id, row_number)
  if instance_id == instance.id then return instance end
  local source = instance.manager:find_by_id(instance_id)
  if not source then
    fail_row(row_number, "marker references unknown instance " .. tostring(instance_id))
  end
  if source._destroyed or source.state == "destroying" or source.state == "destroyed" then
    fail_row(row_number, "marker references destroyed instance " .. tostring(instance_id))
  end
  return source
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

local function navigation_callback_entry(source, navigation_kind)
  local entry = source:_entry(source.root_node)
  local label
  if navigation_kind == "parent" then
    label = ".."
    entry.absolute_path = path.parent(source.root)
  else
    label = "/"
    entry.absolute_path = source.root
  end
  entry.relative_path = label
  entry.name = label
  return entry
end

local function template_for(source, node_id)
  local templates = source.view and source.view.row_templates
  return templates and templates[node_id] or nil
end

local function same_range(left, right)
  return left and right and left.start_byte == right.start_byte
    and left.end_byte == right.end_byte
end

local function parse_columns(row_number, source, node, suffix, marker_end, opts)
  local descriptors = source.config.columns or {}
  local values, ranges, separators, fields = {}, {}, {}, {}
  local navigation_kind = opts.navigation_kind
  local callback_entry = navigation_kind
    and navigation_callback_entry(source, navigation_kind) or source:_entry(node)
  local template = template_for(source, opts.node_id)
  local consumed = 0
  local first_navigable
  for index, descriptor in ipairs(descriptors) do
    local unconsumed = suffix:sub(consumed + 1)
    local ctx = source:_column_context(
      node, callback_entry, descriptor, index, index == #descriptors
    )
    if navigation_kind then ctx = navigation_context(ctx, navigation_kind) end
    local ok, value, remaining = pcall(descriptor.parse, unconsumed, ctx)
    if not ok then
      fail_row(row_number, "column " .. descriptor.id .. " parser failed: " .. tostring(value))
    end
    if value == nil then
      fail_row(row_number, "column " .. descriptor.id .. " parser returned no value")
    end
    if type(remaining) ~= "string" then
      fail_row(row_number, "column " .. descriptor.id .. " parser must return a suffix string")
    end
    if #remaining >= #unconsumed then
      fail_row(row_number, "column " .. descriptor.id .. " parser made no progress")
    end
    local amount = #unconsumed - #remaining
    if unconsumed:sub(amount + 1) ~= remaining then
      fail_row(row_number, "column " .. descriptor.id .. " parser returned a non-literal suffix")
    end
    local consumed_text = unconsumed:sub(1, amount)
    local separator = consumed_text:match("( +)$")
    if not separator then
      fail_row(row_number, "column " .. descriptor.id .. " parser did not consume its separator")
    end
    local start_byte = marker_end + consumed
    local separator_start = start_byte + amount - #separator
    local field_range = { start_byte = start_byte, end_byte = start_byte + amount }
    local physical_range = { start_byte = start_byte, end_byte = separator_start }
    local separator_range = { start_byte = separator_start, end_byte = start_byte + amount }
    local template_field = template and template.fields and template.fields[index]
    local content_range = physical_range
    if template_field and template_field.id == descriptor.id
        and same_range(template_field.physical_range, physical_range) then
      content_range = {
        start_byte = template_field.content_range.start_byte,
        end_byte = template_field.content_range.end_byte,
      }
    end
    fields[index] = {
      id = descriptor.id,
      value = value,
      range = field_range,
      content_range = content_range,
      separator_range = separator_range,
      navigable = descriptor.navigable,
      align = descriptor.align,
      width = source.view and source.view.column_widths[index] or nil,
    }
    ranges[index] = field_range
    separators[index] = separator_range
    values[index] = value
    values[descriptor.id] = value
    if descriptor.navigable and not first_navigable then
      first_navigable = field_range.start_byte
    end
    if opts.validate_metadata then
      local equals_ok, equal = pcall(descriptor.equals, callback_entry, value, ctx)
      if not equals_ok then
        fail_row(row_number, "column " .. descriptor.id
          .. " equals callback failed: " .. tostring(equal))
      end
      if not equal then
        fail_row(row_number, "column " .. descriptor.id .. " metadata changed")
      end
    end
    consumed = consumed + amount
  end
  return {
    values = values,
    ranges = ranges,
    separators = separators,
    fields = fields,
    path_suffix = suffix:sub(consumed + 1),
    path_offset = marker_end + consumed,
    first_navigable = first_navigable,
  }
end

function M.decode(instance, row_number, line, opts)
  opts = opts or {}
  if line == nil then return nil end
  if line:sub(1, 1) ~= US then
    local proposed_path, path_range = trim_range(line, 0)
    return {
      kind = "new", row_kind = "new", marked = false, line = line,
      proposed_path = proposed_path, path = proposed_path,
      marker_range = nil, column_ranges = {}, separator_ranges = {}, fields = {},
      path_range = path_range, visible_range = path_range,
      navigable_range = path_range,
    }
  end

  local marker_widths = instance.manager:get_marker_widths()
  local decoded_marker = M.decode_marker(instance.manager, row_number, line, marker_widths)
  local source = marker_source(instance, decoded_marker.instance_id, row_number)
  local node, entry, navigation_kind
  if decoded_marker.node_id == 0 then
    node = source.root_node
    if not node then fail_row(row_number, "navigation marker references an invalid instance") end
    navigation_kind = path.parent(source.root) and "parent" or "root"
  else
    node = source.nodes_by_id[decoded_marker.node_id]
    if not node then
      if source == instance then
        fail_row(row_number, "marker references unknown local node " .. tostring(decoded_marker.node_id))
      end
      fail_row(row_number, "marker references unknown node " .. tostring(decoded_marker.node_id)
        .. " in instance " .. tostring(decoded_marker.instance_id))
    end
    if source ~= instance and (node.id ~= decoded_marker.node_id or type(node.path) ~= "string"
        or type(source.nodes_by_path) ~= "table" or source.nodes_by_path[node.path] ~= node) then
      fail_row(row_number, "marker references invalid node " .. tostring(decoded_marker.node_id)
        .. " in instance " .. tostring(decoded_marker.instance_id))
    end
    if source == instance then
      entry = source:_entry(node)
    else
      local entry_ok, entry_or_error = pcall(source._entry, source, node)
      if not entry_ok then
        fail_row(row_number, "marker references invalid node " .. tostring(decoded_marker.node_id)
          .. " in instance " .. tostring(decoded_marker.instance_id)
          .. ": " .. tostring(entry_or_error))
      end
      entry = entry_or_error
    end
  end

  local parsed = parse_columns(
    row_number, source, node, line:sub(decoded_marker.marker_end + 1),
    decoded_marker.marker_end, {
      navigation_kind = navigation_kind,
      node_id = decoded_marker.node_id,
      validate_metadata = opts.validate_metadata ~= false,
    }
  )
  local proposed_path, path_range = trim_range(parsed.path_suffix, parsed.path_offset)
  if not navigation_kind then
    local has_trailing_slash = proposed_path:sub(-1) == "/"
    if node.kind == "directory" and not has_trailing_slash
        and not (opts.allow_empty_path and proposed_path == "") then
      fail_row(row_number, "directory path must end in /")
    end
    if node.kind ~= "directory" and has_trailing_slash then
      fail_row(row_number, node.kind .. " path must not end in /")
    end
  end
  local common = {
    marked = true,
    line = line,
    marker = decoded_marker.marker,
    instance_id = decoded_marker.instance_id,
    source_instance_id = decoded_marker.instance_id,
    node_id = decoded_marker.node_id,
    source_instance = source,
    source_node = navigation_kind and nil or node,
    foreign = source ~= instance,
    entry = entry,
    proposed_path = proposed_path,
    path = proposed_path,
    marker_range = { start_byte = 0, end_byte = decoded_marker.marker_end },
    column_values = parsed.values,
    column_ranges = parsed.ranges,
    separator_ranges = parsed.separators,
    fields = parsed.fields,
    path_range = path_range,
    visible_range = { start_byte = decoded_marker.marker_end, end_byte = path_range.end_byte },
    navigable_range = {
      start_byte = parsed.first_navigable or path_range.start_byte,
      end_byte = path_range.end_byte,
    },
  }
  if navigation_kind then
    common.kind = "navigation"
    common.row_kind = "navigation"
    common.synthetic = true
    common.navigation_kind = navigation_kind
    common.entry = nil
  else
    common.kind = "existing"
    common.row_kind = "entry"
  end
  return common
end

function M.matches_identity(instance, line, instance_id, node_id)
  if type(line) ~= "string" or line:sub(1, 1) ~= US then return false end
  local ok, decoded = pcall(M.decode_marker, instance.manager, 0, line)
  return ok and decoded.instance_id == instance_id and decoded.node_id == node_id
end

function M.prepare(instance, projection, render_path, opts)
  opts = opts or {}
  render_path = render_path or function(node)
    return node.kind == "directory" and node.name .. "/" or node.name
  end
  local nodes = projection.nodes or projection
  local descriptors = instance.config.columns or {}
  local marker_widths = instance.manager:get_marker_widths()
  local rendered, widths = {}, {}
  for index = 1, #descriptors do widths[index] = 0 end

  local function add_rendered(node, rendered_path, navigation_kind)
    local callback_entry = navigation_kind
      and navigation_callback_entry(instance, navigation_kind) or instance:_entry(node)
    local fields = {}
    for index, descriptor in ipairs(descriptors) do
      local ctx = instance:_column_context(
        node, callback_entry, descriptor, index, index == #descriptors
      )
      if navigation_kind then ctx = navigation_context(ctx, navigation_kind) end
      local text, highlight, display_width = columns.render_text(descriptor, callback_entry, ctx)
      fields[index] = {
        text = text,
        highlight = highlight,
        display_width = display_width,
      }
      widths[index] = math.max(widths[index], display_width)
    end
    rendered[#rendered + 1] = {
      node = node,
      node_id = navigation_kind and 0 or node.id,
      fields = fields,
      path = rendered_path,
      synthetic = navigation_kind ~= nil,
      navigation_kind = navigation_kind,
    }
  end

  local navigation_kind = path.parent(instance.root) and "parent" or "root"
  local navigation_path
  if navigation_kind == "parent" then
    navigation_path = "../"
  else
    navigation_path = "/"
  end
  add_rendered(instance.root_node, navigation_path, navigation_kind)
  for _, node in ipairs(nodes) do add_rendered(node, render_path(node), nil) end

  local lines, baseline, highlights, row_templates = {}, {}, {}, {}
  for row_number, item in ipairs(rendered) do
    local marker_text = M.marker(instance.manager, instance.id, item.node_id, marker_widths)
    local physical = {}
    local template = {
      instance_id = instance.id,
      node_id = item.node_id,
      marker_range = { start_byte = 0, end_byte = #marker_text },
      fields = {},
      navigation_kind = item.navigation_kind,
    }
    local offset = #marker_text
    for index, field in ipairs(item.fields) do
      local descriptor = descriptors[index]
      local text, leading_padding = columns.align(
        field.text, widths[index], field.display_width, descriptor.align
      )
      local trailing_padding = widths[index] - field.display_width - leading_padding
      physical[index] = text
      local aligned_end = offset + #text
      local range = { start_byte = offset, end_byte = aligned_end + 1 }
      local content_range = {
        start_byte = offset + leading_padding,
        end_byte = offset + leading_padding + #field.text,
      }
      local separator_range = {
        start_byte = aligned_end,
        end_byte = aligned_end + 1,
      }
      template.fields[index] = {
        id = descriptor.id,
        range = range,
        physical_range = { start_byte = offset, end_byte = aligned_end },
        content_range = content_range,
        leading_padding = leading_padding,
        trailing_padding = trailing_padding,
        separator_range = separator_range,
        navigable = descriptor.navigable,
        align = descriptor.align,
        width = widths[index],
      }
      if field.highlight and #field.text > 0 then
        highlights[#highlights + 1] = {
          row = row_number - 1,
          start_col = content_range.start_byte,
          end_col = content_range.end_byte,
          hl_group = field.highlight,
        }
        template.fields[index].highlight = {
          start_col = content_range.start_byte,
          end_col = content_range.end_byte,
          text = field.text,
          hl_group = field.highlight,
        }
      end
      offset = range.end_byte
    end
    local suffix = item.path
    if #physical > 0 then suffix = table.concat(physical, " ") .. " " .. suffix end
    lines[row_number] = marker_text .. suffix
    template.path_range = { start_byte = offset, end_byte = offset + #item.path }
    template.line = lines[row_number]
    row_templates[item.node_id] = template
    if not item.synthetic then baseline[item.node.id] = item.node.path end
  end

  if opts.validate then
    for row_number, item in ipairs(rendered) do
      local decoded = M.decode(instance, row_number, lines[row_number])
      if item.synthetic then
        if not decoded.synthetic or decoded.navigation_kind ~= item.navigation_kind
            or decoded.proposed_path ~= item.path then
          fail_row(row_number, "rendered navigation row failed semantic validation")
        end
      elseif not decoded.marked or decoded.synthetic or decoded.node_id ~= item.node.id
          or decoded.proposed_path ~= item.path then
        fail_row(row_number, "rendered projection failed semantic validation")
      end
    end
  end

  return {
    lines = lines,
    baseline = baseline,
    marker_widths = marker_widths,
    marker_generation = marker_widths.generation,
    column_widths = widths,
    highlights = highlights,
    row_templates = row_templates,
    projection = projection.nodes and projection or { nodes = nodes },
    visible_nodes = nodes,
    row_offset = 1,
  }
end

return M
