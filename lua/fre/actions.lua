local buffer = require("fre.buffer")
local config = require("fre.config")
local default_ui = require("fre.write_ui")
local mapping = require("fre.mapping")
local path = require("fre.path")
local view = require("fre.view")
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

local function validate_source(ctx, instance)
  if type(ctx.bufnr) ~= "number" or ctx.bufnr ~= instance.bufnr
      or type(ctx.tabpage) ~= "number" or not vim.api.nvim_tabpage_is_valid(ctx.tabpage)
      or type(ctx.winid) ~= "number" or not vim.api.nvim_win_is_valid(ctx.winid)
      or vim.api.nvim_win_get_tabpage(ctx.winid) ~= ctx.tabpage
      or vim.api.nvim_win_get_buf(ctx.winid) ~= instance.bufnr then
    fail("action context source is no longer valid", 4)
  end
end

local function capture_target(instance, winid)
  validate_target(winid)
  return {
    winid = winid,
    tabpage = vim.api.nvim_win_get_tabpage(winid),
    bufnr = vim.api.nvim_win_get_buf(winid),
    owner = view.owner(instance.manager, winid),
  }
end

local function recheck_target(instance, captured)
  validate_target(captured.winid)
  if vim.api.nvim_win_get_tabpage(captured.winid) ~= captured.tabpage
      or vim.api.nvim_win_get_buf(captured.winid) ~= captured.bufnr
      or view.owner(instance.manager, captured.winid) ~= captured.owner then
    fail("target window changed during selection preparation", 4)
  end
end

local function split_anchor(ctx, explicit)
  local anchor = explicit
  if anchor == nil then
    if vim.api.nvim_win_get_config(ctx.winid).relative ~= "" then
      fail("split_select.anchor_winid is required for a float source", 4)
    end
    anchor = ctx.winid
  end
  if type(anchor) ~= "number" or anchor % 1 ~= 0
      or not vim.api.nvim_win_is_valid(anchor)
      or vim.api.nvim_win_get_tabpage(anchor) ~= ctx.tabpage
      or vim.api.nvim_win_get_config(anchor).relative ~= "" then
    fail("split anchor window must be an exact ordinary window in the source tab", 4)
  end
  return anchor
end

local function recheck_anchor(ctx, anchor)
  if not vim.api.nvim_win_is_valid(anchor)
      or vim.api.nvim_win_get_tabpage(anchor) ~= ctx.tabpage
      or vim.api.nvim_win_get_config(anchor).relative ~= "" then
    fail("split anchor window is no longer valid", 4)
  end
end

