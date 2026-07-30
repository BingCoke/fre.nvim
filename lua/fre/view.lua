local layout = require("fre.layout")
local window = require("fre.window")

local M = {}

local function fail(message, level)
  error("fre.view: " .. message, level or 3)
end

local function copy(value)
  return vim.deepcopy(value)
end

local function valid_window(tabpage, winid, ordinary)
  return type(winid) == "number"
    and vim.api.nvim_win_is_valid(winid)
    and vim.api.nvim_win_get_tabpage(winid) == tabpage
    and (not ordinary or not window.is_float(winid))
end

local function first_ordinary(tabpage)
  local ordinary = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if valid_window(tabpage, winid, true) then ordinary[#ordinary + 1] = winid end
  end
  table.sort(ordinary)
  return ordinary[1]
end

local function resolve_anchor(record, tabpage, caller_win, normalized)
  if normalized.position == "current" then
    local anchor = record and record.origin_winid or caller_win
    if not valid_window(tabpage, anchor, false) then
      fail("active View origin is not valid in the current tab", 4)
    end
    return anchor
  end
  if normalized.position == "float" then return nil end
  local anchor = caller_win
  if record then
    anchor = window.is_float(record.winid) and record.origin_winid or record.winid
    if not valid_window(tabpage, anchor, true) then
      fail("active View has no valid ordinary split anchor", 4)
    end
    return anchor
  end
  if valid_window(tabpage, anchor, true) then return anchor end
  anchor = first_ordinary(tabpage)
  if not anchor then fail("current tab has no ordinary split anchor", 4) end
  return anchor
end

local function valid_record(instance, tabpage, record)
  return type(record) == "table"
    and vim.api.nvim_tabpage_is_valid(tabpage)
    and type(record.winid) == "number"
    and vim.api.nvim_win_is_valid(record.winid)
    and vim.api.nvim_win_get_tabpage(record.winid) == tabpage
    and vim.api.nvim_buf_is_valid(instance.bufnr)
    and vim.api.nvim_win_get_buf(record.winid) == instance.bufnr
end

local function prune_invalid(instance)
  local removed = false
  for tabpage, record in pairs(instance._views or {}) do
    if not valid_record(instance, tabpage, record) then
      instance._views[tabpage] = nil
      removed = true
    end
  end
  return removed
end

local function defer_reconsider(instance)
  pcall(instance.manager.gc_reconsider, instance.manager, instance, true)
end

local function notify_leave_if_empty(instance, best_effort)
  if next(instance._views or {}) ~= nil then return end
  if best_effort == false then
    instance:_on_presentation_leave()
    return
  end
  local ok, err = pcall(instance._on_presentation_leave, instance)
  if ok then return end
  pcall(instance._report_async_error, instance,
    "presentation leave failed: " .. tostring(err))
  defer_reconsider(instance)
end

local function active(instance, tabpage, best_effort_leave)
  local record = instance._views and instance._views[tabpage]
  if not record then return nil end
  if valid_record(instance, tabpage, record) then return record end
  prune_invalid(instance)
  notify_leave_if_empty(instance, best_effort_leave ~= false)
  return nil
end

local function notify_open(instance)
  instance:_on_presentation_enter()
end

local function make_record(winid, origin_winid, requested, mode, previous_bufnr)
  return {
    winid = winid,
    origin_winid = origin_winid,
    layout = copy(requested),
    mode = mode,
    previous_bufnr = previous_bufnr,
  }
end

local function register_adopted_record(instance, winid, previous_bufnr)
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  if instance._views[tabpage] ~= nil then
    fail("instance already has an active View in the target tab", 3)
  end
  instance._views[tabpage] = make_record(
    winid, winid, layout.normalize({ position = "current" }), "restore", previous_bufnr
  )
  return tabpage
end

local function remove_record(instance, tabpage, record)
  if not valid_record(instance, tabpage, record) then
    instance._views[tabpage] = nil
    return true
  end
  local removed, err = window.remove(
    instance, record.winid, record.mode, record.previous_bufnr
  )
  if not removed then return false, err end
  if instance._views[tabpage] == record then instance._views[tabpage] = nil end
  return true
end

function M.inspect(instance, tabpage)
  if type(instance) ~= "table" or type(instance.bufnr) ~= "number" then
    fail("instance is not valid", 2)
  end
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if type(tabpage) ~= "number" then return nil end
  local record = active(instance, tabpage)
  if not record then return nil end
  return {
    winid = record.winid,
    origin_winid = record.origin_winid,
    layout = copy(record.layout),
  }
end

function M.select(instance, tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local record = active(instance, tabpage)
  return record and record.winid or nil
end

function M.owner(manager, winid)
  if type(manager) ~= "table" or type(manager.find_by_buf) ~= "function" then
    fail("manager is not valid", 2)
  end
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    fail("target window is not valid", 2)
  end
  local candidate = manager:find_by_buf(vim.api.nvim_win_get_buf(winid))
  if not candidate then return nil end
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  local record = active(candidate, tabpage)
  if not record or record.winid ~= winid then return nil end
  return candidate
end

function M.detach(instance, winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    fail("target window is not valid", 2)
  end
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  local record = instance._views and instance._views[tabpage]
  if not record or record.winid ~= winid then return false end
  instance._views[tabpage] = nil
  notify_leave_if_empty(instance, false)
  return true
end

function M.transfer(previous_owner, child, winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= child.bufnr then
    fail("target window does not display the child instance", 2)
  end
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  local record = previous_owner._views and previous_owner._views[tabpage]
  if not record or record.winid ~= winid then
    fail("target window no longer has the captured managed owner", 2)
  end
  if child._views[tabpage] ~= nil then
    fail("child already has an active View in the target tab", 2)
  end
  previous_owner._views[tabpage] = nil
  child._views[tabpage] = make_record(
    winid, record.origin_winid, record.layout, record.mode, record.previous_bufnr
  )

  local errors = {}
  if next(previous_owner._views or {}) == nil then
    local ok, err = pcall(previous_owner._on_presentation_leave, previous_owner)
    if not ok then errors[#errors + 1] = tostring(err) end
  end
  local ok, err = pcall(child._on_presentation_enter, child)
  if not ok then errors[#errors + 1] = tostring(err) end
  if #errors > 0 then error(table.concat(errors, "; "), 0) end
  return true
end

function M.adopt(child, winid, previous_bufnr)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= child.bufnr then
    fail("target window does not display the child instance", 2)
  end
  register_adopted_record(child, winid, previous_bufnr)
  child:_on_presentation_enter()
  return true
end

function M.adopt_created(child, winid, requested, origin_winid)
  local normalized = layout.normalize(requested, { path = "layout" })
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= child.bufnr then
    fail("target window does not display the child instance", 2)
  end
  if type(origin_winid) ~= "number" or origin_winid % 1 ~= 0 then
    fail("created View origin handle is not valid", 2)
  end
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  if child._views[tabpage] ~= nil then
    fail("child already has an active View in the target tab", 2)
  end
  child._views[tabpage] = make_record(
    winid, origin_winid, normalized, "close", nil
  )
  child:_on_presentation_enter()
  return true
end

function M.prune(instance)
  if not instance._views then return false end
  local removed = prune_invalid(instance)
  if next(instance._views) == nil then
    if removed then notify_leave_if_empty(instance) else defer_reconsider(instance) end
  end
  return removed
end

function M.has_active(instance)
  if not instance._views then return false end
  local removed = prune_invalid(instance)
  if next(instance._views) == nil then
    if removed then notify_leave_if_empty(instance) end
    return false
  end
  return true
end

function M.open(instance, requested)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local caller_win = vim.api.nvim_get_current_win()
  local record = active(instance, tabpage)

  if record and requested == nil then
    vim.api.nvim_set_current_win(record.winid)
    notify_open(instance)
    return record.winid
  end

  local normalized = layout.resolve(requested, instance.config.layout, { path = "layout" })
  if record and vim.deep_equal(record.layout, normalized) then
    vim.api.nvim_set_current_win(record.winid)
    notify_open(instance)
    return record.winid
  end
  local _, effective = window.prepare(normalized)
  local anchor = resolve_anchor(record, tabpage, caller_win, normalized)
  local saved = record and window.save_view(record.winid) or nil
  local winid, previous = window.create(instance, normalized, effective, anchor)
  local mode = normalized.position == "current" and "restore" or "close"
  local origin = record and record.origin_winid
    or (normalized.position == "float" and caller_win or anchor)
  local candidate = make_record(
    winid, origin, normalized, mode, previous and previous.bufnr or nil
  )

  if record then
    local function abandon_candidate(err)
      pcall(window.remove, instance, candidate.winid, candidate.mode, candidate.previous_bufnr)
      if valid_record(instance, tabpage, record) then
        pcall(vim.api.nvim_set_current_win, record.winid)
      end
      error(err, 0)
    end
    local fixed_ok, fixed_option, fixed_before = pcall(
      window.set_split_fixed, winid, normalized, true
    )
    if not fixed_ok then abandon_candidate(fixed_option) end
    local retire_ok, removed, remove_err = pcall(
      remove_record, instance, tabpage, record
    )
    if not retire_ok then abandon_candidate(removed) end
    if not removed then abandon_candidate(remove_err) end
    if fixed_option and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_set_option_value, fixed_option, fixed_before, {
        scope = "local", win = winid,
      })
    end
  end

  instance._views[tabpage] = candidate
  if saved then window.restore_view(winid, saved) end
  if vim.api.nvim_win_is_valid(winid) then pcall(vim.api.nvim_set_current_win, winid) end
  notify_open(instance, winid)
  return winid
end

function M.hidden(instance, tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if type(tabpage) ~= "number" then return true end
  local record = active(instance, tabpage, false)
  if record then
    local removed, err = remove_record(instance, tabpage, record)
    if not removed then error(err, 0) end
  end
  notify_leave_if_empty(instance, false)
  return true
end

function M.hide_all(instance)
  local tabpages = {}
  for tabpage in pairs(instance._views or {}) do tabpages[#tabpages + 1] = tabpage end
  table.sort(tabpages, function(left, right)
    if not vim.api.nvim_tabpage_is_valid(left) then return false end
    if not vim.api.nvim_tabpage_is_valid(right) then return true end
    return vim.api.nvim_tabpage_get_number(left) < vim.api.nvim_tabpage_get_number(right)
  end)
  for _, tabpage in ipairs(tabpages) do M.hidden(instance, tabpage) end
  return true
end

function M.toggle(instance, requested)
  local tabpage = vim.api.nvim_get_current_tabpage()
  if active(instance, tabpage) then return M.hidden(instance, tabpage) end
  return M.open(instance, requested)
end

function M.takeover(instance, winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    fail("target window is not valid", 2)
  end
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  if active(instance, tabpage) then fail("instance already has an active View in this tab", 2) end
  local previous = window.install(instance, winid)
  register_adopted_record(instance, winid, previous.bufnr)
  require("fre.buffer").place_initial_cursor(instance, winid)
  instance:_on_presentation_enter()
  return winid
end

return M
