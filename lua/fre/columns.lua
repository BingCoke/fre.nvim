local M = {}

local COLUMN_MARK = "fre-column-v1"
local supported_metadata = { kind = true, mode = true, size = true, mtime = true }
local alignments = { left = true, center = true, right = true }

local function fail(message, level)
  error("fre.columns: " .. message, level or 3)
end

local function proper_sequence(value, name)
  if type(value) ~= "table" then
    fail(name .. " must be a sequential table", 4)
  end
  local n = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      fail(name .. " must be a sequential table", 4)
    end
    n = math.max(n, key)
  end
  for index = 1, n do
    if value[index] == nil then
      fail(name .. " must be a sequential table", 4)
    end
  end
  return n
end

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do result[copy(key, seen)] = copy(item, seen) end
  return result
end

local function validate_metadata(value, name)
  if value == nil then return {} end
  local n = proper_sequence(value, name)
  local result = {}
  local seen = {}
  for i = 1, n do
    local field = value[i]
    if type(field) ~= "string" or not supported_metadata[field] then
      fail(name .. " contains unsupported field " .. tostring(field), 4)
    end
    if seen[field] then fail(name .. " contains duplicate field " .. field, 4) end
    seen[field] = true
    result[i] = field
  end
  return result
end

local function validate_descriptor(descriptor, name)
  name = name or "descriptor"
  if type(descriptor) ~= "table" or descriptor._fre_column ~= COLUMN_MARK then
    fail(name .. " must be created by fre.columns", 4)
  end
  if type(descriptor.id) ~= "string" or descriptor.id == "" then
    fail(name .. ".id must be a non-empty string", 4)
  end
  if descriptor.id:find("[%c%s]") then
    fail(name .. ".id must not contain whitespace or controls", 4)
  end
  if not alignments[descriptor.align] then
    fail(name .. ".align must be left, center, or right", 4)
  end
  if type(descriptor.render) ~= "function" then
    fail(name .. ".render must be a function", 4)
  end
  if type(descriptor.parse) ~= "function" then
    fail(name .. ".parse must be a function", 4)
  end
  if type(descriptor.equals) ~= "function" then
    fail(name .. ".equals must be a function", 4)
  end
  descriptor.metadata = validate_metadata(descriptor.metadata or descriptor.requires, name .. ".metadata")
  descriptor.requires = nil
  return descriptor
end

local function descriptor(opts, defaults)
  if type(opts) ~= "table" then opts = {} end
  local result = copy(opts)
  for key, value in pairs(defaults or {}) do
    if key == "align" then
      if result.align == nil then result.align = value end
    else
      result[key] = value
    end
  end
  result._fre_column = COLUMN_MARK
  return validate_descriptor(result)
end

local function metadata(ctx, field)
  return ctx and ctx.metadata and ctx.metadata[field]
end

local ascii_icons = { directory = "d", file = "f", symlink = "l" }
local nerd_icons = { directory = "", symlink = "" }

local function devicons_provider(devicons)
  return function(entry)
    if nerd_icons[entry.kind] then
      return nerd_icons[entry.kind],
        entry.kind == "directory" and "FreDirectoryIcon" or "FreSymlinkIcon"
    end
    if entry.kind ~= "file" then return "?", "FreUnsupportedIcon" end
    local icon, highlight = devicons.get_icon(entry.name, nil, {
      default = true,
      strict = true,
    })
    return icon or "", highlight or "FreFileIcon"
  end
end

local function resolve_icon_provider(value)
  if value == false or value == "ascii" then return nil end
  if type(value) == "function" then return value end
  if value ~= nil and value ~= "auto" and value ~= "nvim-web-devicons" then
    fail("icon.provider must be auto, ascii, nvim-web-devicons, false, or a function", 4)
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok and type(devicons) == "table" and type(devicons.get_icon) == "function" then
    return devicons_provider(devicons)
  end
  if value == "nvim-web-devicons" then
    fail("icon.provider nvim-web-devicons is unavailable", 4)
  end
  return nil
end

local function icon_value(entry, provider, ctx)
  if provider then
    local icon, highlight = provider(entry, ctx)
    if icon ~= nil then
      if type(icon) ~= "string" or icon == "" then
        error("icon provider must return a non-empty string or nil")
      end
      if highlight ~= nil and type(highlight) ~= "string" then
        error("icon provider highlight must be a string or nil")
      end
      return icon, highlight
    end
  end
  local icon = ascii_icons[entry.kind]
  if icon then return icon end
  return "?", "FreUnsupportedIcon"
