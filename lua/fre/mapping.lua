local buffer = require("fre.buffer")
local manager_module = require("fre.manager")
local view = require("fre.view")

local M = {}

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function visual_mode(mode)
  return mode == "v" or mode == "V" or mode == string.char(22)
end

local function position(row, col)
  return { row = row, col = col }
end

local function visual_range(mode, row, col)
  if not visual_mode(mode) then return nil end
  local anchor = vim.fn.getpos("v")
  local anchor_row = anchor[2]
  local anchor_col = math.max(0, anchor[3] - 1)
  if anchor_row < row or (anchor_row == row and anchor_col <= col) then
    return {
      start = position(anchor_row, anchor_col),
      finish = position(row, col),
    }
  end
  return {
    start = position(row, col),
    finish = position(anchor_row, anchor_col),
  }
end

local function owner_for(buffer)
  local instance = manager_module.default:find_by_buf(buffer.bufnr)
  if not instance or instance.buffer ~= buffer then
    fail("current buffer is not a live Fre instance", 2)
  end
  return instance
end

function M.context(expected_buffer, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local buffer
  local instance
  if expected_buffer ~= nil then
    buffer = expected_buffer
    if bufnr ~= buffer.bufnr then
      fail("current buffer does not match the mapped Fre instance", 2)
    end
    instance = owner_for(buffer)
  else
    instance = manager_module.default:find_by_buf(bufnr)
    if not instance then fail("current buffer is not a live Fre instance", 2) end
    buffer = instance.buffer
  end
  if instance:is_destroying() or instance:is_destroyed()
      or not vim.api.nvim_buf_is_valid(buffer.bufnr) then
    fail("current buffer is not a live Fre instance", 2)
  end

  local winid = vim.api.nvim_get_current_win()
  local source_view = view.source(instance, winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local mode = vim.api.nvim_get_mode().mode
  local row, col = cursor[1], cursor[2]
  local decoded
  if opts.allow_undecodable_row then
    local ok, value = pcall(buffer.decode, buffer, row)
    if ok then decoded = value end
  else
    decoded = buffer:decode(row)
  end
  return {
    instance = instance,
    bufnr = bufnr,
    winid = winid,
    tabpage = vim.api.nvim_win_get_tabpage(winid),
    view = source_view,
    mode = mode,
    row = row,
    col = col,
    row_kind = decoded and decoded.row_kind or nil,
    navigation_kind = decoded and decoded.navigation_kind or nil,
    source_instance_id = decoded and decoded.source_instance_id or nil,
    entry = decoded and decoded.entry or nil,
    path_range = decoded and decoded.path_range or nil,
    range = visual_range(mode, row, col),
  }
end

local function mapping_base()
  local actions = require("fre.actions")
  return {
    n = {
      ["<CR>"] = actions.select,
      ["zv"] = actions.expand,
      ["zc"] = actions.collapse,
      ["za"] = actions.toggle_expand,
      ["zM"] = actions.collapse_all,
      ["q"] = actions.hidden,
      ["g."] = actions.toggle_hidden_file,
      ["R"] = actions.refresh,
    },
    i = {},
    v = {},
  }
end

local function copy_maps(source)
  local result = {}
  for mode, mode_map in pairs(source or {}) do
    local copied = {}
    for lhs, handler in pairs(mode_map) do copied[lhs] = handler end
    result[mode] = copied
  end
  return result
end

local function overlay(base, override)
  local result = copy_maps(base)
  for mode, mode_map in pairs(override or {}) do
    result[mode] = result[mode] or {}
    for lhs, handler in pairs(mode_map) do result[mode][lhs] = handler end
  end
  return result
end

function M.setup(buffer)
  if buffer.mapping_installed then fail("buffer mappings are already installed", 2) end
  local actions = require("fre.actions")
  local allow_undecodable_row = {
    [actions.jump_to_path] = true,
    [actions.collapse_all] = true,
  }
  local base = buffer.config.use_mapping_default and mapping_base() or {}
  local installed_maps = overlay(base, copy_maps(buffer.config.mapping))
  local installed = {}
  local ok, err = pcall(function()
    for mode, mode_map in pairs(installed_maps) do
      for lhs, handler in pairs(mode_map) do
        vim.keymap.set(mode, lhs, function()
          local context_opts = allow_undecodable_row[handler]
            and { allow_undecodable_row = true } or nil
          return handler(M.context(buffer, context_opts))
        end, {
          buffer = buffer.bufnr,
          nowait = true,
          silent = true,
        })
        installed[#installed + 1] = { mode = mode, lhs = lhs }
      end
    end
  end)
  if not ok then
    for index = #installed, 1, -1 do
      local item = installed[index]
      pcall(vim.keymap.del, item.mode, item.lhs, { buffer = buffer.bufnr })
    end
    error(err, 0)
  end
  buffer.installed_mappings = installed
  buffer.mapping_installed = true
end

function M.teardown(buffer)
  for index = #(buffer.installed_mappings or {}), 1, -1 do
    local item = buffer.installed_mappings[index]
    pcall(vim.keymap.del, item.mode, item.lhs, { buffer = buffer.bufnr })
  end
  buffer.installed_mappings = nil
  buffer.mapping_installed = nil
end

return M
