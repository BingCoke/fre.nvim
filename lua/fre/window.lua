local layout_module = require("fre.layout")

local M = {}

local function fail(message, level)
  error("fre.window: " .. message, level or 3)
end

local function copy(value)
  return vim.deepcopy(value)
end

local function geometry()
  return { columns = vim.o.columns, lines = vim.o.lines }
end

local function assert_window(winid, message)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then
    fail(message or "target window is not valid", 4)
  end
end

function M.is_float(winid)
  assert_window(winid)
  return vim.api.nvim_win_get_config(winid).relative ~= ""
end


local function layout_extent(node, axis, minimum)
  if node[1] == "leaf" then
    local actual = axis == "width"
      and vim.api.nvim_win_get_width(node[2]) or vim.api.nvim_win_get_height(node[2])
    if not minimum then return actual end
    local configured = axis == "width" and vim.o.winminwidth or vim.o.winminheight
    return math.min(actual, configured)
  end
  local children = node[2] or {}
  local parallel = (axis == "width" and node[1] == "row")
    or (axis == "height" and node[1] == "col")
  local extent = parallel and math.max(0, #children - 1) or 0
  for _, child in ipairs(children) do
    local child_extent = layout_extent(child, axis, minimum)
    if parallel then
      extent = extent + child_extent
    else
      extent = math.max(extent, child_extent)
    end
  end
  return extent
end

local function split_capacity(position, anchor)
  local axis = (position == "left" or position == "right") and "width" or "height"
  local root = anchor and vim.api.nvim_win_call(anchor, vim.fn.winlayout) or vim.fn.winlayout()
  local usable = layout_extent(root, axis, false)
  local remaining = layout_extent(root, axis, true)
  return usable - remaining - 1
end

function M.prepare(requested)
  local normalized = layout_module.normalize(requested, { path = "layout" })
  local effective = layout_module.materialize(normalized, geometry())
  if effective.position ~= "current" and effective.position ~= "float" then
    layout_module.validate_split_fit(effective, split_capacity(effective.position))
  end
  return copy(normalized), copy(effective)
end

function M.prepare_split(requested, anchor)
  local normalized = layout_module.normalize(requested, { path = "layout" })
  if normalized.position ~= "left" and normalized.position ~= "right"
      and normalized.position ~= "top" and normalized.position ~= "bottom" then
    fail("layout.position must be left, right, top, or bottom", 2)
  end
  assert_window(anchor, "split anchor window is not valid")
  if M.is_float(anchor) then fail("split anchor window must be ordinary", 2) end
  local effective = layout_module.materialize(normalized, geometry())
  layout_module.validate_split_fit(effective, split_capacity(effective.position, anchor))
  return copy(normalized), copy(effective)
end

function M.apply(instance, winid)
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or not vim.api.nvim_buf_is_valid(instance.bufnr)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then
    return false
  end
  for key, value in pairs(instance.window_options or {}) do
    vim.api.nvim_set_option_value(key, value, { scope = "local", win = winid })
  end
  return true
end

local function assert_installed(winid, bufnr)
  assert_window(winid, "target window was invalidated during buffer installation")
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    fail("target window redirected buffer during installation", 4)
  end
end

function M.save_view(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return nil end
  return {
    cursor = vim.api.nvim_win_get_cursor(winid),
    view = vim.api.nvim_win_call(winid, vim.fn.winsaveview),
  }
end

function M.restore_view(winid, saved)
  if not saved or not vim.api.nvim_win_is_valid(winid) then return end
  pcall(vim.api.nvim_win_call, winid, vim.fn.winrestview, saved.view)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.max(1, math.min(saved.cursor[1], count))
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, winid, { row, math.min(saved.cursor[2], #line) })
end

local function snapshot(winid)
  assert_window(winid)
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return {
    winid = winid,
    tabpage = vim.api.nvim_win_get_tabpage(winid),
    bufnr = bufnr,
    bufhidden = vim.api.nvim_get_option_value("bufhidden", { buf = bufnr }),
    view = M.save_view(winid),
    focus = vim.api.nvim_get_current_win(),
  }
end

local function protect(snapshot_value, replacement)
  if snapshot_value.bufnr == replacement then return end
  if snapshot_value.bufhidden == "wipe" or snapshot_value.bufhidden == "delete"
      or snapshot_value.bufhidden == "unload" then
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = snapshot_value.bufnr })
    snapshot_value.protected = true
  end
end

local function finish_protection(snapshot_value)
  if snapshot_value.protected and vim.api.nvim_buf_is_valid(snapshot_value.bufnr) then
    vim.api.nvim_set_option_value(
      "bufhidden", snapshot_value.bufhidden, { buf = snapshot_value.bufnr }
    )
    snapshot_value.protected = nil
  end
end

local function rollback(snapshot_value)
  local winid = snapshot_value.winid
  if not vim.api.nvim_win_is_valid(winid)
      or not vim.api.nvim_buf_is_valid(snapshot_value.bufnr) then return false end
  local ok = pcall(vim.api.nvim_win_set_buf, winid, snapshot_value.bufnr)
  if not ok or vim.api.nvim_win_get_buf(winid) ~= snapshot_value.bufnr then
    ok = pcall(vim.api.nvim_win_call, winid, function()
      vim.cmd("noautocmd buffer " .. tostring(snapshot_value.bufnr))
    end)
  end
  if not ok or vim.api.nvim_win_get_buf(winid) ~= snapshot_value.bufnr then return false end
  finish_protection(snapshot_value)
  M.restore_view(winid, snapshot_value.view)
  if vim.api.nvim_win_is_valid(snapshot_value.focus) then
    pcall(vim.api.nvim_set_current_win, snapshot_value.focus)
  end
  return true
end

function M.install(instance, winid)
  assert_window(winid)
  local before = snapshot(winid)
  local ok, err = pcall(function()
    protect(before, instance.bufnr)
    vim.api.nvim_win_set_buf(winid, instance.bufnr)
    assert_installed(winid, instance.bufnr)
    if not M.apply(instance, winid) then
      fail("target window was invalidated during option application", 4)
    end
    finish_protection(before)
  end)
  if not ok then
    local restored = rollback(before)
    if not restored then err = tostring(err) .. "; destination rollback failed" end
    error(err, 0)
  end
  return before
end

local function resize_split(winid, effective)
  if effective.position == "left" or effective.position == "right" then
    vim.api.nvim_win_set_width(winid, effective.size)
  else
    vim.api.nvim_win_set_height(winid, effective.size)
  end
end

local function split_size(winid, effective)
  if effective.position == "left" or effective.position == "right" then
    return vim.api.nvim_win_get_width(winid)
  end
  return vim.api.nvim_win_get_height(winid)
end

function M.set_split_fixed(winid, normalized, value)
  if normalized.position == "current" or normalized.position == "float" then return nil end
  local option = (normalized.position == "left" or normalized.position == "right")
    and "winfixwidth" or "winfixheight"
  local previous = vim.api.nvim_get_option_value(option, { scope = "local", win = winid })
  vim.api.nvim_set_option_value(option, value, { scope = "local", win = winid })
  return option, previous
end

function M.safe_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  return bufnr
end

local function cleanup_safe_buffer(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) == 0 then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

function M.create(instance, normalized, effective, anchor)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local caller = vim.api.nvim_get_current_win()
  local winid
  local created_win
  local scratch
  local ok, previous = pcall(function()
    if normalized.position == "current" then
      assert_window(anchor, "destination window is not valid in the current tab")
      if vim.api.nvim_win_get_tabpage(anchor) ~= tabpage then
        fail("destination window is not valid in the current tab", 4)
      end
      vim.api.nvim_set_current_win(anchor)
      local before = M.install(instance, anchor)
      winid = anchor
      return before
    end
    if normalized.position == "float" then
      scratch = M.safe_buffer()
      local config = {
        relative = "editor",
        style = "minimal",
        width = effective.width,
        height = effective.height,
        row = effective.row,
        col = effective.col,
        noautocmd = true,
      }
      if effective.border ~= nil then config.border = copy(effective.border) end
      created_win = vim.api.nvim_open_win(scratch, true, config)
      winid = created_win
      assert_installed(winid, scratch)
      vim.api.nvim_win_set_buf(winid, instance.bufnr)
      assert_installed(winid, instance.bufnr)
      if not M.apply(instance, winid) then
        fail("target window was invalidated during option application", 4)
      end
      return nil
    end

    if not anchor or not vim.api.nvim_win_is_valid(anchor)
        or vim.api.nvim_win_get_tabpage(anchor) ~= tabpage or M.is_float(anchor) then
      fail("split anchor window is not a valid ordinary window in the current tab", 4)
    end
    vim.api.nvim_set_current_win(anchor)
    local commands = {
      left = "topleft vertical split",
      right = "botright vertical split",
      top = "topleft split",
      bottom = "botright split",
    }
    vim.cmd("noautocmd " .. commands[normalized.position])
    created_win = vim.api.nvim_get_current_win()
    winid = created_win
    if winid == anchor or vim.api.nvim_win_get_tabpage(winid) ~= tabpage then
      fail("created split destination is not exact", 4)
    end
    resize_split(winid, effective)
    vim.api.nvim_win_set_buf(winid, instance.bufnr)
    assert_installed(winid, instance.bufnr)
    if not M.apply(instance, winid) then
      fail("target window was invalidated during option application", 4)
    end
    if split_size(winid, effective) ~= effective.size then
      fail("layout.size could not be materialized exactly", 4)
    end
    return nil
  end)
  if ok then
    cleanup_safe_buffer(scratch)
    return winid, previous
  end
  if created_win then M.close_window(created_win) end
  cleanup_safe_buffer(scratch)
  if vim.api.nvim_win_is_valid(caller) then pcall(vim.api.nvim_set_current_win, caller) end
  error(previous, 0)
end

function M.discard_buffer(bufnr)
  cleanup_safe_buffer(bufnr)
end

function M.close_window(winid)
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid) then return true end
  local ok, err = pcall(vim.api.nvim_win_close, winid, true)
  if not vim.api.nvim_win_is_valid(winid) then return true end
  return false, err or "failed to close the created window"
end

function M.close_tab(tabpage)
  if type(tabpage) ~= "number" or not vim.api.nvim_tabpage_is_valid(tabpage) then return true end
  local number = vim.api.nvim_tabpage_get_number(tabpage)
  local ok, err = pcall(vim.cmd, "noautocmd " .. tostring(number) .. "tabclose!")
  if not vim.api.nvim_tabpage_is_valid(tabpage) then return true end
  return false, err or "failed to close the created tab"
end

function M.create_split(normalized, effective, anchor)
  assert_window(anchor, "split anchor window is not valid")
  local tabpage = vim.api.nvim_win_get_tabpage(anchor)
  if M.is_float(anchor) then fail("split anchor window must be ordinary", 2) end
  local caller_tab = vim.api.nvim_get_current_tabpage()
  local caller_win = vim.api.nvim_get_current_win()
  local scratch = M.safe_buffer()
  local winid
  local commands = {
    left = "leftabove vertical sbuffer",
    right = "rightbelow vertical sbuffer",
    top = "leftabove sbuffer",
    bottom = "rightbelow sbuffer",
  }
  local ok, err = pcall(function()
    if normalized.position ~= "left" and normalized.position ~= "right"
        and normalized.position ~= "top" and normalized.position ~= "bottom" then
      fail("layout.position must be left, right, top, or bottom", 4)
    end
    if vim.api.nvim_win_get_tabpage(anchor) ~= tabpage then
      fail("split anchor window changed tab", 4)
    end
    vim.api.nvim_set_current_win(anchor)
    vim.cmd("noautocmd " .. commands[normalized.position] .. " " .. tostring(scratch))
    winid = vim.api.nvim_get_current_win()
    if winid == anchor or vim.api.nvim_win_get_tabpage(winid) ~= tabpage
        or vim.api.nvim_win_get_buf(winid) ~= scratch then
      fail("created split destination is not exact", 4)
    end
    resize_split(winid, effective)
    if split_size(winid, effective) ~= effective.size then
      fail("layout.size could not be materialized exactly", 4)
    end
  end)
  if ok then return winid, scratch end
  if winid then M.close_window(winid) end
  cleanup_safe_buffer(scratch)
  if vim.api.nvim_tabpage_is_valid(caller_tab) then
    pcall(vim.api.nvim_set_current_tabpage, caller_tab)
  end
  if vim.api.nvim_win_is_valid(caller_win) then pcall(vim.api.nvim_set_current_win, caller_win) end
  error(err, 0)
end

function M.create_tab()
  local caller_tab = vim.api.nvim_get_current_tabpage()
  local caller_win = vim.api.nvim_get_current_win()
  local scratch = M.safe_buffer()
  local ok, err = pcall(vim.cmd, "noautocmd tab sbuffer " .. tostring(scratch))
  if not ok then
    cleanup_safe_buffer(scratch)
    if vim.api.nvim_tabpage_is_valid(caller_tab) then
      pcall(vim.api.nvim_set_current_tabpage, caller_tab)
    end
    if vim.api.nvim_win_is_valid(caller_win) then
      pcall(vim.api.nvim_set_current_win, caller_win)
    end
    error(err, 0)
  end

  local created_tab = vim.api.nvim_get_current_tabpage()
  local created_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_tabpage_is_valid(created_tab)
      and vim.api.nvim_win_is_valid(created_win)
      and vim.api.nvim_win_get_tabpage(created_win) == created_tab
      and vim.api.nvim_win_get_buf(created_win) == scratch then
    return created_tab, created_win, scratch
  end

  M.close_tab(created_tab)
  cleanup_safe_buffer(scratch)
  if vim.api.nvim_tabpage_is_valid(caller_tab) then
    pcall(vim.api.nvim_set_current_tabpage, caller_tab)
  end
  if vim.api.nvim_win_is_valid(caller_win) then
    pcall(vim.api.nvim_set_current_win, caller_win)
  end
  error("fre.window: created tab destination is not exact", 0)
end

function M.remove(instance, winid, mode, previous_bufnr)
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return true end
  if mode == "tab" then
    local tabpage = vim.api.nvim_win_get_tabpage(winid)
    local closed, close_err = M.close_tab(tabpage)
    if closed then return true end
    local replaced, replace_err = M.remove(instance, winid, "restore", nil)
    if replaced then return true end
    return false, replace_err or close_err or "failed to close the managed tab"
  end
  if mode == "restore" then
    local replacement = previous_bufnr
    local created_safe = false
    if not replacement or not vim.api.nvim_buf_is_valid(replacement)
        or replacement == instance.bufnr then
      replacement = M.safe_buffer()
      created_safe = true
    end
    local ok, err = pcall(vim.api.nvim_win_set_buf, winid, replacement)
    if ok and vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return true end
    if created_safe and vim.api.nvim_buf_is_valid(replacement)
        and #vim.fn.win_findbuf(replacement) == 0 then
      pcall(vim.api.nvim_buf_delete, replacement, { force = true })
    end
    return false, err or "failed to restore the previous buffer"
  end

  local ok, err = pcall(vim.api.nvim_win_close, winid, true)
  if not vim.api.nvim_win_is_valid(winid) then return true end
  if vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return true end
  local replacement = M.safe_buffer()
  local replaced, replace_err = pcall(vim.api.nvim_win_set_buf, winid, replacement)
  if replaced and vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return true end
  if vim.api.nvim_buf_is_valid(replacement) and #vim.fn.win_findbuf(replacement) == 0 then
    pcall(vim.api.nvim_buf_delete, replacement, { force = true })
  end
  return false, replace_err or err or "failed to close the managed window"
end


function M.replace_buffer(instance, winid, bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    fail("replacement buffer is not valid", 2)
  end
  assert_window(winid)
  local before = snapshot(winid)
  local ok, err = pcall(function()
    protect(before, bufnr)
    vim.api.nvim_win_set_buf(winid, bufnr)
    assert_installed(winid, bufnr)
    finish_protection(before)
  end)
  if not ok then
    if not rollback(before) then err = tostring(err) .. "; destination rollback failed" end
    error(err, 0)
  end
  return winid
end


return M