end

local function parse_token(input, pattern, label)
  local leading, value, separator, rest = input:match(
    "^( *)(" .. pattern .. ")( +)(.*)$"
  )
  if not leading then error("malformed " .. label .. " column") end
  return value, rest
end

function M.icon(opts)
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then fail("icon options must be a table", 2) end
  local provider = resolve_icon_provider(opts.provider)
  return descriptor(opts, {
    id = "icon", align = "left", metadata = { "kind" },
    render = function(entry, ctx) return icon_value(entry, provider, ctx) end,
    parse = function(suffix) return parse_token(suffix, "%S+", "icon") end,
    equals = function(entry, value, ctx)
      local expected = icon_value(entry, provider, ctx)
      return value == expected
    end,
  })
end

local function permission_text(mode)
  mode = tonumber(mode) or 0
  local bits = { 256, 128, 64, 32, 16, 8, 4, 2, 1 }
  local chars = { "r", "w", "x", "r", "w", "x", "r", "w", "x" }
  local result = {}
  for i, bit in ipairs(bits) do
    result[i] = math.floor(mode / bit) % 2 == 1 and chars[i] or "-"
  end
  if math.floor(mode / 2048) % 2 == 1 then result[3] = result[3] == "x" and "s" or "S" end
  if math.floor(mode / 1024) % 2 == 1 then result[6] = result[6] == "x" and "s" or "S" end
  if math.floor(mode / 512) % 2 == 1 then result[9] = result[9] == "x" and "t" or "T" end
  return table.concat(result)
end

