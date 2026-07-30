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
  error("fre.layout: " .. message, level or 3)
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
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
--- fields while setup and instance options are being merged, but still rejects
--- explicitly position-incompatible fields.
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

function M.merge(base, override, opts)
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
  local inherited_split = inherited.position == "left" or inherited.position == "right"
    or inherited.position == "top" or inherited.position == "bottom"
  local patch_split = position == "left" or position == "right"
    or position == "top" or position == "bottom"
  local same_family = inherited.position == position or (inherited_split and patch_split)
  local result
  if patch.position ~= nil and not same_family then
    result = { position = position }
  else
    result = copy(inherited)
    result.position = position
  end
  for key, value in pairs(patch) do result[key] = copy(value) end
  return M.normalize(result, { path = path })
end

function M.resolve(requested, default, opts)
  return M.normalize(requested ~= nil and requested or default, opts)
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

function M.materialize(layout, geometry)
  local position = layout.position
  if position == "current" then return { position = position } end
  if position ~= "float" then
    local total = (position == "left" or position == "right")
      and geometry.columns or geometry.lines
    local size = resolve_cells(layout.size, total)
    if size >= total then fail("layout.size does not leave room for another split", 3) end
    return { position = position, size = size }
  end

  local width = resolve_cells(layout.width, geometry.columns)
  local height = resolve_cells(layout.height, geometry.lines)
  local row = resolve_offset(layout.row, geometry.lines, height)
  local col = resolve_offset(layout.col, geometry.columns, width)
  local top, right, bottom, left = border_extents(layout.border)
  if row + height + top + bottom > geometry.lines then
    fail("layout.row places the bordered float outside the editor", 3)
  end
  if col + width + left + right > geometry.columns then
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

function M.validate_split_fit(effective, capacity)
  if effective.position ~= "current" and effective.position ~= "float"
      and effective.size > capacity then
    fail("layout.size cannot be materialized exactly in the current tab", 3)
  end
end

return M
