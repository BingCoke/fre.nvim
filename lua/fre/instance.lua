local config = require("fre.config")
local buffer = require("fre.instance.buffer")
local fs = require("fre.fs")
local path = require("fre.path")
local mutation_fs = require("fre.mutation.fs")
local Work = require("fre.instance.work")
local Tree = require("fre.instance.tree")
local Lifecycle = require("fre.instance.lifecycle")
local Events = require("fre.instance.events")
local Sync = require("fre.instance.sync")
local view = require("fre.instance.view")
local watch = require("fre.watch")
local write_ui = require("fre.write_ui")

local Instance = {}
Instance.__index = Instance

local required_options = {
  buftype = "acwrite",
  bufhidden = "hide",
  swapfile = false,
  buflisted = false,
}

local function copy(value)
  return config.copy(value)
end

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function require_ready(instance)
  if instance.lifecycle:is_dead() then fail("instance is destroyed", 4) end
  if not instance.lifecycle:is_ready() then fail("instance is not ready", 4) end
end

local function report_async_error(err)
  pcall(vim.notify, "fre: " .. tostring(err), vim.log.levels.ERROR)
end

function Instance:status()
  return self.lifecycle:status()
end

function Instance:is_ready()
  return self.lifecycle:is_ready()
end

function Instance:is_destroying()
  return self.lifecycle:is_destroying()
end

function Instance:is_destroyed()
  return self.lifecycle:is_destroyed()
end

function Instance:failure()
  return self.lifecycle:failure()
end

function Instance:result_value()
  return self.sync:result_value()
end

function Instance:inspect_action_row(row_number, allow_undecodable)
  local decoded
  if allow_undecodable then
    local ok, value = pcall(self.buffer.decode, self.buffer, row_number)
    if ok then decoded = value end
  else
    decoded = self.buffer:decode(row_number)
  end
  return {
    row_kind = decoded and decoded.row_kind or nil,
    navigation_kind = decoded and decoded.navigation_kind or nil,
    source_instance_id = decoded and decoded.source_instance_id or nil,
    entry = decoded and decoded.entry or nil,
    path_range = decoded and decoded.path_range or nil,
  }
end




function Instance:when_ready(callback)
  if type(callback) ~= "function" then
    fail("when_ready callback must be a function", 2)
  end
  self.lifecycle:observe(callback)
  return self
end

