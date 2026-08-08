local columns = require("fre.columns")
local fs_path = require("fre.path")
local layout = require("fre.layout")

local M = {}

local function fail(message, level)
  error("fre.config: " .. message, level or 3)
end

local function copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local result = {}
  seen[value] = result
  for key, item in next, value do
    result[copy(key, seen)] = copy(item, seen)
  end
  return result
end

M.copy = copy

local function ascii_lower(value)
  return (value:gsub("[A-Z]", function(char)
    return string.char(char:byte() + 32)
  end))
end

local function builtin_sort(_, a, b)
  local a_directory = a.kind == "directory"
  local b_directory = b.kind == "directory"
  if a_directory ~= b_directory then
    return a_directory
  end
  local a_lower = ascii_lower(a.name)
  local b_lower = ascii_lower(b.name)
  if a_lower ~= b_lower then
    return a_lower < b_lower
  end
  return a.name < b.name
end

local function builtins()
  return {
    default_file_explorer = true,
    hidden_file = false,
    skip_confirm_for_simple_edits = false,
    auto_expand_single_directory = false,
    sort = builtin_sort,
    columns = {
      columns.icon(),
      columns.permissions(),
      columns.size(),
      columns.mtime({ format = "%Y-%m-%d %H:%M" }),
    },
    hidden_columns = {},
    layout = {
      position = "left",
      size = 40,
    },
    use_mapping_default = true,
    mapping = {},
    buffer = {
      options = {
        buftype = "acwrite",
        bufhidden = "hide",
        swapfile = false,
        buflisted = false,
      },
      variables = {},
    },
    window = {
      options = {
        wrap = false,
        number = false,
        relativenumber = false,
        signcolumn = "no",
        conceallevel = 3,
        concealcursor = "nvic",
      },
    },
  }
end

function M.builtins()
  return copy(builtins())
end

local function expect_table(value, path)
  if type(value) ~= "table" then
    fail(path .. " must be a table")
  end
end

local function expect_type(value, expected, path)
  if type(value) ~= expected then
    fail(path .. " must be a " .. expected)
  end
end


local function check_known_keys(value, allowed, path)
  for key in next, value do
    if type(key) ~= "string" or not allowed[key] then
      fail(path .. " contains unknown field " .. tostring(key))
    end
  end
end

local function sequence_length(value, path)
  expect_table(value, path)
  local count = 0
  local maximum = 0
  for key in next, value do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      fail(path .. " must be a proper sequential array")
    end
    count = count + 1
    if key > maximum then
      maximum = key
    end
  end
  if count ~= maximum then
    fail(path .. " must not contain nil holes")
  end
  return maximum
end

local function normalize_expanded(value, field, root)
  local length = sequence_length(value, field)
  local windows = root ~= nil and fs_path.is_windows(root) or false
  local result = {}
  for index = 1, length do
    local item_path = field .. "[" .. index .. "]"
    expect_type(value[index], "string", item_path)
    local ok, relative = pcall(fs_path.normalize_relative, value[index], { windows = windows })
    if not ok or relative == "" or relative == ".."
        or relative:sub(1, 3) == "../" then
      fail(item_path .. " must be a non-empty root-relative local path")
    end
    result[index] = relative
  end
  return result
end

local function validate_named_map(value, path, validate_value)
  expect_table(value, path)
  for key, item in next, value do
    if type(key) ~= "string" then
      fail(path .. " keys must be strings")
    end
    if validate_value then
      validate_value(item, path .. "." .. key)
    end
  end
end

local function validate_option(value, path)
  local kind = type(value)
  if kind ~= "boolean" and kind ~= "number" and kind ~= "string" then
    fail(path .. " must be a boolean, number, or string")
  end
end

local function validate_variable(value, path, active)
  local kind = type(value)
  if kind == "boolean" or kind == "number" or kind == "string" then
    return
  end
  if kind ~= "table" then
    fail(path .. " contains unsupported " .. kind .. " value")
  end
  if active[value] then
    fail(path .. " contains a cycle")
  end
  active[value] = true

  local has_number = false
  local has_string = false
  local count = 0
  local maximum = 0
  for key in next, value do
    local key_kind = type(key)
    if key_kind == "number" then
      has_number = true
      if key < 1 or key % 1 ~= 0 then
        fail(path .. " array keys must be positive integers")
      end
      count = count + 1
      if key > maximum then
        maximum = key
      end
    elseif key_kind == "string" then
      has_string = true
    else
      fail(path .. " keys must be array indexes or strings")
    end
  end
  if has_number and has_string then
    fail(path .. " must not mix array and record keys")
  end
  if has_number and count ~= maximum then
    fail(path .. " must not contain nil holes")
  end
  for key, item in next, value do
    validate_variable(item, path .. "." .. tostring(key), active)
  end
  active[value] = nil
end

local function validate_variables(value, path)
  validate_named_map(value, path)
  if value.fre ~= nil then
    fail(path .. ".fre is reserved")
  end
  local active = {}
  for key, item in next, value do
    validate_variable(item, path .. "." .. key, active)
  end
