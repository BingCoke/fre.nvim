local columns = require("fre.columns")
local window = require("fre.window")

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
    sort = builtin_sort,
    columns = {
      columns.icon(),
      columns.permissions(),
      columns.size(),
      columns.mtime({ format = "%Y-%m-%d %H:%M" }),
    },
    gc = {
      ttl_ms = 60000,
      include_modified = false,
      default_group = "default",
      groups = {
        default = 10,
        project = 5,
      },
    },
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

local function expect_nonnegative_number(value, path)
  if type(value) ~= "number" or value < 0 then
    fail(path .. " must be a non-negative number")
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
  local ok, err = pcall(window.normalize, value, opts)
  if not ok then fail(tostring(err):gsub("^fre%.window:%s*", ""), 4) end
end

local function validate_columns(value, path)
  expect_table(value, path)
  local ok, err = pcall(columns.validate, value, path)
  if not ok then fail(tostring(err):gsub("^fre%.columns:%s*", ""), 4) end
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

local function validate_groups(value, path)
  validate_named_map(value, path, function(capacity, capacity_path)
    if type(capacity) ~= "number" or capacity < 0 or capacity % 1 ~= 0 then
      fail(capacity_path .. " must be a non-negative integer")
    end
  end)
end

local setup_fields = {
  default_file_explorer = true,
  hidden_file = true,
  sort = true,
  columns = true,
  gc = true,
  layout = true,
  use_mapping_default = true,
  mapping = true,
  buffer = true,
  window = true,
}

local new_fields = {
  root = true,
  inherit = true,
  hidden_file = true,
  sort = true,
  columns = true,
  gc = true,
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

local function merge_record(base, override, fields)
  local result = copy(base)
  if override then
    for field in next, fields do
      if override[field] ~= nil then
        result[field] = copy(override[field])
      end
    end
  end
  return result
end

local function validate_common(config, setup)
  expect_type(config.hidden_file, "boolean", "hidden_file")
  expect_type(config.sort, "function", "sort")
  validate_columns(config.columns, "columns")
  expect_type(config.use_mapping_default, "boolean", "use_mapping_default")
  validate_mapping(config.mapping, "mapping")
  validate_layout(config.layout, "layout", true)
  validate_buffer(config.buffer, "buffer")
  validate_window(config.window, "window")

  expect_nonnegative_number(config.gc.ttl_ms, "gc.ttl_ms")
  expect_type(config.gc.include_modified, "boolean", "gc.include_modified")
  if setup then
    expect_type(config.default_file_explorer, "boolean", "default_file_explorer")
    expect_type(config.gc.default_group, "string", "gc.default_group")
    if config.gc.default_group == "" then
      fail("gc.default_group must not be empty")
    end
    validate_groups(config.gc.groups, "gc.groups")
    if config.gc.groups[config.gc.default_group] == nil then
      fail("gc.default_group must name a configured group")
    end
  else
    expect_type(config.gc.group, "string", "gc.group")
    if config.gc.group == "" then
      fail("gc.group must not be empty")
    end
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
  if opts.sort ~= nil then
    result.sort = opts.sort
  end
  if opts.columns ~= nil then
    result.columns = copy(opts.columns)
  end
  if opts.use_mapping_default ~= nil then
    result.use_mapping_default = copy(opts.use_mapping_default)
  end
  result.mapping = merge_mapping(result.mapping, opts.mapping)
  local layout_ok, layout_result = pcall(window.merge_layout, result.layout, opts.layout, { path = "layout" })
  if not layout_ok then fail(tostring(layout_result):gsub("^fre%.window:%s*", ""), 3) end
  result.layout = layout_result

  if opts.gc ~= nil then
    expect_table(opts.gc, "gc")
    check_known_keys(opts.gc, {
      ttl_ms = true,
      include_modified = true,
      default_group = true,
      groups = true,
    }, "gc")
    if opts.gc.groups ~= nil then
      validate_groups(opts.gc.groups, "gc.groups")
    end
    result.gc = merge_record(result.gc, opts.gc, {
      ttl_ms = true,
      include_modified = true,
      default_group = true,
    })
    result.gc.groups = merge_named(result.gc.groups, opts.gc.groups)
  end

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

local function predecessor_sort(predecessor)
  if not predecessor then
    return nil
  end
  return predecessor.current_sort or predecessor.sort or (predecessor.config and predecessor.config.sort)
end

local function predecessor_hidden_file(predecessor)
  if not predecessor then
    return nil
  end
  if predecessor.current_hidden_file ~= nil then
    return predecessor.current_hidden_file
  end
  if predecessor.hidden_file ~= nil then
    return predecessor.hidden_file
  end
  if predecessor.config then
    return predecessor.config.hidden_file
  end
  return nil
end

function M.resolve_instance(setup_defaults, opts, predecessor)
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
  if opts.inherit ~= nil and type(opts.inherit) ~= "table" then
    fail("inherit must be an instance table")
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
  predecessor = predecessor or opts.inherit
  local result = {
    hidden_file = copy(setup_defaults.hidden_file),
    sort = setup_defaults.sort,
    columns = copy(setup_defaults.columns),
    gc = {
      ttl_ms = copy(setup_defaults.gc.ttl_ms),
      include_modified = copy(setup_defaults.gc.include_modified),
      group = copy(setup_defaults.gc.default_group),
    },
    layout = copy(setup_defaults.layout),
    use_mapping_default = copy(setup_defaults.use_mapping_default),
    mapping = copy(setup_defaults.mapping),
    buffer = copy(setup_defaults.buffer),
    window = copy(setup_defaults.window),
  }
  local inherited_sort = predecessor_sort(predecessor)
  if inherited_sort ~= nil then
    result.sort = inherited_sort
  end
  local inherited_hidden = predecessor_hidden_file(predecessor)
  if inherited_hidden ~= nil then
    result.hidden_file = copy(inherited_hidden)
  end
  if opts.hidden_file ~= nil then
    result.hidden_file = copy(opts.hidden_file)
  end
  if opts.sort ~= nil then
    result.sort = opts.sort
  end
  if opts.columns ~= nil then
    result.columns = copy(opts.columns)
  end
  if opts.use_mapping_default ~= nil then
    result.use_mapping_default = copy(opts.use_mapping_default)
  end
  result.mapping = merge_mapping(result.mapping, opts.mapping)
  local layout_ok, layout_result = pcall(window.merge_layout, result.layout, opts.layout, { path = "layout" })
  if not layout_ok then fail(tostring(layout_result):gsub("^fre%.window:%s*", ""), 3) end
  result.layout = layout_result

  if opts.gc ~= nil then
    expect_table(opts.gc, "gc")
    check_known_keys(opts.gc, {
      ttl_ms = true,
      include_modified = true,
      group = true,
    }, "gc")
    result.gc = merge_record(result.gc, opts.gc, {
      ttl_ms = true,
      include_modified = true,
      group = true,
    })
  end
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
  if setup_defaults.gc.groups[result.gc.group] == nil then
    fail("gc.group names an unknown group: " .. result.gc.group)
  end
  return copy(result)
end

return M
