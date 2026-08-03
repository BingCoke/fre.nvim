local Events = require("fre.instance.events")
local layout = require("fre.layout")
local window = require("fre.window")

local M = {}

local policy_var = "fre_view"
local policy_version = 1

local function fail(message, level)
  error("fre.view: " .. message, level or 3)
end

local function copy(value)
  return vim.deepcopy(value)
end

function M.new(options)
  options = options or {}
  return {
    id = assert(options.id),
    bufnr = assert(options.bufnr),
    lifecycle = assert(options.lifecycle),
    default_layout = copy(options.layout),
    window_options = copy(options.window_options or {}),
    buffer = options.buffer,
    sync = options.sync,
    tree = options.tree,
    work = options.work,
    records = {},
    released = {},
    presented = false,
    pending_refresh = false,
  }
end

local function state(view)
  return type(view) == "table" and view or nil
end

local function subject(view)
  local current = assert(state(view))
  return {
    bufnr = current.bufnr,
    window_options = current.window_options,
  }
end

local function live_instance(view)
  local current = state(view)
  return current ~= nil
    and not current.lifecycle:is_dead()
    and type(current.bufnr) == "number"
    and vim.api.nvim_buf_is_valid(current.bufnr)
end

local function valid_window(winid)
  return type(winid) == "number" and vim.api.nvim_win_is_valid(winid)
end

local function displays(instance, winid)
  return valid_window(winid) and vim.api.nvim_buf_is_valid(instance.bufnr)
    and vim.api.nvim_win_get_buf(winid) == instance.bufnr
end

local function normalize_tabpage(tabpage)
  if tabpage == nil or tabpage == 0 then return vim.api.nvim_get_current_tabpage() end
  if type(tabpage) ~= "number" or not vim.api.nvim_tabpage_is_valid(tabpage) then return nil end
  return tabpage
end