end

local function validate_mapping(value, path, active)
  active = active or {}
  expect_table(value, path)
  if active[value] then
    fail(path .. " contains a cycle")
  end
  active[value] = true
  for mode, mode_map in next, value do
    if type(mode) ~= "string" then
      fail(path .. " mode names must be strings")
    end
    expect_table(mode_map, path .. "." .. mode)
    validate_named_map(mode_map, path .. "." .. mode, function(handler, handler_path)
      expect_type(handler, "function", handler_path)
    end)
  end
  active[value] = nil
end

local function validate_layout(value, path, effective)
  local opts = { path = path, partial = not effective }
  local ok, err = pcall(layout.normalize, value, opts)
  if not ok then fail(tostring(err):gsub("^fre%.layout:%s*", ""), 4) end
end

local function validate_columns(value, path)
  expect_table(value, path)
  local ok, err = pcall(columns.validate, value, path)
  if not ok then fail(tostring(err):gsub("^fre%.columns:%s*", ""), 4) end
end

local function validate_hidden_columns(value, path, descriptors)
  local length = sequence_length(value, path)
  local configured = {}
  for _, descriptor in ipairs(descriptors) do configured[descriptor.id] = true end
  local seen = {}
  for index = 1, length do
    local item_path = path .. "[" .. index .. "]"
    local id = value[index]
    expect_type(id, "string", item_path)
    if seen[id] then fail(path .. " contains duplicate column id " .. id) end
    if not configured[id] then fail(path .. " contains unknown column id " .. id) end
    seen[id] = true
  end
end

local function validate_buffer(value, path)
  expect_table(value, path)
  check_known_keys(value, { options = true, variables = true }, path)
  if value.options ~= nil then
    validate_named_map(value.options, path .. ".options", validate_option)
  end
  if value.variables ~= nil then
    validate_variables(value.variables, path .. ".variables")
  end
end

local function validate_window(value, path)
  expect_table(value, path)
  check_known_keys(value, { options = true }, path)
  if value.options ~= nil then
    validate_named_map(value.options, path .. ".options", validate_option)
    if value.options.winfixbuf == true then
      fail(path .. ".options.winfixbuf must not be true")
    end
  end
end


local setup_fields = {
  default_file_explorer = true,
  hidden_file = true,
  skip_confirm_for_simple_edits = true,
  auto_expand_single_directory = true,
  sort = true,
  columns = true,
  hidden_columns = true,
  layout = true,
  use_mapping_default = true,
  mapping = true,
  buffer = true,
  window = true,
}

local new_fields = {
  root = true,
  hidden_file = true,
  skip_confirm_for_simple_edits = true,
  auto_expand_single_directory = true,
  sort = true,
  expanded = true,
  columns = true,
  hidden_columns = true,
  layout = true,
  use_mapping_default = true,
  mapping = true,
  buffer = true,
  window = true,
}

local function merge_named(base, override)
  local result = copy(base)
  if override then
    for key, value in next, override do
      result[key] = copy(value)
    end
  end
  return result
end

local function merge_mapping(base, override)
  local result = copy(base)
  if override then
    for mode, mode_map in next, override do
      result[mode] = merge_named(result[mode] or {}, mode_map)
    end
  end
  return result
end


local function validate_common(config, setup)
  expect_type(config.hidden_file, "boolean", "hidden_file")
  expect_type(config.skip_confirm_for_simple_edits, "boolean", "skip_confirm_for_simple_edits")
  expect_type(config.auto_expand_single_directory, "boolean", "auto_expand_single_directory")
  expect_type(config.sort, "function", "sort")
  validate_columns(config.columns, "columns")
  validate_hidden_columns(config.hidden_columns, "hidden_columns", config.columns)
  expect_type(config.use_mapping_default, "boolean", "use_mapping_default")
  validate_mapping(config.mapping, "mapping")
  validate_layout(config.layout, "layout", true)
  validate_buffer(config.buffer, "buffer")
  validate_window(config.window, "window")
  if setup then
    expect_type(config.default_file_explorer, "boolean", "default_file_explorer")
  end
end

