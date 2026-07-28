local columns = require("fre.columns")
local path = require("fre.path")

local M = {}

local US = string.char(31)
local PREFIX = US .. "fre:"
local PARSER_GUARD = US .. "fre-parser-guard" .. US
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

local function active_layout(source, override)
  if override and override.source_instance_id == source.id then return override end
  return source.view
end

local function template_for(layout, node_id)
  local templates = layout and layout.row_templates
  return templates and templates[node_id] or nil
end

local function same_range(left, right)
  return left and right and left.start_byte == right.start_byte
    and left.end_byte == right.end_byte
end

local function display_width_boundary(text, width)
  local boundary = 0
  local character_count = vim.fn.strchars(text)
  for character_index = 1, character_count do
    local candidate = vim.str_byteindex(text, character_index)
    if vim.fn.strdisplaywidth(text:sub(1, candidate)) > width then break end
    boundary = candidate
  end
  if vim.fn.strdisplaywidth(text:sub(1, boundary)) ~= width then return nil end
  return boundary
end

local function resolve_layout(descriptors, suffix, marker_end, layout)
  local widths = layout and layout.column_widths
  if type(widths) ~= "table" then return nil end
  local owned, consumed = {}, 0
  for index, descriptor in ipairs(descriptors) do
    local width = widths[index]
    if type(width) ~= "number" or width < 0 then return nil end
    local boundary = display_width_boundary(suffix:sub(consumed + 1), width)
    if boundary == nil or suffix:sub(consumed + boundary + 1, consumed + boundary + 1) ~= " " then
      return nil
    end
    local physical_start = marker_end + consumed
    local physical_end = physical_start + boundary
    owned[index] = {
      chunk = suffix:sub(consumed + 1, consumed + boundary + 1),
      physical_range = { start_byte = physical_start, end_byte = physical_end },
      separator_range = { start_byte = physical_end, end_byte = physical_end + 1 },
      width = width,
    }
    consumed = consumed + boundary + 1
  end
  return { fields = owned, consumed = consumed }
end

