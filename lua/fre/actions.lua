local config = require("fre.config")
local default_ui = require("fre.write_ui")
local mapping = require("fre.mapping")
local path = require("fre.path")
local window = require("fre.window")

local M = {}
local ui_adapter = default_ui

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function instance_from(ctx)
  if type(ctx) ~= "table" or type(ctx.instance) ~= "table" then
    fail("action context must contain an instance", 3)
  end
  if ctx.bufnr ~= nil and ctx.bufnr ~= ctx.instance.bufnr then
    fail("action context buffer does not match its instance", 3)
  end
  return ctx.instance
end

local function exact_opts(opts, allowed, name)
  if opts == nil then return {} end
  if type(opts) ~= "table" then fail(name .. " options must be a table", 4) end
  for key in pairs(opts) do
    if type(key) ~= "string" or not allowed[key] then
      fail(name .. " options contain unknown field " .. tostring(key), 4)
    end
  end
  return opts
end

local function entry_from(ctx)
  instance_from(ctx)
  if ctx.entry == nil then fail("action requires an entry", 4) end
  if type(ctx.entry) ~= "table" then fail("action context entry must be a table", 4) end
  if type(ctx.entry.absolute_path) ~= "string" or ctx.entry.absolute_path == "" then
    fail("action context entry must contain an absolute path", 4)
  end
  if ctx.entry.kind ~= "file" and ctx.entry.kind ~= "symlink"
      and ctx.entry.kind ~= "directory" then
    fail("action context entry has unsupported kind " .. tostring(ctx.entry.kind), 4)
  end
  return ctx.entry
end

local function entry_path(ctx)
  return entry_from(ctx).absolute_path
end

local function directory_action_target(ctx)
  local instance = instance_from(ctx)
  if ctx.entry == nil then return instance, nil end
  local entry = entry_from(ctx)
  if entry.kind ~= "directory" then return instance, nil end
  return instance, entry.absolute_path
end

local function no_options(opts, name)
  exact_opts(opts, {}, name)
end

local function validate_target(winid)
  if type(winid) ~= "number" or winid % 1 ~= 0
      or not vim.api.nvim_win_is_valid(winid) then
    fail("target window is not valid", 4)
  end
  return winid
end

local function selection_target(ctx, instance)
  if ctx.row_kind == "navigation" then
    if ctx.source_instance_id ~= instance.id or ctx.navigation_kind == "root" then
      return { kind = "noop" }
    end
    local parent = assert(path.parent(instance.root))
    return {
      kind = "directory",
      root = parent,
      cursor = assert(path.relative(parent, instance.root)),
    }
  end
  local entry = entry_from(ctx)
  if entry.kind == "directory" then
    return { kind = "directory", root = entry.absolute_path, entry = entry }
  end
  return { kind = "file", path = entry.absolute_path, entry = entry }
end

local function child_options(instance, overrides, root)
  if overrides == nil then overrides = {} end
  if type(overrides) ~= "table" then fail("opts.instance must be a table", 4) end
  if overrides.root ~= nil then fail("opts.instance.root is action-owned", 4) end
  local result = config.copy(overrides)
  if result.sort == nil then result.sort = instance.current_sort end
  if result.hidden_file == nil then result.hidden_file = instance.current_hidden_file end
  result.root = root
  return result
end

local function place_selection_cursor(instance, winid, snapshot_path)
  if snapshot_path == nil then return end
  instance:when_ready(function(err)
    if err or instance._destroyed or not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then
      return
    end
    local position = instance:get_pos(snapshot_path)
    if position then vim.api.nvim_win_set_cursor(winid, position) end
  end)
end

local function file_buffer(filename)
  local existing = vim.fn.bufnr(filename)
  local bufnr = vim.fn.bufadd(filename)
  local created = existing < 0
  local ok, err = pcall(vim.fn.bufload, bufnr)
  if not ok then
    if created and vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) == 0 then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    error(err, 0)
  end
  return bufnr, created
end

local function cleanup_file_buffer(bufnr, created)
  if created and vim.api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) == 0 then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function replace_with_file(source, target, filename)
  local bufnr, created = file_buffer(filename)
  local ok, err = pcall(window.replace_buffer, source, target, bufnr)
  if not ok then
    cleanup_file_buffer(bufnr, created)
    error(err, 0)
  end
  return bufnr