local function expanded_under(instance, root)
  local result = {}
  for _, expanded_path in ipairs(instance:_active_expanded_paths()) do
    local relative = path.relative(root, expanded_path)
    if relative and relative ~= "" then result[#result + 1] = relative end
  end
  return result
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
    return {
      kind = "directory",
      root = entry.absolute_path,
      entry = entry,
      expanded = expanded_under(instance, entry.absolute_path),
    }
  end
  return { kind = "file", path = entry.absolute_path, entry = entry }
end

local function preflight_child_options(overrides)
  if overrides == nil then return {} end
  if type(overrides) ~= "table" then fail("opts.instance must be a table", 4) end
  if overrides.root ~= nil then fail("opts.instance.root is action-owned", 4) end
  return overrides
end

local function child_options(instance, overrides, target)
  local result = config.copy(preflight_child_options(overrides))
  if result.sort == nil then result.sort = instance.current_sort end
  if result.hidden_file == nil then result.hidden_file = instance.current_hidden_file end
  result.expanded = config.copy(target.expanded or {})
  result.root = target.root
  return result
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

local function validate_selection_options(opts, target, name)
  if opts.hide_source ~= nil and type(opts.hide_source) ~= "boolean" then
    fail(name .. ".hide_source must be a boolean", 4)
  end
  if target.kind == "file" and opts.instance ~= nil then
    fail(name .. ".instance is only valid for directory selections", 4)
  end
  if opts.instance ~= nil then preflight_child_options(opts.instance) end
  return opts.hide_source or false
end

local function prepare_selection(instance, target, overrides)
  if target.kind == "file" then
    local bufnr, created = file_buffer(target.path)
    return { kind = "file", bufnr = bufnr, created = created }
  end
  local options = child_options(instance, overrides, target)
  return {
    kind = "child",
    child = instance.manager:create_instance(options),
  }
end

local function cleanup_prepared(prepared)
  if not prepared then return nil end
  if prepared.kind == "file" then
    cleanup_file_buffer(prepared.bufnr, prepared.created)
    return nil
  end
  local ok, err = pcall(prepared.child.destroy, prepared.child)
  return ok and nil or err
end

local function precommit_error(prepared, err)
  local cleanup_err = cleanup_prepared(prepared)
  if cleanup_err then
    err = tostring(err) .. "; selection cleanup failed: " .. tostring(cleanup_err)
  end
  error(err, 0)
end

local function install_selection(instance, prepared, captured)
  recheck_target(instance, captured)
  if prepared.kind == "file" then
    window.replace_buffer(instance, captured.winid, prepared.bufnr)
    return nil
  end
  return window.install(prepared.child, captured.winid)
end

local function commit_ownership(target, prepared, captured, previous, destination)
  if prepared.kind == "file" then
    if captured.owner then view.detach(captured.owner, captured.winid) end
    return prepared.bufnr
  end
  local child = prepared.child
  if captured.owner then
    view.transfer(captured.owner, child, captured.winid)
  elseif destination then
    view.adopt_created(
      child, captured.winid, destination.layout, destination.origin_winid
    )
  else
    view.adopt(child, captured.winid, previous.bufnr)
  end
  buffer.place_initial_cursor(child, captured.winid)
  if target.cursor then child:set_cursor_to_path(target.cursor, captured.winid) end
  return child
end

local function finish_select(ctx, instance, target_winid, hide_source)
  vim.api.nvim_set_current_win(target_winid)
  if hide_source and view.select(instance, ctx.tabpage) == ctx.winid then
    instance:hidden(ctx.tabpage)
  end
end

local function restore_caller(tabpage, winid)
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, tabpage)
  end
  if vim.api.nvim_win_is_valid(winid) then pcall(vim.api.nvim_set_current_win, winid) end
end


function M.context()
  return mapping.context()
end

function M.jump_to_path(ctx, opts)
  no_options(opts, "jump_to_path")
  local instance = instance_from(ctx)
  local range = ctx.path_range
  if (ctx.row_kind ~= "entry" and ctx.row_kind ~= "navigation")
      or type(range) ~= "table" or type(range.start_byte) ~= "number" then
    return nil
  end
  local winid = ctx.winid
  if type(winid) ~= "number" or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then
    return nil
  end
  vim.api.nvim_win_set_cursor(winid, { ctx.row, range.start_byte })
  return instance
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

function M.collapse_all(ctx, opts)
  no_options(opts, "collapse_all")
  return instance_from(ctx):collapse_all()
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
  if vim.bo[instance.bufnr].modified then
    return instance:refresh({ force = true })
  end
  return instance:refresh()
end

function M.select(ctx, opts)
  local instance = instance_from(ctx)
  opts = exact_opts(opts, {
    target_winid = true, hide_source = true, instance = true,
  }, "select")
  local target = selection_target(ctx, instance)
  local hide_source = validate_selection_options(opts, target, "select")
  validate_source(ctx, instance)
  local captured = capture_target(instance, opts.target_winid or ctx.winid)
  if target.kind == "noop" then return nil end

  local prepared = prepare_selection(instance, target, opts.instance)
  local installed, previous = pcall(function()
    validate_source(ctx, instance)
    return install_selection(instance, prepared, captured)
  end)
  if not installed then precommit_error(prepared, previous) end
  local result = commit_ownership(target, prepared, captured, previous)
  finish_select(ctx, instance, captured.winid, hide_source)
  return result