local function permission_mode(value)
  if type(value) ~= "string" or #value ~= 9 then return nil end
  local expected = {
    { "r", "-", 256 }, { "w", "-", 128 }, { "x", "s", "S", "-", 64 },
    { "r", "-", 32 }, { "w", "-", 16 }, { "x", "s", "S", "-", 8 },
    { "r", "-", 4 }, { "w", "-", 2 }, { "x", "t", "T", "-", 1 },
  }
  local mode = 0
  for i = 1, 9 do
    local char = value:sub(i, i)
    local allowed = false
    for j = 1, #expected[i] - 1 do
      if char == expected[i][j] then allowed = true; break end
    end
    if not allowed then return nil end
    if char ~= "-" and char ~= "S" and char ~= "T" then mode = mode + expected[i][#expected[i]] end
    if (i == 3 and (char == "s" or char == "S")) then mode = mode + 2048 end
    if (i == 6 and (char == "s" or char == "S")) then mode = mode + 1024 end
    if (i == 9 and (char == "t" or char == "T")) then mode = mode + 512 end
  end
  return mode
end

function M.permissions(opts)
  if opts ~= nil and type(opts) ~= "table" then fail("permissions options must be a table", 2) end
  local function expected(ctx)
    if ctx and ctx.synthetic then return "-" end
    return permission_text(metadata(ctx, "mode"))
  end
  return descriptor(opts, {
    id = "permissions", align = "left", metadata = { "mode" },
    render = function(_, ctx) return expected(ctx) end,
    parse = function(suffix, ctx)
      if ctx and ctx.synthetic then return parse_token(suffix, "%-", "permissions") end
      local value, rest = parse_token(suffix, "[rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-]", "permissions")
      if not permission_mode(value) then error("invalid permissions column") end
      return value, rest
    end,
    equals = function(_, value, ctx)
      return value == expected(ctx)
    end,
  })
end

local function size_text(value)
  local size = tonumber(value)
  if size == nil then return "-" end
  if size < 1000 then return tostring(math.floor(size)) end
  if size < 1000000 then return string.format("%.1fk", size / 1000) end
  if size < 1000000000 then return string.format("%.1fM", size / 1000000) end
  return string.format("%.1fG", size / 1000000000)
end

function M.size(opts)
  if opts ~= nil and type(opts) ~= "table" then fail("size options must be a table", 2) end
  return descriptor(opts, {
    id = "size", align = "right", metadata = { "size" },
    render = function(_, ctx) return size_text(metadata(ctx, "size")) end,
    parse = function(suffix) return parse_token(suffix, "%S+", "size") end,
    equals = function(_, value, ctx)
      return value == size_text(metadata(ctx, "size"))
    end,
  })
end

local function mtime_seconds(value)
  if type(value) == "table" then return tonumber(value.sec) or 0 end
  return tonumber(value) or 0
end

function M.mtime(opts)
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then fail("mtime options must be a table", 2) end
  local format = opts.format or "%Y-%m-%d %H:%M"
  if type(format) ~= "string" or format == "" then fail("mtime.format must be a non-empty string", 2) end
  local result = copy(opts)
  result.id = "mtime"
  result.align = result.align or "left"
  result.format = format
  result.metadata = { "mtime" }
  result._fre_column = COLUMN_MARK
  local function expected(ctx)
    if ctx and ctx.synthetic then return "-" end
    return os.date(ctx.descriptor.format, mtime_seconds(metadata(ctx, "mtime")))
  end
  result.render = function(_, ctx)
    return expected(ctx)
  end
  result.parse = function(suffix, ctx)
    local rendered = expected(ctx)
    local leading = suffix:match("^( *)") or ""
    local start = #leading + 1
    local value = suffix:sub(start, start + #rendered - 1)
    local separator = suffix:sub(start + #rendered):match("^( +)")
    if value == "" or #value ~= #rendered or not separator then
      error("malformed mtime column")
    end
    local consumed = #leading + #rendered + #separator
    return value, suffix:sub(consumed + 1)
  end
  result.equals = function(_, value, ctx)
    return value == expected(ctx)
  end
  return validate_descriptor(result)
end

function M.custom(opts)
  if type(opts) ~= "table" then fail("custom options must be a table", 2) end
  local result = copy(opts)
  result._fre_column = COLUMN_MARK
  if result.align == nil then result.align = "left" end
  return validate_descriptor(result, "custom descriptor")
end

function M.validate(descriptors, name)
  name = name or "columns"
  local n = proper_sequence(descriptors, name)
  local ids = {}
  for i = 1, n do
    local item = validate_descriptor(descriptors[i], name .. "[" .. i .. "]")
    if ids[item.id] then fail(name .. " contains duplicate column id " .. item.id, 4) end
    ids[item.id] = true
  end
  return descriptors
end

function M.is_descriptor(value)
  return type(value) == "table" and value._fre_column == COLUMN_MARK
end

function M.render_text(descriptor_value, entry, ctx)
  local ok, text, highlight = pcall(descriptor_value.render, entry, ctx)
  if not ok then error("render callback for column " .. descriptor_value.id .. " failed: " .. tostring(text), 0) end
  if type(text) ~= "string" then error("render callback for column " .. descriptor_value.id .. " must return text", 0) end
  local index = 1
  while index <= #text do
    local byte = text:byte(index)
    if byte < 32 or byte == 127 then
      error("rendered column " .. descriptor_value.id .. " contains a control byte", 0)
    end
    local length
    if byte < 0x80 then length = 1
    elseif byte >= 0xc2 and byte <= 0xdf then length = 2
    elseif byte >= 0xe0 and byte <= 0xef then length = 3
    elseif byte >= 0xf0 and byte <= 0xf4 then length = 4
    else error("rendered column " .. descriptor_value.id .. " is not valid UTF-8", 0) end
    if index + length - 1 > #text then error("rendered column " .. descriptor_value.id .. " is not valid UTF-8", 0) end
    for j = index + 1, index + length - 1 do
      if text:byte(j) < 0x80 or text:byte(j) > 0xbf then error("rendered column " .. descriptor_value.id .. " is not valid UTF-8", 0) end
    end
    if length == 3 and ((byte == 0xe0 and text:byte(index + 1) < 0xa0) or (byte == 0xed and text:byte(index + 1) >= 0xa0)) then error("rendered column " .. descriptor_value.id .. " is not valid UTF-8", 0) end
    if length == 4 and ((byte == 0xf0 and text:byte(index + 1) < 0x90) or (byte == 0xf4 and text:byte(index + 1) >= 0x90)) then error("rendered column " .. descriptor_value.id .. " is not valid UTF-8", 0) end
    index = index + length
  end
  return text, highlight, vim.api.nvim_strwidth(text)
end

return M
