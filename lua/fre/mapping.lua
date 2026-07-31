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

function M.context(expected_instance, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local instance
  if expected_instance ~= nil then
    instance = expected_instance
    if bufnr ~= instance.bufnr then
      fail("current buffer does not match the mapped Fre instance", 2)
    end
    if instance._destroyed
        or instance.state == "destroying" or instance.state == "destroyed"
        or not vim.api.nvim_buf_is_valid(instance.bufnr)
        or instance.manager:find_by_buf(bufnr) ~= instance then
      fail("current buffer is not a live Fre instance", 2)
    end
  else
    instance = manager_module.default:find_by_buf(bufnr)
    if not instance or instance._destroyed
        or instance.state == "destroying" or instance.state == "destroyed"
        or not vim.api.nvim_buf_is_valid(instance.bufnr) then
      fail("current buffer is not a live Fre instance", 2)
    end
  end

  local winid = vim.api.nvim_get_current_win()
  local source_view = view.source(instance, winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local mode = vim.api.nvim_get_mode().mode
  local row, col = cursor[1], cursor[2]
  local decoded
  if opts.allow_undecodable_row then
    local ok, value = pcall(buffer.decode, instance, row)
    if ok then decoded = value end
  else
    decoded = buffer.decode(instance, row)
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

function M.setup(instance)
  if instance._mapping_installed then fail("instance mappings are already installed", 2) end
  local actions = require("fre.actions")
  local allow_undecodable_row = {
    [actions.jump_to_path] = true,
    [actions.collapse_all] = true,
  }
  local base = instance.config.use_mapping_default and mapping_base() or {}
  local installed_maps = overlay(base, copy_maps(instance.config.mapping))
  local installed = {}
  local ok, err = pcall(function()
    for mode, mode_map in pairs(installed_maps) do
      for lhs, handler in pairs(mode_map) do
        vim.keymap.set(mode, lhs, function()
          local context_opts = allow_undecodable_row[handler]
            and { allow_undecodable_row = true } or nil
          return handler(M.context(instance, context_opts))
        end, {
          buffer = instance.bufnr,
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
      pcall(vim.keymap.del, item.mode, item.lhs, { buffer = instance.bufnr })
    end
    error(err, 0)
  end
  instance._installed_mappings = installed
  instance._mapping_installed = true
end

function M.teardown(instance)
  for index = #(instance._installed_mappings or {}), 1, -1 do
    local item = instance._installed_mappings[index]
    pcall(vim.keymap.del, item.mode, item.lhs, { buffer = instance.bufnr })
  end
  instance._installed_mappings = nil
  instance._mapping_installed = nil
end

return M