end

function M.tab_select(ctx, opts)
  local instance = instance_from(ctx)
  opts = exact_opts(opts, { hide_source = true, instance = true }, "tab_select")
  local target = selection_target(ctx, instance)
  local hide_source = validate_selection_options(opts, target, "tab_select")
  validate_source(ctx, instance)
  if target.kind == "noop" then return nil end

  local prepared = prepare_selection(instance, target, opts.instance)
  local created_tab
  local target_winid
  local destination_bufnr
  local captured
  local installed, previous = pcall(function()
    validate_source(ctx, instance)
    created_tab, target_winid, destination_bufnr = window.create_tab()
    validate_source(ctx, instance)
    captured = capture_target(instance, target_winid)
    local snapshot = install_selection(instance, prepared, captured)
    window.discard_buffer(destination_bufnr)
    return snapshot
  end)
  if not installed then
    if created_tab then window.close_tab(created_tab) end
    restore_caller(ctx.tabpage, ctx.winid)
    precommit_error(prepared, previous)
  end

  local result = commit_ownership(target, prepared, captured, previous, {
    layout = { position = "current" },
    origin_winid = ctx.winid,
  })
  finish_select(ctx, instance, target_winid, hide_source)
  return result
end

function M.split_select(ctx, opts)
  local instance = instance_from(ctx)
  opts = exact_opts(opts, {
    layout = true, anchor_winid = true, hide_source = true, instance = true,
  }, "split_select")
  if opts.layout == nil then fail("split_select.layout is required", 3) end
  local target = selection_target(ctx, instance)
  local hide_source = validate_selection_options(opts, target, "split_select")
  validate_source(ctx, instance)
  local anchor = split_anchor(ctx, opts.anchor_winid)
  local normalized, effective = window.prepare_split(opts.layout, anchor)
  if target.kind == "noop" then return nil end

  local prepared = prepare_selection(instance, target, opts.instance)
  local target_winid
  local destination_bufnr
  local captured
  local installed, previous = pcall(function()
    validate_source(ctx, instance)
    recheck_anchor(ctx, anchor)
    normalized, effective = window.prepare_split(normalized, anchor)
    target_winid, destination_bufnr = window.create_split(normalized, effective, anchor)
    validate_source(ctx, instance)
    recheck_anchor(ctx, anchor)
    captured = capture_target(instance, target_winid)
    local snapshot = install_selection(instance, prepared, captured)
    window.discard_buffer(destination_bufnr)
    return snapshot
  end)
  if not installed then
    if target_winid then window.close_window(target_winid) end
    restore_caller(ctx.tabpage, ctx.winid)
    precommit_error(prepared, previous)
  end

  local result = commit_ownership(target, prepared, captured, previous, {
    layout = normalized,
    origin_winid = anchor,
  })
  finish_select(ctx, instance, target_winid, hide_source)
  return result
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

local function is_simple_edit(operations)
  local creates, moves, copies = 0, 0, 0
  for _, operation in ipairs(operations) do
    if operation.type == "create_file" or operation.type == "create_directory" then
      creates = creates + 1
    elseif operation.type == "move" then
      moves = moves + 1
    elseif operation.type == "copy" then
      copies = copies + 1
    else
      return false
    end
  end
  return creates <= 5 and moves <= 1 and copies <= 1
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

  local function start_execution(plan)
    local ok, err = pcall(begin_execution, plan)
    if ok then return end
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
  if instance.config.skip_confirm_for_simple_edits and is_simple_edit(plan.operations) then
    start_execution(plan)
    return nil
  end

  token.phase = "confirming"
  local function decide(accepted)
    if token.phase ~= "confirming" then return end
    if accepted ~= true then
      finish_before_execution()
      return
    end
    start_execution(plan)
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