end

local function restore_caller(tabpage, winid)
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, tabpage)
  end
  if vim.api.nvim_win_is_valid(winid) then pcall(vim.api.nvim_set_current_win, winid) end
end

local function snapshot_tabs()
  local result = {}
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do result[tabpage] = true end
  return result
end

local function snapshot_buffers()
  local result = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do result[bufnr] = true end
  return result
end

local function remove_created_tabs(before, buffers_before, caller_tab, caller_win)
  local created = {}
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if not before[tabpage] then created[#created + 1] = tabpage end
  end
  table.sort(created, function(left, right)
    return vim.api.nvim_tabpage_get_number(left) > vim.api.nvim_tabpage_get_number(right)
  end)
  for _, tabpage in ipairs(created) do
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      local number = vim.api.nvim_tabpage_get_number(tabpage)
      pcall(vim.cmd, "noautocmd " .. tostring(number) .. "tabclose!")
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if not buffers_before[bufnr] and vim.api.nvim_buf_is_valid(bufnr)
        and #vim.fn.win_findbuf(bufnr) == 0 then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  restore_caller(caller_tab, caller_win)
end

function M.context()
  return mapping.context()
end

function M.expand(ctx, opts)
  no_options(opts, "expand")
  local instance, target = directory_action_target(ctx)
  if not target then return nil end
  return instance:expand(target)
end

function M.collapse(ctx, opts)
  no_options(opts, "collapse")
  local instance, target = directory_action_target(ctx)
  if not target then return nil end
  return instance:collapse(target)
end

function M.toggle_expand(ctx, opts)
  no_options(opts, "toggle_expand")
  local instance, target = directory_action_target(ctx)
  if not target then return nil end
  return instance:toggle_expand(target)
end

function M.reveal(ctx, opts)
  no_options(opts, "reveal")
  local instance = instance_from(ctx)
  if ctx.entry == nil then return nil end
  return instance:reveal(entry_path(ctx))
end

function M.open(ctx, opts)
  opts = exact_opts(opts, { layout = true }, "open")
  return instance_from(ctx):open(opts.layout)
end

function M.hidden(ctx, opts)
  no_options(opts, "hidden")
  return instance_from(ctx):hidden()
end

function M.toggle(ctx, opts)
  opts = exact_opts(opts, { layout = true }, "toggle")
  return instance_from(ctx):toggle(opts.layout)
end

function M.set_hidden_file(ctx, opts)
  opts = exact_opts(opts, { hidden_file = true }, "set_hidden_file")
  if type(opts.hidden_file) ~= "boolean" then
    fail("set_hidden_file.hidden_file must be a boolean", 3)
  end
  return instance_from(ctx):set_hidden_file(opts.hidden_file)
end

function M.toggle_hidden_file(ctx, opts)
  no_options(opts, "toggle_hidden_file")
  return instance_from(ctx):toggle_hidden_file()
end

function M.refresh(ctx, opts)
  no_options(opts, "refresh")
  local instance = instance_from(ctx)
  if not vim.bo[instance.bufnr].modified then return instance:refresh() end
  local delivered = false
  return M.confirm(ctx, { "Discard changes and refresh?" }, function(accepted)
    if delivered then return end
    delivered = true
    if accepted == true then instance:refresh({ force = true }) end
  end)
end

function M.select(ctx, opts)
  local instance = instance_from(ctx)
  opts = exact_opts(opts, { target_winid = true, instance = true }, "select")
  local target_winid = validate_target(opts.target_winid or ctx.winid)
  local target = selection_target(ctx, instance)
  if target.kind == "noop" then return nil end
  if target.kind == "file" then
    return replace_with_file(instance, target_winid, target.path)
  end

  local prepared = child_options(instance, opts.instance, target.root)
  local child = instance.manager:create_instance(prepared)
  local ok, err = pcall(window.replace, child, target_winid)
  if not ok then
    pcall(child.destroy, child)
    error(err, 0)
  end
  window.sync_visibility(instance)
  child:_on_visibility_enter()
  place_selection_cursor(child, target_winid, target.cursor)
  return child
end

function M.tab_select(ctx, opts)
  local instance = instance_from(ctx)
  opts = exact_opts(opts, { instance = true }, "tab_select")
  validate_target(ctx.winid)
  local target = selection_target(ctx, instance)
  if target.kind == "noop" then return nil end
  local caller_tab = vim.api.nvim_get_current_tabpage()
  local caller_win = vim.api.nvim_get_current_win()
  local tabs_before = snapshot_tabs()
  local buffers_before = snapshot_buffers()
  local child
  if target.kind == "directory" then
    local prepared = child_options(instance, opts.instance, target.root)
    child = instance.manager:create_instance(prepared)
  end
  local file_bufnr
  local file_created
  local ok, result = pcall(function()
    vim.cmd("tabnew")
    local target_winid = vim.api.nvim_get_current_win()
    if child then
      window.replace(child, target_winid)
      child:_on_visibility_enter()
      place_selection_cursor(child, target_winid, target.cursor)
      return child
    end
    file_bufnr, file_created = file_buffer(target.path)
    vim.api.nvim_win_set_buf(target_winid, file_bufnr)
    return file_bufnr
  end)
  if not ok then
    if child then pcall(child.destroy, child) end
    remove_created_tabs(tabs_before, buffers_before, caller_tab, caller_win)
    cleanup_file_buffer(file_bufnr, file_created)
    error(result, 0)
  end
  return result
end

function M.split_select(ctx, opts)
  local instance = instance_from(ctx)
  opts = exact_opts(opts, { layout = true, instance = true }, "split_select")
  validate_target(ctx.winid)
  if opts.layout == nil then fail("split_select.layout is required", 3) end
  local target = selection_target(ctx, instance)
  if target.kind == "noop" then return nil end
  window.prepare_split(opts.layout)
  if target.kind == "directory" then
    local prepared = child_options(instance, opts.instance, target.root)
    local child = instance.manager:create_instance(prepared)
    local ok, winid = pcall(child.open, child, config.copy(opts.layout))
    if not ok then
      pcall(child.destroy, child)
      error(winid, 0)
    end
    place_selection_cursor(child, winid, target.cursor)
    return child
  end

  local bufnr, created = file_buffer(target.path)
  local ok, result = pcall(window.split_buffer, bufnr, config.copy(opts.layout))
  if not ok then
    cleanup_file_buffer(bufnr, created)
    error(result, 0)
  end
  return bufnr
end

function M.destroy(ctx, opts)
  no_options(opts, "destroy")
  return instance_from(ctx):destroy()
end

local function report_internal(instance, message)
  if instance and type(instance._report_async_error) == "function" then
    instance:_report_async_error(message)
  else
    pcall(vim.notify, "fre: " .. tostring(message), vim.log.levels.ERROR)
  end
end

local function safe_method(instance, object, method, ...)
  if object == nil or type(object[method]) ~= "function" then return true end
  local ok, err = pcall(object[method], object, ...)
  if not ok then report_internal(instance, "write UI " .. method .. " failed: " .. tostring(err)) end
  return ok
end

local function release(instance, token)
  local ok, err = pcall(instance._release_write_lock, instance, token)
  if not ok then report_internal(instance, "write unlock failed: " .. tostring(err)) end
end

local function validate_display(display)
  if type(display) ~= "table" then fail("confirmation display must be a string array", 4) end
  local count = 0
  for key, line in pairs(display) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(line) ~= "string" then
      fail("confirmation display must be a string array", 4)
    end
    count = count + 1
  end
  if count ~= #display then fail("confirmation display must not contain nil holes", 4) end
end

function M.confirm(ctx, display, on_decision)
  instance_from(ctx)
  validate_display(display)
  if type(on_decision) ~= "function" then fail("confirmation callback must be a function", 3) end
  return ui_adapter.confirm(ctx, display, on_decision)
end

local function report_outcome(ctx, outcome, reconciliation_error)
  local instance = ctx.instance
  if type(ui_adapter.report) ~= "function" then return end
  local ok, err = pcall(ui_adapter.report, ctx, outcome, reconciliation_error)
  if not ok then report_internal(instance, "write UI report failed: " .. tostring(err)) end
end

function M.write(ctx, _opts)
  local instance = instance_from(ctx)
  local token = instance:_acquire_write_lock()
  instance._last_write_result = nil
  token.phase = "preparing"
  token.ctx = ctx

  local function close_confirmation()
    local handle = token.confirmation_ui
    token.confirmation_ui = nil
    safe_method(instance, handle, "close", true)
  end

  local function close_progress()
    local handle = token.progress_ui
    token.progress_ui = nil
    safe_method(instance, handle, "close", true)
  end

  local function finish_before_execution()
    if token.phase == "finished" then return end
    token.phase = "finished"
    close_confirmation()
    close_progress()
    token.execution = nil
    release(instance, token)
    token.ctx = nil
  end

  local function finish_reconciliation(outcome, reconciliation_error)
    if token.phase == "finished" then return end
    token.phase = "finished"
    close_confirmation()
    close_progress()
    token.execution = nil
    if reconciliation_error ~= nil then instance.needs_refresh = true end
    local execution
    if outcome ~= nil then execution = vim.deepcopy(outcome) end
    instance._last_write_result = {
      execution = execution,
      reconciliation_error = reconciliation_error,
    }
    release(instance, token)
    report_outcome(ctx, outcome, reconciliation_error)
    token.ctx = nil
  end

  local function reconcile(outcome)
    token.phase = "reconciling"
    local ok, err = pcall(instance._reconcile_write, instance, token, function(reconciliation_error)
      finish_reconciliation(outcome, reconciliation_error)
    end)
    if not ok then finish_reconciliation(outcome, err) end
  end

  local function begin_execution(plan)
    close_confirmation()
    token.phase = "starting-execution"
    local execution
    local ok, execution_or_error = pcall(instance._execute_write, instance, token, plan, {
      on_progress = function(status)
        safe_method(instance, token.progress_ui, "update", status)
      end,
      on_complete = function(_execution_error, result)
        if token.phase == "finished" or token.phase == "reconciling" then return end
        close_progress()
        token.execution = nil
        reconcile(result)
      end,
    })
    if not ok then
      finish_before_execution()
      error(execution_or_error, 0)
    end
    execution = execution_or_error
    token.execution = execution
    token.phase = "executing"

    local progress_ok, progress_or_error = pcall(ui_adapter.progress, ctx,
      execution:get_status(), function()
        if token.phase ~= "executing" or token.execution ~= execution then return end
        local cancel_ok, cancel_error = pcall(execution.cancel, execution)
        if not cancel_ok then
          report_internal(instance, "write progress cancellation failed: " .. tostring(cancel_error))
        end
      end)
    if progress_ok then
      if token.phase == "executing" then
        token.progress_ui = progress_or_error
      else
        safe_method(instance, progress_or_error, "close", true)
      end
    else
      report_internal(instance, "write progress UI failed: " .. tostring(progress_or_error))
      local cancel_ok, cancel_error = pcall(execution.cancel, execution)
      if not cancel_ok then
        report_internal(instance, "write cancellation after UI failure failed: " .. tostring(cancel_error))
      end
    end
    return execution
  end

  local prepare_ok, plan_or_error = pcall(instance._prepare_write, instance, token)
  if not prepare_ok then
    finish_before_execution()
    error(plan_or_error, 0)
  end
  local plan = plan_or_error
  if #plan.operations == 0 then
    reconcile(nil)
    return nil
  end

  token.phase = "confirming"
  local function decide(accepted)
    if token.phase ~= "confirming" then return end
    if accepted ~= true then
      finish_before_execution()
      return
    end
    local ok, err = pcall(begin_execution, plan)
    if not ok then
      if token.execution ~= nil then
        local cancel_ok, cancel_error = pcall(token.execution.cancel, token.execution)
        if not cancel_ok then
          report_internal(instance, "write cancellation failed: " .. tostring(cancel_error))
        end
      else
        finish_before_execution()
      end
      report_internal(instance, err)
    end
  end
  local confirm_ok, confirmation_or_error = pcall(M.confirm, ctx, plan.display, decide)
  if not confirm_ok then
    finish_before_execution()
    error(confirmation_or_error, 0)
  end
  if token.phase == "confirming" then
    token.confirmation_ui = confirmation_or_error
  else
    safe_method(instance, confirmation_or_error, "close", true)
  end
  return nil
end

function M._set_ui_adapter(adapter)
  if type(adapter) ~= "table" or type(adapter.confirm) ~= "function"
      or type(adapter.progress) ~= "function" then
    fail("write UI adapter must provide confirm() and progress()", 2)
  end
  ui_adapter = adapter
end

function M._reset_ui_adapter()
  ui_adapter = default_ui
end

return M