local function parse_columns(row_number, source, node, suffix, marker_end, opts)
  local descriptors = source.config.columns or {}
  local values, ranges, separators, fields = {}, {}, {}, {}
  local navigation_kind = opts.navigation_kind
  local callback_entry
  if navigation_kind then
    callback_entry = navigation_callback_entry(source, navigation_kind)
  else
    callback_entry = source:_entry(node)
  end
  local layout = active_layout(source, opts.layout_override)
  local resolved = resolve_layout(descriptors, suffix, marker_end, layout)
  local template = resolved and template_for(layout, opts.node_id) or nil
  local consumed = 0
  local first_navigable
  for index, descriptor in ipairs(descriptors) do
    local owned = resolved and resolved.fields[index]
    local parser_input = owned and owned.chunk .. PARSER_GUARD or suffix:sub(consumed + 1)
    local ctx = source:_column_context(
      node, callback_entry, descriptor, index, index == #descriptors
    )
    if navigation_kind then ctx = navigation_context(ctx, navigation_kind) end
    local ok, value, remaining = pcall(descriptor.parse, parser_input, ctx)
    if not ok then
      fail_row(row_number, "column " .. descriptor.id .. " parser failed: " .. tostring(value))
    end
    if value == nil then
      fail_row(row_number, "column " .. descriptor.id .. " parser returned no value")
    end
    if type(remaining) ~= "string" then
      fail_row(row_number, "column " .. descriptor.id .. " parser must return a suffix string")
    end
    if #remaining >= #parser_input then
      fail_row(row_number, "column " .. descriptor.id .. " parser made no progress")
    end
    local amount = #parser_input - #remaining
    if parser_input:sub(amount + 1) ~= remaining then
      fail_row(row_number, "column " .. descriptor.id .. " parser returned a non-literal suffix")
    end
    local consumed_text = parser_input:sub(1, amount)
    local separator = consumed_text:match("( +)$")
    if not separator then
      fail_row(row_number, "column " .. descriptor.id .. " parser did not consume its separator")
    end
    if owned and remaining ~= PARSER_GUARD then
      fail_row(row_number, "column " .. descriptor.id
        .. " parser did not consume its exact layout chunk")
    end
    local parser_start = owned and owned.physical_range.start_byte or marker_end + consumed
    local parser_end = parser_start + amount
    local field_range = { start_byte = parser_start, end_byte = parser_end }
    local physical_range
    local separator_range
    local width = layout and layout.column_widths and layout.column_widths[index] or nil
    if owned then
      physical_range = owned.physical_range
      separator_range = owned.separator_range
    else
      local separator_start = parser_end - #separator
      physical_range = { start_byte = parser_start, end_byte = separator_start }
      separator_range = { start_byte = separator_start, end_byte = parser_end }
    end
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
      physical_range = physical_range,
      content_range = content_range,
      separator_range = separator_range,
      leading_padding = content_range.start_byte - physical_range.start_byte,
      trailing_padding = physical_range.end_byte - content_range.end_byte,
      template_available = template_field ~= nil
        and template_field.id == descriptor.id
        and same_range(template_field.physical_range, physical_range),
      navigable = descriptor.navigable,
      align = descriptor.align,
      width = width,
    }
    ranges[index] = field_range
    separators[index] = separator_range
    values[index] = value
    values[descriptor.id] = value
    if descriptor.navigable and not first_navigable then
      first_navigable = physical_range.start_byte
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
  local path_consumed = resolved and resolved.consumed or consumed
  return {
    values = values,
    ranges = ranges,
    separators = separators,
    fields = fields,
    path_suffix = suffix:sub(path_consumed + 1),
    path_offset = marker_end + path_consumed,
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
    if path.parent(source.root) then
      navigation_kind = "parent"
    else
      navigation_kind = "root"
    end
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
      layout_override = opts.layout_override,
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
  local source_node
  if navigation_kind then
    source_node = nil
  else
    source_node = node
  end
  local common = {
    marked = true,
    line = line,
    marker = decoded_marker.marker,
    instance_id = decoded_marker.instance_id,
    source_instance_id = decoded_marker.instance_id,
    node_id = decoded_marker.node_id,
    source_instance = source,
    source_node = source_node,
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

local function byte_boundary(text, byte_offset)
  byte_offset = math.max(0, math.min(byte_offset, #text))
  local boundary = 0
  for character_index = 1, vim.fn.strchars(text) do
    local candidate = vim.str_byteindex(text, character_index)
    if candidate > byte_offset then break end
    boundary = candidate
  end
  return boundary
end

local function display_offset(text, byte_offset)
  local boundary = byte_boundary(text, byte_offset)
  return vim.fn.strdisplaywidth(text:sub(1, boundary))
end

local function byte_for_display_offset(text, offset)
  offset = math.max(0, offset or 0)
  local boundary = 0
  local width = 0
  for character_index = 1, vim.fn.strchars(text) do
    local candidate = vim.str_byteindex(text, character_index)
    local candidate_width = vim.fn.strdisplaywidth(text:sub(1, candidate))
    if offset < candidate_width then return boundary end
    boundary = candidate
    width = candidate_width
  end
  if offset >= width then return boundary end
  return 0
end

local function range_text(decoded, range)
  return decoded.line:sub(range.start_byte + 1, range.end_byte)
end

local function content_end_anchor(decoded, field)
  return {
    field_id = field.id,
    zone = "content",
    display_offset = vim.fn.strdisplaywidth(range_text(decoded, field.content_range)),
  }
end

function M.cursor_anchor(decoded, col)
  if not decoded or not decoded.marked or type(decoded.line) ~= "string" then return nil end
  col = math.max(0, math.min(col or 0, #decoded.line))
  local preceding
  for _, field in ipairs(decoded.fields or {}) do
    local physical = field.physical_range
    if field.navigable and physical then
      if col >= physical.start_byte and col < physical.end_byte then
        local physical_text = range_text(decoded, physical)
        local normalized = physical.start_byte
          + byte_boundary(physical_text, col - physical.start_byte)
        local content = field.content_range
        if normalized < content.start_byte then
          local padding = decoded.line:sub(normalized + 1, content.start_byte)
          return {
            field_id = field.id,
            zone = "leading_padding",
            display_offset = vim.fn.strdisplaywidth(padding),
          }
        end
        if normalized >= content.end_byte then
          local padding = decoded.line:sub(content.end_byte + 1, normalized)
          return {
            field_id = field.id,
            zone = "trailing_padding",
            display_offset = vim.fn.strdisplaywidth(padding),
          }
        end
        local text = range_text(decoded, content)
        return {
          field_id = field.id,
          zone = "content",
          display_offset = display_offset(text, normalized - content.start_byte),
        }
      end
      if col >= physical.end_byte then preceding = field end
    end
    local separator = field.separator_range
    if separator and col >= separator.start_byte and col < separator.end_byte then
      if preceding then return content_end_anchor(decoded, preceding) end
      return { field_id = "path", zone = "content", display_offset = 0 }
    end
  end

  if col < decoded.path_range.start_byte then
    if preceding then return content_end_anchor(decoded, preceding) end
    return { field_id = "path", zone = "content", display_offset = 0 }
  end
  local text = range_text(decoded, decoded.path_range)
  return {
    field_id = "path",
    zone = "content",
    display_offset = display_offset(text, col - decoded.path_range.start_byte),
  }
end

function M.cursor_column(decoded, anchor)
  if not decoded or not decoded.marked or type(anchor) ~= "table" then return nil end
  if anchor.field_id == "path" then
    local text = range_text(decoded, decoded.path_range)
    return decoded.path_range.start_byte
      + byte_for_display_offset(text, anchor.display_offset)
  end

  local selected
  for _, field in ipairs(decoded.fields or {}) do
    if field.navigable and field.id == anchor.field_id then
      selected = field
      break
    end
  end
  if not selected or not selected.physical_range or not selected.content_range then
    return decoded.path_range.start_byte
  end

  local physical = selected.physical_range
  local content = selected.content_range
  if anchor.zone == "leading_padding" then
    local text = decoded.line:sub(physical.start_byte + 1, content.start_byte)
    local width = vim.fn.strdisplaywidth(text)
    return physical.start_byte
      + byte_for_display_offset(text, math.max(0, width - (anchor.display_offset or 0)))
  end
  if anchor.zone == "trailing_padding" then
    local text = decoded.line:sub(content.end_byte + 1, physical.end_byte)
    return content.end_byte + byte_for_display_offset(text, anchor.display_offset)
  end

  local text = range_text(decoded, content)
  return content.start_byte + byte_for_display_offset(text, anchor.display_offset)
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
    local callback_entry
    if navigation_kind then
      callback_entry = navigation_callback_entry(instance, navigation_kind)
    else
      callback_entry = instance:_entry(node)
    end
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
    local node_id
    if navigation_kind then
      node_id = 0
    else
      node_id = node.id
    end
    rendered[#rendered + 1] = {
      node = node,
      node_id = node_id,
      fields = fields,
      path = rendered_path,
      synthetic = navigation_kind ~= nil,
      navigation_kind = navigation_kind,
    }
  end

  local navigation_kind
  if path.parent(instance.root) then
    navigation_kind = "parent"
  else
    navigation_kind = "root"
  end
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
    local validation_layout = {
      source_instance_id = instance.id,
      column_widths = widths,
      row_templates = row_templates,
    }
    for row_number, item in ipairs(rendered) do
      local decoded = M.decode(instance, row_number, lines[row_number], {
        layout_override = validation_layout,
      })
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
