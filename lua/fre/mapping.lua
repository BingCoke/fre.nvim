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
  local instance = expected_instance
  if instance == nil then instance = require("fre").get_instance() end
  local bufnr = vim.api.nvim_get_current_buf()
  if not instance or bufnr ~= instance.bufnr or instance:is_destroying()
      or instance:is_destroyed() or not vim.api.nvim_buf_is_valid(instance.bufnr) then
    fail("current buffer is not a live Fre instance", 2)
  end
  local winid = vim.api.nvim_get_current_win()
  local source_view = instance:inspect_view({ winid = winid })
  if not source_view then fail("current window is not a live Fre View", 2) end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local mode = vim.api.nvim_get_mode().mode
  local row_number, col = cursor[1], cursor[2]
  local inspected = instance:inspect_action_row(
    row_number, opts.allow_undecodable_row == true
  )
  return {
    instance = instance,
    bufnr = bufnr,
    winid = winid,
    tabpage = vim.api.nvim_win_get_tabpage(winid),
    view = source_view,
    mode = mode,
    row = row_number,
    col = col,
    row_kind = inspected.row_kind,
    navigation_kind = inspected.navigation_kind,
    source_instance_id = inspected.source_instance_id,
    entry = inspected.entry,
    path_range = inspected.path_range,
    range = visual_range(mode, row_number, col),
  }
end

local function mapping_base()
  local actions = require("fre.actions")
  local function toggle_detail_columns(ctx)
    local ids = {}
    for _, column in ipairs(ctx.instance:get_columns()) do
      if column.id ~= "icon" then ids[#ids + 1] = column.id end
    end
    return actions.toggle_columns(ctx, ids)
  end
  return {
    n = {
      ["<CR>"] = actions.select,
      ["zv"] = actions.expand,
      ["zc"] = actions.collapse,
      ["za"] = actions.toggle_expand,
      ["zM"] = actions.collapse_all,
      ["q"] = actions.hidden,
      ["g."] = actions.toggle_hidden_file,
      ["gC"] = toggle_detail_columns,
      ["R"] = actions.refresh,
      ["]n"] = actions.create_child,
      ["]N"] = actions.create_root,
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

function M.setup(instance, opts)
  opts = opts or {}
  local actions = require("fre.actions")
  local allow_undecodable_row = {
    [actions.jump_to_path] = true,
    [actions.collapse_all] = true,
  }
  local base = opts.use_mapping_default and mapping_base() or {}
  local installed_maps = overlay(base, copy_maps(opts.mapping))
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
end

return M