function M.resolve_setup(opts, ignore_default_file_explorer)
  opts = opts or {}
  expect_table(opts, "setup options")
  check_known_keys(opts, setup_fields, "setup options")

  local result = builtins()
  if opts.columns ~= nil then
    validate_columns(opts.columns, "columns")
  end
  if opts.mapping ~= nil then
    validate_mapping(opts.mapping, "mapping")
  end
  if opts.layout ~= nil then
    validate_layout(opts.layout, "layout")
  end
  if opts.buffer ~= nil then
    validate_buffer(opts.buffer, "buffer")
  end
  if opts.window ~= nil then
    validate_window(opts.window, "window")
  end
  if opts.default_file_explorer ~= nil and not ignore_default_file_explorer then
    result.default_file_explorer = copy(opts.default_file_explorer)
  end
  if opts.hidden_file ~= nil then
    result.hidden_file = copy(opts.hidden_file)
  end
  if opts.skip_confirm_for_simple_edits ~= nil then
    result.skip_confirm_for_simple_edits = copy(opts.skip_confirm_for_simple_edits)
  end
  if opts.auto_expand_single_directory ~= nil then
    result.auto_expand_single_directory = copy(opts.auto_expand_single_directory)
  end
  if opts.sort ~= nil then
    result.sort = opts.sort
  end
  if opts.columns ~= nil then
    result.columns = copy(opts.columns)
  end
  if opts.hidden_columns ~= nil then
    result.hidden_columns = copy(opts.hidden_columns)
  end
  if opts.use_mapping_default ~= nil then
    result.use_mapping_default = copy(opts.use_mapping_default)
  end
  result.mapping = merge_mapping(result.mapping, opts.mapping)
  local layout_ok, layout_result = pcall(
    layout.merge, result.layout, opts.layout, { path = "layout" }
  )
  if not layout_ok then fail(tostring(layout_result):gsub("^fre%.layout:%s*", ""), 3) end
  result.layout = layout_result


  if opts.buffer ~= nil then
    expect_table(opts.buffer, "buffer")
    check_known_keys(opts.buffer, { options = true, variables = true }, "buffer")
    result.buffer.options = merge_named(result.buffer.options, opts.buffer.options)
    result.buffer.variables = merge_named(result.buffer.variables, opts.buffer.variables)
  end
  if opts.window ~= nil then
    expect_table(opts.window, "window")
    check_known_keys(opts.window, { options = true }, "window")
    result.window.options = merge_named(result.window.options, opts.window.options)
  end

  validate_common(result, true)
  return copy(result)
end

function M.resolve_instance(setup_defaults, opts, normalized_root)
  expect_table(setup_defaults, "setup defaults")
  opts = opts or {}
  expect_table(opts, "new options")
  if opts.default_file_explorer ~= nil then
    fail("default_file_explorer is setup-only")
  end
  check_known_keys(opts, new_fields, "new options")
  if opts.root ~= nil then
    expect_type(opts.root, "string", "root")
  end
  if opts.columns ~= nil then
    validate_columns(opts.columns, "columns")
  end
  if opts.mapping ~= nil then
    validate_mapping(opts.mapping, "mapping")
  end
  if opts.layout ~= nil then
    validate_layout(opts.layout, "layout")
  end
  if opts.buffer ~= nil then
    validate_buffer(opts.buffer, "buffer")
  end
  if opts.window ~= nil then
    validate_window(opts.window, "window")
  end
  local expanded = normalize_expanded(opts.expanded or {}, "expanded", normalized_root)
  local result = {
    hidden_file = copy(setup_defaults.hidden_file),
    skip_confirm_for_simple_edits = copy(setup_defaults.skip_confirm_for_simple_edits),
    auto_expand_single_directory = copy(setup_defaults.auto_expand_single_directory),
    sort = setup_defaults.sort,
    expanded = expanded,
    columns = copy(setup_defaults.columns),
    hidden_columns = copy(setup_defaults.hidden_columns),
    layout = copy(setup_defaults.layout),
    use_mapping_default = copy(setup_defaults.use_mapping_default),
    mapping = copy(setup_defaults.mapping),
    buffer = copy(setup_defaults.buffer),
    window = copy(setup_defaults.window),
  }
  if opts.hidden_file ~= nil then
    result.hidden_file = copy(opts.hidden_file)
  end
  if opts.skip_confirm_for_simple_edits ~= nil then
    result.skip_confirm_for_simple_edits = copy(opts.skip_confirm_for_simple_edits)
  end
  if opts.auto_expand_single_directory ~= nil then
    result.auto_expand_single_directory = copy(opts.auto_expand_single_directory)
  end
  if opts.sort ~= nil then
    result.sort = opts.sort
  end
  if opts.columns ~= nil then
    result.columns = copy(opts.columns)
  end
  if opts.hidden_columns ~= nil then
    result.hidden_columns = copy(opts.hidden_columns)
  end
  if opts.use_mapping_default ~= nil then
    result.use_mapping_default = copy(opts.use_mapping_default)
  end
  result.mapping = merge_mapping(result.mapping, opts.mapping)
  local layout_ok, layout_result = pcall(
    layout.merge, result.layout, opts.layout, { path = "layout" }
  )
  if not layout_ok then fail(tostring(layout_result):gsub("^fre%.layout:%s*", ""), 3) end
  result.layout = layout_result

  if opts.buffer ~= nil then
    expect_table(opts.buffer, "buffer")
    check_known_keys(opts.buffer, { options = true, variables = true }, "buffer")
    result.buffer.options = merge_named(result.buffer.options, opts.buffer.options)
    result.buffer.variables = merge_named(result.buffer.variables, opts.buffer.variables)
  end
  if opts.window ~= nil then
    expect_table(opts.window, "window")
    check_known_keys(opts.window, { options = true }, "window")
    result.window.options = merge_named(result.window.options, opts.window.options)
  end

  validate_common(result, false)
  return copy(result)
end

return M
