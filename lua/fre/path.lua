local M = {}

local temp_counter = 0

local function fail(message)
  error("fre.path: " .. message, 3)
end

local function check_string(value, name)
  if type(value) ~= "string" then
    fail((name or "path") .. " must be a string")
  end
  if value:find("[\r\n]") then
    fail((name or "path") .. " must not contain CR or LF")
  end
  return value
end

local function ascii_lower(value)
  return (value:gsub("[A-Z]", function(char)
    return string.char(char:byte() + 32)
  end))
end

local function has_drive(path)
  return path:match("^%a:") ~= nil
end

local function has_unc_prefix(path)
  return path:match("^[\\/][\\/]") ~= nil
end

local function windows_shaped(path)
  return has_drive(path) or has_unc_prefix(path)
end

local function path_kind(path)
  if has_unc_prefix(path) then
    return "unc"
  end
  if path:match("^%a:[\\/]") then
    return "drive_absolute"
  end
  if has_drive(path) then
    return "drive_relative"
  end
  if path:sub(1, 1) == "/" then
    return "posix_absolute"
  end
  return "relative"
end

local function split_components(path)
  local result = {}
  for component in path:gmatch("[^/]+") do
    result[#result + 1] = component
  end
  return result
end

local function normalize_components(components, absolute)
  local result = {}
  for _, component in ipairs(components) do
    if component ~= "" and component ~= "." then
      if component == ".." then
        if #result > 0 and result[#result] ~= ".." then
          result[#result] = nil
        elseif not absolute then
          result[#result + 1] = component
        end
      else
        result[#result + 1] = component
      end
    end
  end
  return result
end

local function parse_normalized(path)
  local kind = path_kind(path)
  if kind == "unc" then
    local components = split_components(path:sub(3))
    return {
      kind = kind,
      windows = true,
      volume = "//" .. components[1] .. "/" .. components[2],
      components = vim.list_slice(components, 3),
    }
  end
  if kind == "drive_absolute" then
    return {
      kind = kind,
      windows = true,
      volume = path:sub(1, 2),
      components = split_components(path:sub(4)),
    }
  end
  if kind == "drive_relative" then
    return {
      kind = kind,
      windows = true,
      volume = path:sub(1, 2),
      components = split_components(path:sub(3)),
    }
  end
  if kind == "posix_absolute" then
    return {
      kind = kind,
      windows = false,
      volume = "/",
      components = split_components(path:sub(2)),
    }
  end
  return {
    kind = kind,
    windows = false,
    volume = "",
    components = split_components(path),
  }
end

function M.assert_single_line(value, name)
  return check_string(value, name or "value")
end

function M.is_uri(path)
  check_string(path)
  if has_drive(path) then
    return false
  end
  return path:match("^[A-Za-z][A-Za-z0-9+.-]*:") ~= nil
end

function M.is_windows(path)
  check_string(path)
  return windows_shaped(path)
end

function M.is_absolute(path)
  check_string(path)
  local kind = path_kind(path)
  return kind == "posix_absolute" or kind == "drive_absolute" or kind == "unc"
end

function M.normalize(path, opts)
  check_string(path)
  opts = opts or {}
  if M.is_uri(path) then
    fail("URI is not a local path: " .. path)
  end

  local kind = path_kind(path)
  local windows = opts.windows
  if windows == nil then
    windows = windows_shaped(path)
  end

  if windows then
    path = path:gsub("\\", "/")
    kind = path_kind(path)
  end

  if kind == "unc" then
    path = path:gsub("\\", "/")
    local components = split_components(path:sub(3))
    if #components < 2 then
      fail("UNC path must include a server and share")
    end
    local server, share = components[1], components[2]
    local rest = {}
    for index = 3, #components do
      rest[#rest + 1] = components[index]
    end
    rest = normalize_components(rest, true)
    local normalized = "//" .. server .. "/" .. share
    if #rest > 0 then
      normalized = normalized .. "/" .. table.concat(rest, "/")
    end
    return normalized
  end

  if kind == "drive_absolute" then
    local drive = path:sub(1, 1):upper() .. ":/"
    local components = normalize_components(split_components(path:sub(4)), true)
    return drive .. table.concat(components, "/")
  end

  if kind == "drive_relative" then
    local drive = path:sub(1, 1):upper() .. ":"
    local components = normalize_components(split_components(path:sub(3)), false)
    if #components == 0 then
      return drive
    end
    return drive .. table.concat(components, "/")
  end

  if kind == "posix_absolute" then
    local components = normalize_components(split_components(path:sub(2)), true)
    return "/" .. table.concat(components, "/")
  end

  local components = normalize_components(split_components(path), false)
  if #components == 0 then
    return "."
  end
  return table.concat(components, "/")
end

function M.normalize_relative(path, opts)
  check_string(path)
  opts = opts or {}
  if path == "" then
    return ""
  end
  if M.is_uri(path) or M.is_absolute(path) or has_drive(path)
      or (opts.windows == true and path:sub(1, 1) == "\\") then
    fail("expected a root-relative local path: " .. path)
  end

  local normalized = M.normalize(path, { windows = opts.windows == true })
  if normalized == "." then
    return ""
  end
  return normalized
end

function M.equal(left, right, opts)
  check_string(left, "left path")
  check_string(right, "right path")
  opts = opts or {}
  local windows = opts.windows
  if windows == nil then
    windows = windows_shaped(left) or windows_shaped(right)
  end
  local normalized_left = M.normalize(left, { windows = windows })
  local normalized_right = M.normalize(right, { windows = windows })
  if windows then
    return ascii_lower(normalized_left) == ascii_lower(normalized_right)
  end
  return normalized_left == normalized_right
end

local function same_component(left, right, windows)
  if windows then
    return ascii_lower(left) == ascii_lower(right)
  end
  return left == right
end

function M.contains(root, target)
  check_string(root, "root")
  check_string(target, "target")
  if not M.is_absolute(root) then
    fail("root must be absolute")
  end

  local windows = windows_shaped(root)
  local normalized_root = M.normalize(root, { windows = windows })
  local normalized_target = M.normalize(target, { windows = windows })
  if not M.is_absolute(normalized_target) then
    return false
  end

  local root_parts = parse_normalized(normalized_root)
  local target_parts = parse_normalized(normalized_target)
  if root_parts.kind ~= target_parts.kind then
    return false
  end
  if not same_component(root_parts.volume, target_parts.volume, windows) then
    return false
  end
  if #target_parts.components < #root_parts.components then
    return false
  end
  for index, component in ipairs(root_parts.components) do
    if not same_component(component, target_parts.components[index], windows) then
      return false
    end
  end
  return true
end

function M.relative(root, target)
  if not M.contains(root, target) then
    return nil
  end
  local windows = windows_shaped(root)
  local root_parts = parse_normalized(M.normalize(root, { windows = windows }))
  local target_parts = parse_normalized(M.normalize(target, { windows = windows }))
  local result = {}
  for index = #root_parts.components + 1, #target_parts.components do
    result[#result + 1] = target_parts.components[index]
  end
  return table.concat(result, "/")
end

function M.resolve(root, relative)
  check_string(root, "root")
  check_string(relative, "relative path")
  if not M.is_absolute(root) then
    fail("root must be absolute")
  end
  local windows = windows_shaped(root)
  local normalized_root = M.normalize(root, { windows = windows })
  local normalized_relative = M.normalize_relative(relative, { windows = windows })
  if normalized_relative == "" then
    return normalized_root
  end
  local separator = normalized_root:sub(-1) == "/" and "" or "/"
  return M.normalize(normalized_root .. separator .. normalized_relative, { windows = windows })
end

function M.edit_target(root, target)
  check_string(root, "root")
  check_string(target, "editable target")
  if target == "" then
    fail("editable target must not be empty")
  end
  if M.is_uri(target) or M.is_absolute(target) or has_drive(target) then
    fail("editable target must be root-relative")
  end

  local windows = windows_shaped(root)
  local relative = M.normalize_relative(target, { windows = windows })
  if relative == "" then
    fail("editable target must not name the root")
  end
  if relative == ".." or relative:sub(1, 3) == "../" then
    fail("editable target escapes the root")
  end

  local absolute = M.resolve(root, relative)
  if not M.contains(root, absolute) then
    fail("editable target escapes the root")
  end
  return absolute, relative
end

local function parent_and_name(path)
  local normalized = M.normalize(path)
  local parsed = parse_normalized(normalized)
  if #parsed.components == 0 then
    fail("path root has no sibling name")
  end
  local name = parsed.components[#parsed.components]
  local parent_components = vim.list_slice(parsed.components, 1, #parsed.components - 1)
  local parent
  if parsed.kind == "posix_absolute" then
    parent = "/" .. table.concat(parent_components, "/")
  elseif parsed.kind == "drive_absolute" then
    parent = parsed.volume .. "/" .. table.concat(parent_components, "/")
  elseif parsed.kind == "unc" then
    parent = parsed.volume
    if #parent_components > 0 then
      parent = parent .. "/" .. table.concat(parent_components, "/")
    end
  elseif parsed.kind == "drive_relative" then
    parent = parsed.volume .. table.concat(parent_components, "/")
  else
    parent = table.concat(parent_components, "/")
    if parent == "" then
      parent = "."
    end
  end
  return M.normalize(parent), name
end

local function is_occupied(candidate, occupied)
  if occupied == nil then
    return false
  end
  if type(occupied) == "function" then
    return occupied(candidate) == true
  end
  if type(occupied) ~= "table" then
    fail("occupied paths must be a function or table")
  end
  for key, value in pairs(occupied) do
    local known = type(key) == "string" and value and key or value
    if type(known) == "string" and M.equal(candidate, known) then
      return true
    end
  end
  return false
end

function M.temporary_sibling(path, occupied, token)
  check_string(path)
  if token == nil then
    temp_counter = temp_counter + 1
    token = string.format("%x-%d", vim.uv.hrtime(), temp_counter)
  end
  check_string(token, "temporary token")
  if token == "" or token:find("[\\/]") then
    fail("temporary token must be a non-empty path component")
  end

  local parent, name = parent_and_name(path)
  local stem = "." .. name .. ".fre-tmp-" .. token
  local suffix = 0
  while true do
    local candidate_name = stem .. (suffix == 0 and "" or "-" .. suffix)
    local candidate = M.resolve(parent, candidate_name)
    if not is_occupied(candidate, occupied) then
      return candidate
    end
    suffix = suffix + 1
  end
end

function M.absolute(path, cwd)
  check_string(path)
  if M.is_uri(path) then
    fail("URI is not a local path: " .. path)
  end
  local windows = windows_shaped(path) or (cwd and windows_shaped(cwd))
  if M.is_absolute(path) then
    return M.normalize(path, { windows = windows })
  end
  cwd = cwd or vim.fn.getcwd()
  check_string(cwd, "cwd")
  if not M.is_absolute(cwd) then
    cwd = vim.fn.fnamemodify(cwd, ":p")
  end
  cwd = M.normalize(cwd, { windows = windows })
  if path_kind(path) == "drive_relative" then
    local drive = path:sub(1, 2)
    if cwd:sub(1, 2):lower() ~= drive:lower() then
      fail("drive-relative root is not on the current drive: " .. path)
    end
    path = path:sub(3)
  end
  return M.resolve(cwd, M.normalize_relative(path, { windows = windows }))
end

return M