local function first_ordinary(tabpage)
  local found = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if valid_window(winid) and not window.is_float(winid) then found[#found + 1] = winid end
  end
  table.sort(found)
  return found[1]
end

local function actual_windows(instance, tabpage)
  local result = {}
  if type(instance) ~= "table" or type(instance.bufnr) ~= "number"
      or not vim.api.nvim_buf_is_valid(instance.bufnr) then return result end
  if tabpage ~= nil then
    tabpage = normalize_tabpage(tabpage)
    if not tabpage then return result end
  end
  for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
    if displays(instance, winid)
        and (tabpage == nil or vim.api.nvim_win_get_tabpage(winid) == tabpage) then
      result[#result + 1] = winid
    end
  end
  table.sort(result)
  return result
end

local function clear_policy(winid)
  if valid_window(winid) then pcall(vim.api.nvim_win_del_var, winid, policy_var) end
end

local policy_fields = {
  version = true, winid = true, tabpage = true, layout_json = true, mode = true,
  origin_winid = true, previous_bufnr = true,
}

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

local function validate_policy(value, winid, tabpage)
  if type(value) ~= "table" or value.version ~= policy_version
      or value.winid ~= winid or value.tabpage ~= tabpage
      or (value.mode ~= "restore" and value.mode ~= "close" and value.mode ~= "tab")
      or (value.origin_winid ~= nil and not positive_integer(value.origin_winid))
      or (value.previous_bufnr ~= nil and not positive_integer(value.previous_bufnr)) then
    return nil
  end
  for key in pairs(value) do
    if type(key) ~= "string" or not policy_fields[key] then return nil end
  end
  if type(value.layout_json) ~= "string" then return nil end
  local decoded_ok, decoded = pcall(vim.json.decode, value.layout_json)
  if not decoded_ok then return nil end
  local ok, normalized = pcall(layout.normalize, decoded, { path = "view policy layout" })
  if not ok then return nil end
  local result = copy(value)
  result.layout_json = nil
  result.layout = normalized
  return result
end

local function policy(winid)
  if not valid_window(winid) then return nil end
  local ok, value = pcall(vim.api.nvim_win_get_var, winid, policy_var)
  if not ok then return nil end
  local validated = validate_policy(value, winid, vim.api.nvim_win_get_tabpage(winid))
  if not validated then clear_policy(winid) end
  return validated
end

local function set_policy(winid, spec, preserve)
  if not valid_window(winid) then fail("target window is not valid", 4) end
  local existing = policy(winid)
  if preserve and existing then return existing end
  local layout_ok, layout_json = pcall(
    vim.json.encode, type(spec) == "table" and spec.layout or nil
  )
  if not layout_ok then fail("presentation policy is invalid", 4) end
  local value = {
    version = policy_version,
    winid = winid,
    tabpage = vim.api.nvim_win_get_tabpage(winid),
    layout_json = layout_json,
    mode = type(spec) == "table" and spec.mode or nil,
    origin_winid = type(spec) == "table" and spec.origin_winid or nil,
    previous_bufnr = type(spec) == "table" and spec.previous_bufnr or nil,
  }
  local validated = validate_policy(value, winid, value.tabpage)
  if not validated then fail("presentation policy is invalid", 4) end
  vim.api.nvim_win_set_var(winid, policy_var, value)
  return copy(validated)
end

local function alternate_buffer(winid, excluded)
  if not valid_window(winid) then return nil end
  local ok, bufnr = pcall(vim.api.nvim_win_call, winid, function()
    return vim.fn.bufnr("#")
  end)
  if ok and type(bufnr) == "number" and bufnr > 0 and bufnr ~= excluded
      and vim.api.nvim_buf_is_valid(bufnr) then return bufnr end
  return nil
end

local function external_layout(winid)
  local config = vim.api.nvim_win_get_config(winid)
  if config.relative == "" then return { position = "current" }, winid end
  local layout = {
    position = "float",
    width = config.width,
    height = config.height,
    row = config.row,
    col = config.col,
  }
  if config.border ~= nil and config.border ~= "" then layout.border = copy(config.border) end
  return layout, nil
end

local function describe(instance, winid)
  if not displays(instance, winid) then return nil end
  local tracked = policy(winid)
  if tracked then
    return {
      winid = winid,
      tabpage = vim.api.nvim_win_get_tabpage(winid),
      origin_winid = tracked.origin_winid,
      layout = copy(tracked.layout),
      mode = tracked.mode,
      previous_bufnr = tracked.previous_bufnr,
      managed = true,
    }
  end
  local layout, origin_winid = external_layout(winid)
  return {
    winid = winid,
    tabpage = vim.api.nvim_win_get_tabpage(winid),
    origin_winid = origin_winid,
    layout = layout,
    mode = "restore",
    previous_bufnr = alternate_buffer(winid, instance.bufnr),
    managed = false,
  }
end

local function snapshot(record)
  if not record then return nil end
  return {
    winid = record.winid,
    origin_winid = record.origin_winid,
    layout = copy(record.layout),
  }
end

local function forget(instance, winid)
  local current = state(instance)
  if not current then return end
  for tab, tab_records in pairs(current.records) do
    tab_records[winid] = nil
    if next(tab_records) == nil then current.records[tab] = nil end
  end
end

local function remember(instance, record)
  local current = assert(state(instance))
  current.released[record.winid] = nil
  local tab_records = current.records[record.tabpage]
  if not tab_records then
    tab_records = {}
    current.records[record.tabpage] = tab_records
  end
  tab_records[record.winid] = copy(record)
  return tab_records[record.winid]
end

local function stored(instance, winid)
  local current = state(instance)
  if not current then return nil end
  for _, tab_records in pairs(current.records) do
    if tab_records[winid] then return copy(tab_records[winid]) end
  end
  return nil
end

local function records(instance, tabpage)
  local current = state(instance)
  if not current then return {} end
  local result = {}
  local actual = {}
  for _, winid in ipairs(actual_windows(instance, tabpage)) do
    actual[winid] = true
    if current.released[winid] == current.bufnr then
      -- An explicit release is authoritative until the window stops displaying this buffer.
    else
      local record = describe(instance, winid)
      if record then
        remember(instance, record)
        result[#result + 1] = record
      end
    end
  end
  for released_winid, released_bufnr in pairs(current.released) do
    if not valid_window(released_winid)
        or vim.api.nvim_win_get_buf(released_winid) ~= released_bufnr then
      current.released[released_winid] = nil
    end
  end
  local requested_tab = tabpage ~= nil and normalize_tabpage(tabpage) or nil
  for tracked_tab, tab_records in pairs(current.records) do
    for winid in pairs(tab_records) do
      local invalid_tab = not vim.api.nvim_tabpage_is_valid(tracked_tab)
      local in_scope = tabpage == nil or tracked_tab == requested_tab
      if invalid_tab or (in_scope and not actual[winid]) then forget(instance, winid) end
    end
  end
  table.sort(result, function(left, right) return left.winid < right.winid end)
  return result
end

local function report_async_error(message)
  local text = "fre: " .. tostring(message)
  local ok = pcall(vim.schedule, function()
    pcall(vim.notify, text, vim.log.levels.ERROR)
  end)
  if not ok then pcall(vim.notify, text, vim.log.levels.ERROR) end
end

local error_scopes = setmetatable({}, { __mode = "k" })

function M.capture_errors(instance)
  local stack = error_scopes[instance]
  if not stack then
    stack = {}
    error_scopes[instance] = stack
  end
  local captured = {}
  stack[#stack + 1] = captured
  local finished = false
  return function()
    if finished then fail("presentation error capture is already finished", 3) end
    finished = true
    if stack[#stack] ~= captured then fail("presentation error capture finished out of order", 3) end
    stack[#stack] = nil
    if #stack == 0 then error_scopes[instance] = nil end
    if #captured == 0 then return nil end
    return table.concat(captured, "; ")
  end
end

function M.attach(view, dependencies)
  local current = assert(state(view))
  for _, key in ipairs({ "buffer", "sync", "tree", "work" }) do
    if dependencies[key] ~= nil then current[key] = dependencies[key] end
  end
end

function M.refresh_if_presented(view)
  local current = state(view)
  if not current or current.lifecycle:is_dead() or not current.presented then return end
  local sync = current.sync
  local work = current.work
  local tree = current.tree
  if not sync or not work or not tree or not current.lifecycle:is_ready()
      or not sync:is_dirty() or current.pending_refresh or sync:is_busy()
      or vim.bo[current.bufnr].modified or work:is_write_active()
      or work:is_execution_active() then return end
  for _, node in tree:iter_nodes() do
    if node.kind == "directory"
        and (node.load_state == "loading" or node.load_state == "refreshing") then return end
  end
  current.pending_refresh = true
  local ok, err = pcall(sync.presentation_refresh, sync, function(refresh_err)
    if current.lifecycle:is_dead() then return end
    current.pending_refresh = false
    if refresh_err ~= nil then report_async_error(refresh_err) end
  end)
  if not ok then
    current.pending_refresh = false
    report_async_error(err)
  end
end

function M.sync(view, _)
  if not live_instance(view) then return false end
  local current = assert(state(view))
  local visible = #records(view) > 0
  if current.presented == visible then return visible end
  current.presented = visible
  Events.presentation_changed(current.id, current.bufnr, visible)
  if visible then M.refresh_if_presented(view) end
  return visible
end

function M.list(instance, tabpage)
  local result = {}
  for _, record in ipairs(records(instance, tabpage)) do
    local item = snapshot(record)
    item.tabpage = record.tabpage
    result[#result + 1] = item
  end
  return result
end

function M.source(instance, winid)
  if not live_instance(instance) then fail("instance is not live", 3) end
  local record
  for _, candidate in ipairs(records(instance)) do
    if candidate.winid == winid then record = candidate; break end
  end
  if not record then fail("window does not display this instance", 3) end
  M.sync(instance)
  return snapshot(record)
end

local function inspect_location(instance, location)
  local exact_winid
  local tabpage
  if type(location) == "table" then
    exact_winid = location.winid
    if type(exact_winid) ~= "number" then fail("inspect location must contain winid", 3) end
  elseif type(location) == "number" and location ~= 0
      and not vim.api.nvim_tabpage_is_valid(location) and vim.api.nvim_win_is_valid(location) then
    exact_winid = location
  else
    tabpage = normalize_tabpage(location)
    if not tabpage then return nil end
  end
  if exact_winid then
    for _, record in ipairs(records(instance)) do
      if record.winid == exact_winid then return record end
    end
    return nil
  end
  local found = records(instance, tabpage)
  if #found == 0 then return nil end
  local current = vim.api.nvim_get_current_win()
  for _, record in ipairs(found) do
    if record.winid == current then return record end
  end
  if #found == 1 then return found[1] end
  fail("multiple Views exist in the tab; inspect an exact winid", 3)
end

function M.inspect(instance, location)
  if not live_instance(instance) then return nil end
  local record = inspect_location(instance, location)
  pcall(M.sync, instance, { report = true })
  return snapshot(record)
end

local function choose(instance, tabpage)
  local found = records(instance, tabpage)
  if #found == 0 then return nil end
  local current = vim.api.nvim_get_current_win()
  for _, record in ipairs(found) do
    if record.winid == current then return record end
  end
  if #found == 1 then return found[1] end
  if #found > 26 then fail("more than 26 Views require an exact window", 4) end

  local choices = {}
  for index, record in ipairs(found) do
    local key = string.char(string.byte("a") + index - 1)
    local number = vim.api.nvim_win_call(record.winid, vim.fn.winnr)
    choices[#choices + 1] = string.format(
      "&%s window %d (%s)", key, number, record.layout.position
    )
  end
  local selected = vim.fn.confirm("fre: select View", table.concat(choices, "\n"), 0)
  if type(selected) ~= "number" or selected < 1 or selected > #found then
    fail("View selection was cancelled", 4)
  end
  return found[selected]
end

function M.select(instance, tabpage)
  if not live_instance(instance) then fail("instance is not live", 3) end
  tabpage = normalize_tabpage(tabpage)
  if not tabpage then return nil end
  local selected = choose(instance, tabpage)
  return selected and selected.winid or nil
end

function M.has_active(instance)
  return live_instance(instance) and #records(instance) > 0
end

function M.adopt(instance, winid, presentation)
  if not live_instance(instance) then fail("instance is not live", 3) end
  if not displays(instance, winid) then fail("window does not display this instance", 3) end
  presentation = presentation or {
    layout = { position = "current" },
    origin_winid = winid,
    mode = "restore",
    previous_bufnr = alternate_buffer(winid, instance.bufnr),
  }
  set_policy(winid, {
    layout = presentation.layout,
    origin_winid = presentation.origin_winid,
    mode = presentation.mode or "restore",
    previous_bufnr = presentation.previous_bufnr,
  }, false)
  local record = assert(describe(instance, winid))
  remember(instance, record)
  M.sync(instance)
  return snapshot(record)
end

function M.release(instance, winid)
  local current = state(instance)
  if not current then return false end
  local record = stored(instance, winid)
  forget(instance, winid)
  if valid_window(winid) and vim.api.nvim_win_get_buf(winid) == current.bufnr then
    current.released[winid] = current.bufnr
  else
    current.released[winid] = nil
  end
  if live_instance(instance) then M.sync(instance) end
  return record ~= nil
end

function M.take(instance, source_instance, winid)
  if not live_instance(instance) then fail("instance is not live", 3) end
  local record = stored(source_instance, winid)
  if not record then
    local tracked = policy(winid)
    if tracked then
      record = {
        winid = winid,
        tabpage = vim.api.nvim_win_get_tabpage(winid),
        origin_winid = tracked.origin_winid,
        layout = copy(tracked.layout),
        mode = tracked.mode,
        previous_bufnr = tracked.previous_bufnr,
        managed = true,
      }
    end
  end
  if not record then fail("source View is not managed", 3) end
  M.release(source_instance, winid)
  return M.adopt(instance, winid, record)
end

function M.track_created(instance, winid, requested_layout, origin_winid, mode)
  return M.adopt(instance, winid, {
    layout = requested_layout,
    origin_winid = origin_winid,
    mode = mode or "close",
  })
end

function M.track_current(instance, winid, previous_bufnr)
  return M.adopt(instance, winid, {
    layout = { position = "current" },
    origin_winid = winid,
    mode = "restore",
    previous_bufnr = previous_bufnr,
  })
end

function M.place_initial_cursor(instance, winid)
  local current = assert(state(instance))
  return require("fre.instance.buffer").place_initial_cursor(current.buffer, winid)
end

local function focus(winid)
  if not valid_window(winid) then fail("selected window is no longer valid", 4) end
  local tabpage = vim.api.nvim_win_get_tabpage(winid)
  if tabpage ~= vim.api.nvim_get_current_tabpage() then vim.api.nvim_set_current_tabpage(tabpage) end
  vim.api.nvim_set_current_win(winid)
end

local function removal_error(instance, record)
  clear_policy(record.winid)
  forget(instance, record.winid)
  local ok, err = window.remove(
    subject(instance), record.winid, record.mode, record.previous_bufnr
  )
  if ok then return nil end
  return err or "failed to remove View"
end

function M.open(instance, requested)
  if not live_instance(instance) then fail("instance is not live", 2) end
  local tabpage = vim.api.nvim_get_current_tabpage()
  local normalized, effective
  if requested ~= nil then normalized, effective = window.prepare(requested) end
  local selected = choose(instance, tabpage)

  if selected and requested == nil then
    focus(selected.winid)
    window.apply(subject(instance), selected.winid)
    M.sync(instance)
    return selected.winid
  end

  if requested == nil then
    normalized, effective = window.prepare(assert(state(instance)).default_layout)
  end
  if selected and vim.deep_equal(selected.layout, normalized) then
    focus(selected.winid)
    window.apply(subject(instance), selected.winid)
    M.sync(instance)
    return selected.winid
  end

  local selected_sync_err
  if selected then
    local synced, sync_err = pcall(M.sync, instance)
    if not synced then selected_sync_err = sync_err end
  end

  local anchor
  if not selected then
    anchor = vim.api.nvim_get_current_win()
  elseif selected.mode == "tab" then
    anchor = selected.origin_winid or selected.winid
  elseif normalized.position == "current" then
    anchor = selected.origin_winid
  elseif window.is_float(selected.winid) then
    anchor = selected.origin_winid
  else
    anchor = selected.winid
  end
  if not selected and (not valid_window(anchor)
      or vim.api.nvim_win_get_tabpage(anchor) ~= tabpage or window.is_float(anchor)) then
    anchor = first_ordinary(tabpage)
  end
  if not valid_window(anchor) or vim.api.nvim_win_get_tabpage(anchor) ~= tabpage
      or window.is_float(anchor) then
    fail("View origin is not a valid ordinary window in the current tab", 3)
  end

  local saved = selected and window.save_view(selected.winid) or nil
  local finish_capture = M.capture_errors(instance)
  local created, winid, previous = pcall(
    window.create, subject(instance), normalized, effective, anchor
  )
  local enter_err = finish_capture()
  if not created then error(winid, 0) end

  local mode
  if selected and selected.mode == "tab" then
    mode = "tab"
  else
    mode = normalized.position == "current" and "restore" or "close"
  end
  local candidate_origin = winid
  if mode == "close" then
    candidate_origin = selected and selected.origin_winid or anchor
  elseif mode == "tab" and normalized.position ~= "current" then
    candidate_origin = selected and selected.origin_winid or anchor
  end
  local cleanup_mode = normalized.position == "current" and "restore" or "close"
  local policy_ok, policy_err = pcall(function()
    set_policy(winid, {
      layout = normalized,
      origin_winid = candidate_origin,
      mode = mode,
      previous_bufnr = mode == "restore" and previous and previous.bufnr or nil,
    }, false)
  end)
  if not policy_ok then
    window.remove(subject(instance), winid, cleanup_mode, previous and previous.bufnr or nil)
    error(policy_err, 0)
  end
  remember(instance, assert(describe(instance, winid)))
  window.restore_view(winid, saved)

  local remove_err
  if selected and selected.winid ~= winid then
    local fixed_ok, fixed_option, fixed_before = pcall(
      window.set_split_fixed, winid, normalized, true
    )
    if not fixed_ok then
      clear_policy(winid)
      forget(instance, winid)
      window.remove(subject(instance), winid, cleanup_mode, previous and previous.bufnr or nil)
      focus(selected.winid)
      error(fixed_option, 0)
    end
    if selected.mode == "tab" then
      clear_policy(selected.winid)
      forget(instance, selected.winid)
      local retire_mode = selected.layout.position == "current" and "restore" or "close"
      local retired, retire_err = window.remove(
        subject(instance), selected.winid, retire_mode, nil
      )
      if not retired then remove_err = retire_err end
    else
      remove_err = removal_error(instance, selected)
    end
    if fixed_option and valid_window(winid) then
      pcall(vim.api.nvim_set_option_value, fixed_option, fixed_before, {
        scope = "local", win = winid,
      })
    end
  end
  local synced, sync_err = pcall(M.sync, instance)
  focus(winid)
  local errors = {}
  if selected_sync_err then errors[#errors + 1] = tostring(selected_sync_err) end
  if enter_err then errors[#errors + 1] = enter_err end
  if not synced then errors[#errors + 1] = tostring(sync_err) end
  if remove_err then errors[#errors + 1] = tostring(remove_err) end
  if #errors > 0 then error(table.concat(errors, "; "), 0) end
  return winid
end

local function hide_records(instance, found)
  local caller_tab = vim.api.nvim_get_current_tabpage()
  local caller_win = vim.api.nvim_get_current_win()
  local errors = {}
  for _, record in ipairs(found) do
    local err = removal_error(instance, record)
    if err then errors[#errors + 1] = tostring(err) end
  end
  if live_instance(instance) then M.sync(instance) end
  if vim.api.nvim_tabpage_is_valid(caller_tab) then
    pcall(vim.api.nvim_set_current_tabpage, caller_tab)
  end
  if vim.api.nvim_win_is_valid(caller_win) then pcall(vim.api.nvim_set_current_win, caller_win) end
  if #errors > 0 then error(table.concat(errors, "; "), 0) end
  return true
end

function M.hidden(instance, tabpage)
  if not live_instance(instance) then fail("instance is not live", 2) end
  tabpage = normalize_tabpage(tabpage)
  if not tabpage then
    pcall(M.sync, instance, { report = true })
    return true
  end
  return hide_records(instance, records(instance, tabpage))
end

function M.hide_all(instance)
  if type(instance) ~= "table" then return true end
  return hide_records(instance, records(instance))
end

function M.toggle(instance, layout)
  if not live_instance(instance) then fail("instance is not live", 2) end
  local tabpage = vim.api.nvim_get_current_tabpage()
  if #records(instance, tabpage) > 0 then return M.hidden(instance, tabpage) end
  return M.open(instance, layout)
end

function M.takeover(instance, winid)
  if not live_instance(instance) then fail("instance is not live", 2) end
  if not valid_window(winid) then fail("target window is not valid", 2) end
  local previous_bufnr = vim.api.nvim_win_get_buf(winid)
  local finish_capture = M.capture_errors(instance)
  local ok, previous = pcall(window.install, subject(instance), winid)
  local enter_err = finish_capture()
  if not ok then error(previous, 0) end
  M.track_current(instance, winid, previous_bufnr)
  M.place_initial_cursor(instance, winid)
  if enter_err then error(enter_err, 0) end
  return winid
end

function M.apply_window(instance, winid)
  return window.apply(subject(instance), winid)
end

function M.destroy(instance)
  local current = state(instance)
  if not current then return end
  if current.presented then
    current.presented = false
    Events.presentation_changed(current.id, current.bufnr, false)
  end
  for _, tab_records in pairs(current.records) do
    for winid in pairs(tab_records) do clear_policy(winid) end
  end
  current.records = {}
  current.released = {}
  current.pending_refresh = false
end

return M