local function split_relative(relative)
  local result = {}
  for segment in relative:gmatch("[^/]+") do result[#result + 1] = segment end
  return result
end


function Instance:_require_projection_change()
  if self.lifecycle:is_dead() then
    fail("instance is destroyed", 3)
  end
  require_ready(self)
  if self.work:is_write_active() then fail("instance is write-locked", 3) end
  if self.sync:is_full_refresh_busy() then fail("refresh is already in progress", 3) end
  if vim.bo[self.bufnr].modified then
    fail("buffer is modified; write or discard changes before changing the tree", 3)
  end
  self.sync:cancel_active_watch_refresh()
end











function Instance:get_sort()
  return self.tree:get_comparator()
end

function Instance:get_hidden_file()
  return self.buffer:hidden_files()
end

function Instance:get_expanded_paths()
  return self.tree:active_expanded_paths()
end


function Instance:set_sort(sort_fn)
  if type(sort_fn) ~= "function" then fail("sort must be a function", 2) end
  self:_require_projection_change()
  self.tree:set_comparator(sort_fn)
  return self:refresh()
end

function Instance:set_hidden_file(hidden_file)
  if type(hidden_file) ~= "boolean" then
    fail("hidden_file must be a boolean", 2)
  end
  self:_require_projection_change()
  if hidden_file == self.buffer:hidden_files() then return nil end
  self.buffer:set_hidden_files(hidden_file)
  return nil
end

function Instance:toggle_hidden_file()
  return self:set_hidden_file(not self.buffer:hidden_files())
end


function Instance:expand(snapshot_path)
  self:_require_projection_change()
  return self.sync:expand(snapshot_path)
end

function Instance:collapse(snapshot_path)
  self:_require_projection_change()
  self.sync:collapse(snapshot_path)
  return nil
end

function Instance:collapse_all()
  self:_require_projection_change()
  self.sync:collapse_all()
  self.sync:schedule_followup()
  return nil
end

function Instance:toggle_expand(snapshot_path)
  self:_require_projection_change()
  return self.sync:toggle_expand(snapshot_path)
end

function Instance:get_entry(row)
  require_ready(self)
  local decoded = self.buffer:decode(row)
  if not decoded or not decoded.marked then
    return nil
  end
  return decoded.entry
end

function Instance:get_pos(snapshot_path)
  require_ready(self)
  if type(snapshot_path) ~= "string" then
    fail("snapshot path must be a string", 2)
  end
  local relative = path.normalize_relative(snapshot_path, { windows = path.is_windows(self.root) })
  local absolute = path.resolve(self.root, relative)
  local node = self.tree:node_by_path(absolute)
  if not node then return nil end
  return self.buffer:position(node)
end

function Instance:set_cursor_to_path(snapshot_path, winid)
  if type(snapshot_path) ~= "string" then fail("snapshot path must be a string", 2) end
  if type(winid) ~= "number" or winid % 1 ~= 0 then
    fail("target window must be a window ID", 2)
  end
  local function place()
    if not vim.api.nvim_win_is_valid(winid) then fail("target window is not valid", 3) end
    if vim.api.nvim_win_get_buf(winid) ~= self.bufnr then
      fail("target window does not display this instance", 3)
    end
    local position = self:get_pos(snapshot_path)
    if not position then fail("snapshot path is not visible: " .. snapshot_path, 3) end
    vim.api.nvim_win_set_cursor(winid, position)
  end
  if self.lifecycle:is_ready() then
    place()
  elseif self.lifecycle:is_creating() then
    self:when_ready(function(ready_err)
      if ready_err == nil then place() end
    end)
  else
    require_ready(self)
  end
  return self
end

function Instance:reveal(snapshot_path)
  if self.lifecycle:is_dead() then
    fail("instance is destroyed", 2)
  end
  require_ready(self)
  local relative, absolute = self.sync:normalize_snapshot_path(snapshot_path)
  if relative == "" then fail("the instance root has no revealable row", 2) end
  local segments = split_relative(relative)
  if not self.buffer:hidden_files() then
    for _, segment in ipairs(segments) do
      if segment:sub(1, 1) == "." then
        fail("path is hidden; enable hidden files explicitly before reveal: " .. relative, 2)
      end
    end
  end

  local position = self:get_pos(relative)
  if not position then self:_require_projection_change() end

  self._reveal_generation = self._reveal_generation + 1
  local target_tabpage = vim.api.nvim_get_current_tabpage()
  local target_winid = view.select(self.view, target_tabpage)
  local request = {
    generation = self._reveal_generation,
    relative = relative,
    absolute = absolute,
    active = true,
    synchronous = true,
  }

  local function current()
    return request.active and not self.lifecycle:is_dead()
      and request.generation == self._reveal_generation
  end
  local function stop(err)
    if not current() then return end
    request.active = false
    if err then
      if request.synchronous then fail(err, 4) end
      report_async_error(err)
      return
    end
    if not target_winid then return end
    pcall(function()
      if not vim.api.nvim_win_is_valid(target_winid)
          or vim.api.nvim_win_get_tabpage(target_winid) ~= target_tabpage
          or vim.api.nvim_win_get_buf(target_winid) ~= self.bufnr then return end
      local target = self:get_pos(request.relative)
      if target then vim.api.nvim_win_set_cursor(target_winid, target) end
    end)
  end
  local function finish(parent)
    if not current() then return end
    local target = self.tree:find_child(parent, segments[#segments])
    if not target or self.tree:node_by_path(target.path) ~= target then
      stop("snapshot path does not exist: " .. relative)
      return
    end
    request.absolute = target.path
    request.relative = assert(path.relative(self.root, target.path))
    stop(nil)
  end
  local function walk(parent, index)
    if not current() then return end
    if index == #segments then finish(parent); return end
    local child = self.tree:find_child(parent, segments[index])
    local prefix = table.concat(vim.list_slice(segments, 1, index), "/")
    if not child then
      stop("snapshot path does not exist: " .. prefix)
      return
    end
    if child.kind ~= "directory" then
      stop(prefix .. " is a " .. tostring(child.kind) .. " and cannot contain the reveal target")
      return
    end
    if child.expanded and child.loaded then
      walk(child, index + 1)
      return
    end
    self.sync:expand(prefix, function(err)
      if not current() then return end
      if err then stop(err); return end
      local expanded = self.tree:node_by_path(child.path)
      if not expanded then stop("snapshot path does not exist: " .. prefix); return end
      walk(expanded, index + 1)
    end, false, { auto_expand = false, rescan_loaded = false })
  end

  if position then
    stop(nil)
  else
    walk(self.tree:root_node(), 1)
  end
  request.synchronous = false
  return nil
end




function Instance:refresh(opts)
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then fail("refresh options must be a table", 2) end
  for key in pairs(opts) do
    if key ~= "force" and key ~= "on_complete" then
      fail("refresh options contain unknown field " .. tostring(key), 2)
    end
  end
  local force = opts.force
  if force == nil then force = false end
  if type(force) ~= "boolean" then fail("refresh.force must be a boolean", 2) end
  if opts.on_complete ~= nil and type(opts.on_complete) ~= "function" then
    fail("refresh.on_complete must be a function", 2)
  end
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  if self.lifecycle:is_creating() then fail("instance is still loading", 2) end
  if self.work:is_write_active() then fail("instance is write-locked", 2) end
  if self.sync:is_busy() then fail("refresh is already in progress", 2) end
  if self.lifecycle:is_load_failed() then
    self.lifecycle:begin_load()
    self.sync:load_initial(opts.on_complete)
    return nil
  end
  if not self.lifecycle:is_ready() then fail("instance is not ready", 2) end
  for _, node in self.tree:iter_nodes() do
    if node.kind == "directory"
        and (node.load_state == "loading" or node.load_state == "refreshing") then
      fail("a directory load is already in progress", 2)
    end
  end
  if vim.bo[self.bufnr].modified and not force then
    fail("buffer is modified; pass force = true to discard changes", 2)
  end
  self.sync:cancel_active_watch_refresh()
  self.sync:refresh(force, opts.on_complete, false)
  return nil
end

function Instance:inspect_view(location)
  if not self.view then return nil end
  return view.inspect(self.view, location)
end

function Instance:release_view(winid)
  return view.release(self.view, winid)
end

function Instance:take_view(source_instance, winid)
  return view.take(self.view, source_instance.view, winid)
end

function Instance:adopt_view(winid, presentation)
  return view.adopt(self.view, winid, presentation)
end

function Instance:place_initial_cursor(winid)
  view.place_initial_cursor(self.view, winid)
  return self
end

function Instance:capture_view_errors()
  return view.capture_errors(self.view)
end

function Instance:sync_view(opts)
  return view.sync(self.view, opts)
end

function Instance:open(layout)
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  return self, view.open(self.view, layout)
end

function Instance:hidden(tabpage)
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  return view.hidden(self.view, tabpage)
end

function Instance:hide_all()
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  return view.hide_all(self.view)
end

function Instance:toggle(layout)
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  local result = view.toggle(self.view, layout)
  return type(result) == "number" and self or result
end

function Instance:write(ctx)
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  if ctx == nil then ctx = {} end
  if type(ctx) ~= "table" then fail("write context must be a table", 2) end
  return self.work:write({
    bufnr = ctx.bufnr,
    winid = ctx.winid,
    tabpage = ctx.tabpage,
    mode = ctx.mode,
    row = ctx.row,
    col = ctx.col,
  })
end

function Instance:prepare()
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  return self.work:prepare()
end

function Instance:execute(plan, handlers)
  if self.lifecycle:is_dead() then fail("instance is destroyed", 2) end
  return self.work:execute(plan, handlers)
end

local function new_destroy_operation(
    id, bufnr, lifecycle, view_state, buffer_state, sync, work, tree
)
  return function()
    if not lifecycle:is_destroying() and not lifecycle:is_destroyed() then
      if work:is_write_active() then fail("instance is write-locked", 3) end
      if work:is_execution_active() then
        fail("cannot destroy an instance with an active execution", 3)
      end
    end
    if lifecycle:is_destroyed() then fail("instance is destroyed", 3) end
    if lifecycle:begin_destroy() then
      Events.destroying(id, bufnr)
      pcall(view.hide_all, view_state)
      view.destroy(view_state)
      buffer_state:clear_initial_cursors()
      pcall(work.destroy, work)
      pcall(sync.destroy, sync)
      tree:invalidate_loads(tree:root_node())
    end

    local delete_error
    if vim.api.nvim_buf_is_valid(bufnr) then
      local ok, err = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      if not ok then delete_error = err end
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("bwipeout!")
      end)
      if not ok then delete_error = err end
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      error("fre: failed to delete instance buffer: " .. tostring(delete_error), 2)
    end
    pcall(buffer.teardown, buffer_state)
    lifecycle:finish_destroy()
    Events.destroyed(id, bufnr)
    return nil
  end
end

function Instance:destroy()
  return self.buffer.request_destroy()
end

local function invalidate_failed_constructor(self)
  if self.lifecycle then self.lifecycle:discard() end
  if self.sync then pcall(self.sync.destroy, self.sync) end
  if self.work then pcall(self.work.destroy, self.work) end
  if self.tree then self.tree:invalidate_loads(self.tree:root_node()) end
  if self.buffer then self.buffer:clear_initial_cursors() end
end


local function wipe_failed_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return true end
  local _, delete_err = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if vim.api.nvim_buf_is_valid(bufnr) then
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("noautocmd bwipeout!")
    end)
    if not ok then delete_err = err end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    local ok, err = pcall(vim.cmd, "noautocmd bwipeout! " .. tostring(bufnr))
    if not ok then delete_err = err end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    return false, delete_err or "buffer remained valid"
  end
  return true
end

local function cleanup_failed_constructor(self, bufnr)
  if self._constructor_cleanup_done then return true end
  self._constructor_cleanup_done = true
  invalidate_failed_constructor(self)
  if self.buffer then pcall(buffer.teardown, self.buffer) end
  return wipe_failed_buffer(bufnr)
end


local core_fields = {
  "hidden_file",
  "skip_confirm_for_simple_edits",
  "auto_expand_single_directory",
  "sort",
  "expanded",
  "columns",
  "layout",
  "buffer",
  "window",
}

local function resolve_construction(options)
  if type(options) ~= "table" then fail("instance options must be a table", 3) end
  if options.root == nil then fail("root is required", 3) end
  if type(options.root) ~= "string" then fail("root must be a string", 3) end
  if options.root == "" then fail("root must not be empty", 3) end

  local root = path.absolute(options.root)
  local core_options = {}
  for _, field in ipairs(core_fields) do
    if options[field] ~= nil then core_options[field] = options[field] end
  end
  local effective = config.resolve_instance(config.builtins(), core_options, root)
  return {
    root = root,
    effective = effective,
    registry = options.registry or require("fre.registry").default,
    fs_adapter = options.fs_adapter or fs.default,
    watch_adapter = options.watch_adapter or watch.default,
    mutation_adapter = options.mutation_adapter or mutation_fs.default,
    write_ui_adapter = options.write_ui_adapter or write_ui,
  }
end

function Instance.new(options)
  local selected = resolve_construction(options)
  local root = selected.root
  local effective = selected.effective
  local registry = selected.registry
  local fs_adapter = selected.fs_adapter
  local watch_adapter = selected.watch_adapter
  local mutation_adapter = selected.mutation_adapter
  local write_ui_adapter = selected.write_ui_adapter
  local id = registry:allocate_instance_id()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local self = setmetatable({
    id = id,
    bufnr = bufnr,
  }, Instance)

  local ok, result = xpcall(function()
    self.root = root
    self.lifecycle = Lifecycle.new({
      schedule = vim.schedule,
      emit_ready = function(err, ready_result)
        Events.ready(id, bufnr, err, ready_result)
      end,
    })
    self._reveal_generation = 0

    vim.api.nvim_buf_set_name(bufnr, "fre://" .. tostring(id))
    for key, value in pairs(required_options) do
      vim.bo[bufnr][key] = value
    end
    for key, value in pairs(effective.buffer.options or {}) do
      vim.bo[bufnr][key] = value
    end
    vim.bo[bufnr].filetype = "fre"
    vim.bo[bufnr].syntax = "fre"
    vim.b[bufnr].fre = {
      version = 1,
      instance_id = id,
      root = root,
    }
    for key, value in pairs(effective.buffer.variables or {}) do
      if key ~= "fre" then vim.b[bufnr][key] = copy(value) end
    end

    self.tree = Tree.new(root, id, effective.sort, registry)
    self.buffer = buffer.new({
      id = id,
      root = root,
      bufnr = bufnr,
      columns = effective.columns,
      tree = self.tree,
      lifecycle = self.lifecycle,
      hidden_file = effective.hidden_file,
      registry = registry,
      report_async_error = report_async_error,
    })
    self.view = view.new({
      id = id,
      bufnr = bufnr,
      lifecycle = self.lifecycle,
      buffer = self.buffer,
      layout = effective.layout,
      window_options = effective.window.options,
    })
    self.sync = Sync.new({
      id = id,
      root = root,
      tree = self.tree,
      buffer = self.buffer,
      lifecycle = self.lifecycle,
      view = self.view,
      expanded = effective.expanded,
      auto_expand_single_directory = effective.auto_expand_single_directory,
      fs_adapter = fs_adapter,
      schedule = vim.schedule,
      bufnr = bufnr,
      report_error = report_async_error,
      watch_adapter = watch_adapter,
    })
    self.work = Work.new({
      id = id,
      root = root,
      bufnr = bufnr,
      lifecycle = self.lifecycle,
      tree = self.tree,
      buffer = self.buffer,
      sync = self.sync,
      skip_confirm_for_simple_edits = effective.skip_confirm_for_simple_edits,
      mutation_adapter = mutation_adapter,
      write_ui_adapter = write_ui_adapter,
      report_error = report_async_error,
    })
    local request_destroy = new_destroy_operation(
      id, bufnr, self.lifecycle, self.view, self.buffer, self.sync, self.work, self.tree
    )
    buffer.attach(self.buffer, self.view, self.sync, self.work, request_destroy)
    self.sync:attach_work(self.work)
    view.attach_sync(self.view, self.sync)
    self.buffer:setup()
    self.sync:load_initial()
    Events.created(id, bufnr)
    return self
  end, function(err) return err end)

  if ok then return result end
  local cleaned, cleanup_err = cleanup_failed_constructor(self, bufnr)
  if not cleaned then
    error(tostring(result) .. "; cleanup failed: instance buffer " .. tostring(bufnr)
      .. " survived: " .. tostring(cleanup_err), 0)
  end
  error(result, 0)
end

return Instance
