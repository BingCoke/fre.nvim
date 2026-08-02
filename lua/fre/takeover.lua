local path = require("fre.path")
local window = require("fre.window")

local M = {
  augroup_name = "FreDefaultExplorer",
}

local Takeover = {}
Takeover.__index = Takeover

local function create_instance(manager, root)
  return manager:create_instance({ root = root })
end

local function replace_window(instance, winid)
  local previous_bufnr = vim.api.nvim_win_get_buf(winid)
  local finish_capture = instance:capture_view_errors()
  local ok, previous = pcall(window.install, instance, winid)
  local enter_err = finish_capture()
  if not ok then error(previous, 0) end
  instance:adopt_view(winid, {
    layout = { position = "current" },
    origin_winid = winid,
    mode = "restore",
    previous_bufnr = previous_bufnr,
  })
  instance:place_initial_cursor(winid)
  if enter_err then error(enter_err, 0) end
  return winid
end

local function valid_views(bufnr)
  local result = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == bufnr then
      result[#result + 1] = winid
    end
  end
  return result
end

function Takeover:_destroy_failed_child(child)
  if #valid_views(child.bufnr) == 0 then
    pcall(child.destroy, child)
  end
end

function Takeover:_take_over(bufnr, winid, name)
  if vim.bo[bufnr].modified then
    error("fre: cannot take over a modified directory buffer", 0)
  end

  local root = path.absolute(name)
  local child = self._create_instance(self.manager, root)
  local replaced, replace_err = pcall(self._replace_window, child, winid)
  local replacement_visible = vim.api.nvim_win_is_valid(winid)
    and vim.api.nvim_win_get_buf(winid) == child.bufnr

  if not replaced or not replacement_visible then
    self:_destroy_failed_child(child)
    if not replaced then error(replace_err, 0) end
    error("fre: failed to replace directory buffer", 0)
  end

  if #valid_views(bufnr) == 0 and vim.api.nvim_buf_is_valid(bufnr) then
    self._delete_source(bufnr)
  end
  return child
end

function Takeover:_check(bufnr, winid)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then return nil end
  if winid ~= vim.api.nvim_get_current_win()
      or vim.api.nvim_win_get_buf(winid) ~= bufnr then return nil end

  local owned = self.manager:find_by_buf(bufnr)
  if owned and not owned:is_destroying() and not owned:is_destroyed() then return nil end
  local has_reserved_variable = pcall(vim.api.nvim_buf_get_var, bufnr, "fre")
  if has_reserved_variable then return nil end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or path.is_uri(name) then return nil end
  if vim.fn.isdirectory(name) == 0 then return nil end
  return self:_take_over(bufnr, winid, name)
end

function Takeover:check(bufnr, winid)
  if type(bufnr) == "number" and self._checking[bufnr] then return nil end
  if type(bufnr) == "number" then self._checking[bufnr] = true end
  local ok, result = xpcall(function()
    return self:_check(bufnr, winid)
  end, function(err)
    return err
  end)
  if type(bufnr) == "number" then self._checking[bufnr] = nil end
  if not ok then error(result, 0) end
  return result
end

function Takeover:enable()
  if self._enabled then return false end

  vim.g.loaded_netrw = 1
  vim.g.loaded_netrwPlugin = 1
  pcall(vim.api.nvim_clear_autocmds, { group = "FileExplorer" })

  self._augroup = vim.api.nvim_create_augroup(M.augroup_name, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = self._augroup,
    desc = "Fre default directory explorer takeover",
    callback = function(args)
      local winid = vim.api.nvim_get_current_win()
      self:check(args.buf, winid)
    end,
  })
  self._enabled = true

  local winid = vim.api.nvim_get_current_win()
  return self:check(vim.api.nvim_win_get_buf(winid), winid)
end

function M.new(manager)
  return setmetatable({
    manager = manager,
    _checking = {},
    _enabled = false,
    _create_instance = create_instance,
    _replace_window = replace_window,
    _delete_source = function(bufnr)
      vim.api.nvim_buf_delete(bufnr, {})
    end,
  }, Takeover)
end

return M
