local config = require("fre.config")
local buffer = require("fre.buffer")
local mapping = require("fre.mapping")
local path = require("fre.path")
local mutation_execute = require("fre.mutation.execute")
local mutation_prepare = require("fre.mutation.prepare")
local Tree = require("fre.tree")
local Watch = require("fre.watch")
local window = require("fre.window")

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
  if instance._destroyed or instance.state == "destroying" or instance.state == "destroyed" then
    fail("instance is destroyed", 4)
  end
  if instance.state == "creating" or instance.state == "load-failed" then
    fail("instance is not ready", 4)
  end
end

local function safe_string(value)
  local text = tostring(value)
  return (text:gsub("[\r\n]", " "))
end

local function display_name(instance, node)
  local relative = assert(path.relative(instance.root, node.path))
  if node.kind == "directory" then
    return relative .. "/"
  end
  return relative
end

function Instance:_entry(node)
  local relative_path = ""
  if node ~= self.root_node then
    relative_path = assert(path.relative(self.root, node.path))
  end
  return {
    instance_id = self.id,
    node_id = node.id,
    absolute_path = node.path,
    relative_path = relative_path,
    name = node.name,
    kind = node.kind,
  }
end

function Instance:_column_context(node, entry, descriptor, index, is_last)
  local mtime = node.mtime
  if type(mtime) == "table" then
    mtime = { sec = tonumber(mtime.sec) or 0, nsec = tonumber(mtime.nsec) or 0 }
  else
    mtime = { sec = tonumber(mtime) or 0, nsec = 0 }
  end
  return {
    entry = entry,
    descriptor = descriptor,
    config = descriptor,
    column_index = index,
    is_last = is_last,
    instance = { id = self.id, bufnr = self.bufnr, root = self.root },
    metadata = {
      kind = node.kind,
      mode = tonumber(node.mode) or 0,
      size = node.stat and tonumber(node.stat.size) or nil,
      mtime = mtime,
    },
  }
end

function Instance:_replace_lines(first, last, lines)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return false end
  local views = {}
  for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      views[winid] = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
    end
  end
  local was_modifiable = vim.bo[self.bufnr].modifiable
  vim.bo[self.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, first, last, false, lines)
  vim.bo[self.bufnr].modified = false
  vim.bo[self.bufnr].modifiable = was_modifiable
  for winid, view in pairs(views) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == self.bufnr then
      pcall(vim.api.nvim_win_call, winid, vim.fn.winrestview, view)
    end
  end
  return true
end

function Instance:_set_lines(lines)
  return self:_replace_lines(0, -1, lines)
end

function Instance:_loading_line()
  return "[fre] Loading " .. self.root
end

function Instance:_error_line(err)
  return "[fre] Error loading " .. safe_string(err)
end

function Instance:_projection()
  return self.tree:project(function(node)
    return self.current_hidden_file or node.name:sub(1, 1) ~= "."
  end)
end

function Instance:_prepare_projection(validate)
  local projection = self:_projection()
  return buffer.prepare(self, projection, function(node)
    return display_name(self, node)
  end, { validate = validate == true })
end

function Instance:_render_success()
  local projection = self:_projection()
  return buffer.project(self, projection, function(node)
    return display_name(self, node)
  end)
end

function Instance:_on_marker_width_changed(generation)
  self._marker_width_stale = true
  if self._destroyed or self.state == "destroying" or self.state == "destroyed" then
    return
  end
  if self.state ~= "ready-hidden" and self.state ~= "ready-visible" then return end
  if not vim.api.nvim_buf_is_valid(self.bufnr) or vim.bo[self.bufnr].modified then return end
  if (self.actions and self.actions.write) or self._refresh_request
      or self._watch_refresh_request then return end
  if self._execution and not mutation_execute.is_terminal(self._execution) then return end
  for _, node in pairs(self.nodes_by_id) do
    if node.kind == "directory"
        and (node.load_state == "loading" or node.load_state == "refreshing") then
      return
    end
  end

  local current_generation = self.manager:get_marker_widths().generation
  local view_generation = self.view and self.view.marker_generation or 0
  if view_generation >= generation and view_generation >= current_generation then
    self._marker_width_stale = false
    return
  end

  local ok, result = pcall(self._render_success, self)
  if not ok or result == false then
    local err = ok and "buffer projection commit failed" or result
    self._marker_width_stale = true
    self:_report_async_error("marker width reprojection failed: " .. tostring(err))
    return
  end
  view_generation = self.view and self.view.marker_generation or 0
  self._marker_width_stale = view_generation < self.manager:get_marker_widths().generation
end

function Instance:_snapshot_visibility()
  local snapshot = {}
  for _, node in pairs(self.nodes_by_id) do
    snapshot[node] = {
      visible_size = node.visible_size,
      visible_start = node.visible_start,
      visible_end = node.visible_end,
      visible_range = node.visible_range and copy(node.visible_range) or nil,
    }
  end
  return snapshot
end

function Instance:_restore_visibility(snapshot)
  for node, value in pairs(snapshot) do
    node.visible_size = value.visible_size
    node.visible_start = value.visible_start
    node.visible_end = value.visible_end
    node.visible_range = value.visible_range
  end
end


function Instance:_emit_ready(err, result)
  local data = {
    instance_id = self.id,
    bufnr = self.bufnr,
    error = err,
    result = result,
  }
  vim.api.nvim_exec_autocmds("User", {
    pattern = "FreReady",
    modeline = false,
    data = data,
  })
end

function Instance:_call_callback(callback, err)
  if not callback.active then
    return
  end
  callback.active = false
  local ok, callback_err = pcall(callback.fn, err)
  if not ok then
    vim.schedule(function()
      error(callback_err)
    end)
  end
end

function Instance:_schedule_callback(callback, err)
  vim.schedule(function()
    self:_call_callback(callback, err)
  end)
end

function Instance:_cancel_pending_callbacks()
  for _, callback in ipairs(self._ready_callbacks) do
    callback.active = false
  end
  self._ready_callbacks = {}
end


function Instance:_apply_configured_expansions(on_complete)
  local completed = false
  local function finish(err)
    if completed then return end
    completed = true
    on_complete(err)
  end
  local function apply(index)
    local relative = self.config.expanded[index]
    if relative == nil then
      finish(nil)
      return
    end
    local ok, err = pcall(self._expand, self, relative, function(expand_err)
      if expand_err ~= nil then
        finish("initial expansion failed for " .. relative .. ": " .. tostring(expand_err))
      else
        apply(index + 1)
      end
    end, true)
    if not ok then
      finish("initial expansion failed for " .. relative .. ": " .. tostring(err))
    end
  end
  apply(1)
end

function Instance:_finish_initial(token, generation, err, children, real_root, on_complete)
  if self._destroyed or self._attempt ~= token or self._attempt_done[token]
      or self.root_node.load_generation ~= generation then
    return
  end
  local completed = false
  local function complete(completion_err)
    if completed or self._destroyed or self._attempt ~= token or self._attempt_done[token]
        or self.root_node.load_generation ~= generation then
      return
    end
    completed = true
    self._attempt_done[token] = true
    local callbacks = self._ready_callbacks
    self._ready_callbacks = {}
    if completion_err ~= nil then
      self.root_node.load_state = "unloaded"
      self.root_node.loaded = false
      self.root_node.children_cached = false
      self.state = "load-failed"
      self.error = completion_err
      self.result = nil
      self.real_root = nil
      self.needs_refresh = true
      self:_set_lines({ self:_error_line(completion_err) })
    else
      self.state = #vim.fn.win_findbuf(self.bufnr) > 0 and "ready-visible" or "ready-hidden"
      self.error = nil
      self.needs_refresh = false
      self:_sync_watchers()
    end
    self.manager:gc_visibility_changed(self)
    -- This function already runs on the main loop. Existing observers complete
    -- before FreReady so reentrant event handlers cannot suppress them.
    for _, callback in ipairs(callbacks) do
      self:_call_callback(callback, completion_err)
    end
    self:_emit_ready(completion_err, self.result)
    if on_complete then
      local ok, callback_err = pcall(on_complete, completion_err)
      if not ok then vim.schedule(function() error(callback_err) end) end
    end
  end

  if err ~= nil then
    complete(err)
    return
  end
  local ok, value = pcall(function()
    local ordered = self.tree:reconcile(self.root_node, children or {}, function(a, b)
      return self.current_sort(
        self:_entry(self.root_node), self:_entry(a), self:_entry(b)
      )
    end)
    local snapshot = {}
    for _, node in ipairs(ordered) do
      snapshot[#snapshot + 1] = {
        id = node.id, name = node.name, path = node.path, kind = node.kind,
      }
    end
    return { children = snapshot, root = self.root }
  end)
  if not ok then
    complete(value)
    return
  end
  self.result = value
  self.real_root = real_root
  self.error = nil
  local render_ok, render_err = pcall(self._render_success, self)
  if not render_ok then
    complete(render_err)
    return
  end
  self._tree_generation = self._tree_generation + 1
  self:_apply_configured_expansions(complete)
end

function Instance:_start_load(initial, on_complete)
  self._attempt = self._attempt + 1
  local token = self._attempt
  self._attempt_done[token] = false
  self.root_node.load_generation = self.root_node.load_generation + 1
  local generation = self.root_node.load_generation
  self.root_node.load_state = "loading"
  self.root_node.loaded = false
  if initial then
    self.state = "creating"
    self.error = nil
    self.result = nil
    self:_set_lines({ self:_loading_line() })
  end
  local finished = false
  local function done(load_err, loaded_children, loaded_real_root)
    if finished then return end
    finished = true
    vim.schedule(function()
      if self._destroyed or token ~= self._attempt
          or generation ~= self.root_node.load_generation then
        return
      end
      self:_finish_initial(
        token, generation, load_err, loaded_children, loaded_real_root, on_complete
      )
    end)
  end
  local ok, adapter_err = pcall(self.manager:get_fs_adapter().load, self.root, done)
  if not ok then done(adapter_err) end
end

function Instance:when_ready(callback)
  if type(callback) ~= "function" then
    fail("when_ready callback must be a function", 2)
  end
  if self._destroyed then
    fail("instance is destroyed", 2)
  end
  local entry = { fn = callback, active = true }
  if self.state == "ready-hidden" or self.state == "ready-visible" then
    self:_schedule_callback(entry, nil, self._attempt)
  elseif self.state == "load-failed" then
    self:_schedule_callback(entry, self.error, self._attempt)
  else
    self._ready_callbacks[#self._ready_callbacks + 1] = entry
  end
  return self
end

local function split_relative(relative)
  local result = {}
  for segment in relative:gmatch("[^/]+") do result[#result + 1] = segment end
  return result
end

function Instance:_require_write_capability(token)
  if type(token) ~= "table" or token.released
      or not self.actions or self.actions.write ~= token then
    fail("invalid write capability", 3)
  end
end

function Instance:_acquire_write_lock()
  if self._destroyed or self.state == "destroying" or self.state == "destroyed" then
    fail("instance is destroyed", 3)
  end
  require_ready(self)
  if not vim.api.nvim_buf_is_valid(self.bufnr) then fail("instance buffer is not valid", 3) end
  if self.actions and self.actions.write then fail("instance is already write-locked", 3) end
  if self._refresh_request then fail("refresh is already in progress", 3) end
  if self._execution and not mutation_execute.is_terminal(self._execution) then
    fail("an execution is already in progress", 3)
  end
  if not vim.bo[self.bufnr].modifiable then
    fail("buffer is not modifiable", 3)
  end
  self:_cancel_watch_refresh()

  local actions = self.actions
  if type(actions) ~= "table" then
    actions = {}
    self.actions = actions
  end
  local token = {
    original_modifiable = vim.bo[self.bufnr].modifiable,
    released = false,
  }
  actions.write = token
  local ok, err = pcall(function() vim.bo[self.bufnr].modifiable = false end)
  if not ok then
    actions.write = nil
    if next(actions) == nil then self.actions = nil end
    token.released = true
    error(err, 0)
  end
  self.manager:gc_reconsider(self, false)
  return token
end

function Instance:_release_write_lock(token)
  if type(token) ~= "table" or token.released then return false end
  if not self.actions or self.actions.write ~= token then return false end
  token.released = true
  local ok, err = true, nil
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    ok, err = pcall(function() vim.bo[self.bufnr].modifiable = token.original_modifiable end)
  end
  self.actions.write = nil
  if next(self.actions) == nil then self.actions = nil end
  if not ok then self:_report_async_error(err) end
  self:_schedule_watch_followup()
  if not self._destroyed then self.manager:gc_reconsider(self, true) end
  return true
end

function Instance:_require_projection_change()
  if self._destroyed or self.state == "destroying" or self.state == "destroyed" then
    fail("instance is destroyed", 3)
  end
  require_ready(self)
  if self.actions and self.actions.write then fail("instance is write-locked", 3) end
  if self._refresh_request then fail("refresh is already in progress", 3) end
  if vim.bo[self.bufnr].modified then
    fail("buffer is modified; write or discard changes before changing the tree", 3)
  end
  self:_cancel_watch_refresh()
end

function Instance:_normalize_snapshot_path(snapshot_path)
  if type(snapshot_path) ~= "string" then fail("snapshot path must be a string", 3) end
  local windows = path.is_windows(self.root)
  local relative
  if path.is_absolute(snapshot_path) then
    local absolute = path.normalize(snapshot_path, { windows = windows })
    if not path.contains(self.root, absolute) then
      fail("path is outside the instance root: " .. snapshot_path, 3)
    end
    relative = assert(path.relative(self.root, absolute))
  else
    relative = path.normalize_relative(snapshot_path, { windows = windows })
    if relative == ".." or relative:sub(1, 3) == "../" then
      fail("snapshot path escapes the instance root: " .. snapshot_path, 3)
    end
  end
  return relative, path.resolve(self.root, relative)
end

function Instance:_cached_node(relative)
  local node = self.root_node
  for _, segment in ipairs(split_relative(relative)) do
    if node.kind ~= "directory" or node.load_state ~= "loaded" then return nil end
    node = self.tree:find_child(node, segment)
    if not node then return nil end
  end
  return node
end

function Instance:_directory_or_fail(node, relative)
  if not node then fail("snapshot path does not exist: " .. relative, 3) end
  if node.kind ~= "directory" then
    fail(relative .. " is a " .. tostring(node.kind) .. " and cannot be expanded", 3)
  end
  return node
end

function Instance:_active_directory(node)
  if node == self.root_node then return true end
  local current = node
  while current and current ~= self.root_node do
    if current.kind ~= "directory" or not current.expanded then return false end
    current = current.parent
  end
  return current == self.root_node
end

function Instance:_is_visible()
  if not vim.api.nvim_buf_is_valid(self.bufnr) then return false end
  for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == self.bufnr then
      return true
    end
  end
  return false
end

function Instance:_watch_specs()
  local specs = {
    { path = self.root_node.path, node_id = self.root_node.id,
      tree_generation = self._tree_generation },
  }
  local function visit(parent)
    for _, node in ipairs(parent.children_order or {}) do
      if node.kind == "directory" and node.expanded then
        specs[#specs + 1] = {
          path = node.path, node_id = node.id, tree_generation = self._tree_generation,
        }
        visit(node)
      end
    end
  end
  visit(self.root_node)
  return specs
end

function Instance:_sync_watchers(recreate_failed)
  if self._destroyed or (self.state ~= "ready-hidden" and self.state ~= "ready-visible") then
    return
  end
  self._watchers:sync(self:_watch_specs(), { recreate_failed = recreate_failed == true })
end

function Instance:_suspend_watchers_for_write(token)
  self:_require_write_capability(token)
  if path.is_windows(self.root) then self._watchers:suspend() end
end

function Instance:_next_watch_event_generation()
  self._watch_event_generation = self._watch_event_generation + 1
  return self._watch_event_generation
end

function Instance:_mark_watch_pending(generation)
  generation = generation or self:_next_watch_event_generation()
  self._watch_pending_generation = math.max(self._watch_pending_generation, generation)
  self.needs_refresh = true
end

function Instance:_schedule_watch_followup()
  if self._destroyed or not self.needs_refresh or self._watch_followup_scheduled then return end
  self._watch_followup_scheduled = true
  vim.schedule(function()
    if self._destroyed then return end
    self._watch_followup_scheduled = false
    if self.needs_refresh then self:_on_visibility_enter() end
  end)
end

function Instance:_watch_commit_safe(entry, request)
  if self._destroyed or self.state == "destroying" or self.state == "destroyed"
      or not vim.api.nvim_buf_is_valid(self.bufnr) then return false end
  if self.state ~= "ready-hidden" and self.state ~= "ready-visible" then return false end
  if not self._watchers:is_current(entry) then return false end
  local node = self.nodes_by_id[entry.node_id]
  if not node or node.path ~= entry.path or node.kind ~= "directory"
      or not node.loaded or not self:_active_directory(node) then return false end
  if not self:_is_visible() or vim.bo[self.bufnr].modified
      or (self.actions and self.actions.write) or self._refresh_request then return false end
  if self._execution and not mutation_execute.is_terminal(self._execution) then return false end
  if request then
    if self._watch_refresh_request ~= request then return false end
  elseif self._watch_refresh_request or self.needs_refresh then
    return false
  end
  for _, current in pairs(self.nodes_by_id) do
    if current.kind == "directory"
        and (current.load_state == "loading" or current.load_state == "refreshing") then
      return false
    end
  end
  return true
end

function Instance:_on_watch_error(entry, err)
  if self._destroyed or self._watchers.failed[entry.path] ~= entry then return end
  self:_mark_watch_pending()
  self:_report_async_error("watch failed for " .. entry.path .. ": " .. tostring(err))
end

function Instance:_on_watch_event(entry)
  if self._destroyed or not self._watchers:is_current(entry) then return end
  local generation = self:_next_watch_event_generation()
  if not self:_watch_commit_safe(entry) then
    self:_mark_watch_pending(generation)
    return
  end
  self:_start_watch_directory_refresh(entry, generation)
end

function Instance:_report_async_error(err)
  self._last_async_error = tostring(err)
  local ok, notify_err = pcall(
    vim.notify, "fre: " .. self._last_async_error, vim.log.levels.ERROR
  )
  if not ok then
    self._last_async_error = self._last_async_error
      .. "; error reporter failed: " .. tostring(notify_err)
  end
end

function Instance:_ensure_directory_loaded(node, callback)
  if node.loaded then callback(nil); return end
  node._load_waiters = node._load_waiters or {}
  node._load_waiters[#node._load_waiters + 1] = callback
  if node.load_state == "loading" then return end

  node.load_generation = node.load_generation + 1
  local generation = node.load_generation
  node.load_state = "loading"
  node.loaded = false
  node.children_cached = false
  local finished = false
  local function done(err, children, real_path)
    if finished then return end
    finished = true
    vim.schedule(function()
      if self._destroyed or self.nodes_by_id[node.id] ~= node
          or node.load_generation ~= generation or node.load_state ~= "loading" then
        return
      end
      if vim.bo[self.bufnr].modified or (self.actions and self.actions.write)
          or not self:_active_directory(node) then
        node._load_waiters = {}
        node.load_state = "unloaded"
        node.loaded = false
        node.children_cached = false
        return
      end
      local waiters = node._load_waiters or {}
      node._load_waiters = {}
      local tree_snapshot
      if not err then
        tree_snapshot = self.tree:snapshot_directory(node)
        local ok, value = pcall(function()
          local ordered = self.tree:reconcile(node, children or {}, function(a, b)
            return self.current_sort(self:_entry(node), self:_entry(a), self:_entry(b))
          end)
          if real_path then node.real_path = real_path end
          return ordered
        end)
        if not ok then err = value end
      end
      if not err then
        local ok, result = pcall(self._render_success, self)
        if not ok then
          err = result
        elseif result == false then
          err = "buffer projection commit failed"
        end
      end
      if err then
        if tree_snapshot then
          self.tree:restore_directory(node, tree_snapshot)
          self:_projection()
        end
        node.load_state = "unloaded"
        node.loaded = false
        node.children_cached = false
      else
        self:_sync_watchers()
      end
      for _, waiter in ipairs(waiters) do waiter(err) end
    end)
  end
  local ok, adapter_err = pcall(self.manager:get_fs_adapter().load, node.path, done)
  if not ok then done(adapter_err) end
end

function Instance:_rescan_directory(node)
  if not node.loaded or node.load_state == "refreshing" then return end
  node.load_generation = node.load_generation + 1
  local generation = node.load_generation
  node.load_state = "refreshing"
  local finished = false
  local function done(err, children, real_path)
    if finished then return end
    finished = true
    vim.schedule(function()
      if self._destroyed or self.nodes_by_id[node.id] ~= node
          or node.load_generation ~= generation or node.load_state ~= "refreshing" then
        return
      end
      if vim.bo[self.bufnr].modified or (self.actions and self.actions.write)
          or not self:_active_directory(node) then
        node.load_state = "loaded"
        node.loaded = true
        node.children_cached = true
        return
      end
      local tree_snapshot
      if not err then
        tree_snapshot = self.tree:snapshot_directory(node)
        local ok, value = pcall(function()
          local ordered = self.tree:reconcile(node, children or {}, function(a, b)
            return self.current_sort(self:_entry(node), self:_entry(a), self:_entry(b))
          end)
          if real_path then node.real_path = real_path end
          return ordered
        end)
        if not ok then err = value end
      end
      if err then
        if tree_snapshot then
          self.tree:restore_directory(node, tree_snapshot)
          self:_projection()
        end
        node.load_state = "loaded"
        node.loaded = true
        node.children_cached = true
        self:_report_async_error(err)
        return
      end
      local ok, render_err = pcall(self._render_success, self)
      if not ok then
        self.tree:restore_directory(node, tree_snapshot)
        self:_projection()
        node.load_state = "loaded"
        node.loaded = true
        node.children_cached = true
        self:_report_async_error(render_err)
      else
        self:_sync_watchers()
      end
    end)
  end
  local ok, adapter_err = pcall(self.manager:get_fs_adapter().load, node.path, done)
  if not ok then done(adapter_err) end
end

function Instance:_invalidate_subtree_loads(node)
  if node.kind ~= "directory" then return end
  if node.load_state == "loading" or node.load_state == "refreshing" then
    local preserved = node.loaded
    node.load_generation = node.load_generation + 1
    node._load_waiters = {}
    node.load_state = preserved and "loaded" or "unloaded"
    node.loaded = preserved
    node.children_cached = preserved
  end
  for _, child in ipairs(node.children_order or {}) do
    self:_invalidate_subtree_loads(child)
  end
end

function Instance:set_sort(sort_fn)
  if type(sort_fn) ~= "function" then fail("sort must be a function", 2) end
  self:_require_projection_change()
  self.current_sort = sort_fn
  return self:refresh()
end

function Instance:set_hidden_file(hidden_file)
  if type(hidden_file) ~= "boolean" then
    fail("hidden_file must be a boolean", 2)
  end
  self:_require_projection_change()
  if hidden_file == self.current_hidden_file then return nil end
  local previous = self.current_hidden_file
  local visibility = self:_snapshot_visibility()
  self.current_hidden_file = hidden_file
  local ok, result = pcall(self._render_success, self)
  if not ok or result == false then
    self.current_hidden_file = previous
    self:_restore_visibility(visibility)
    if not ok then error(result, 0) end
    fail("buffer projection commit failed", 2)
  end
  return nil
end

function Instance:toggle_hidden_file()
  return self:set_hidden_file(not self.current_hidden_file)
end

function Instance:_expand(snapshot_path, on_complete, initializing)
  if not initializing then self:_require_projection_change() end
  local relative = self:_normalize_snapshot_path(snapshot_path)
  if relative == "" then
    if on_complete then on_complete(nil) end
    return nil
  end
  local segments = split_relative(relative)
  local request = { active = true, synchronous = true }
  local function stop(expand_err)
    if not request.active then return end
    request.active = false
    if on_complete then
      on_complete(expand_err)
    elseif expand_err then
      if request.synchronous then fail(expand_err, 4) end
      self:_report_async_error(expand_err)
    end
  end
  local walk
  local function resume(parent, index)
    if request.synchronous then
      walk(parent, index)
      return
    end
    local ok, walk_err = pcall(walk, parent, index)
    if not ok then stop(walk_err) end
  end
  walk = function(parent, index)
    if not request.active then return end
    local child = self.tree:find_child(parent, segments[index])
    local prefix = table.concat(vim.list_slice(segments, 1, index), "/")
    if not child then
      stop("snapshot path does not exist: " .. prefix)
      return
    end
    if child.kind ~= "directory" then
      stop(prefix .. " is a " .. tostring(child.kind) .. " and cannot be expanded")
      return
    end
    local became_expanded = not child.expanded
    if became_expanded then
      child.expanded = true
      self:_render_success()
      self:_sync_watchers()
    end
    if child.loaded then
      if became_expanded then self:_rescan_directory(child) end
      if index == #segments then stop(nil) else resume(child, index + 1) end
    else
      self:_ensure_directory_loaded(child, function(load_err)
        if load_err then
          stop(load_err)
        elseif index == #segments then
          stop(nil)
        else
          resume(child, index + 1)
        end
      end)
    end
  end

  resume(self.root_node, 1)
  request.synchronous = false
  return nil
end

function Instance:expand(snapshot_path)
  return self:_expand(snapshot_path, nil, false)
end

function Instance:collapse(snapshot_path)
  self:_require_projection_change()
  local relative = self:_normalize_snapshot_path(snapshot_path)
  if relative == "" then fail("the instance root cannot be collapsed", 2) end
  local node = self:_directory_or_fail(self:_cached_node(relative), relative)
  node.expanded = false
  self:_invalidate_subtree_loads(node)
  self:_render_success()
  self:_sync_watchers()
  return nil
end

function Instance:toggle_expand(snapshot_path)
  self:_require_projection_change()
  local relative = self:_normalize_snapshot_path(snapshot_path)
  if relative == "" then fail("the instance root cannot be toggled", 2) end
  local node = self:_directory_or_fail(self:_cached_node(relative), relative)
  if node.expanded then return self:collapse(relative) end
  return self:expand(relative)
end

function Instance:get_entry(row)
  require_ready(self)
  local decoded = buffer.decode(self, row)
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
  local node = self.nodes_by_path[absolute]
  if not node or not self.view or not self.view.baseline or self.view.baseline[node.id] == nil then
    return nil
  end
  local hint = buffer.hint_row(self, node)
  if hint and buffer.row_matches_identity(self, hint, self.id, node.id) then
    local decoded = buffer.decode(self, hint)
    return { hint, decoded.path_range.start_byte }
  end
  local matches = buffer.find_identity_rows(self, self.id, node.id)
  if #matches == 0 then
    return nil
  end
  local row = matches[1]
  buffer.rebind(self, node, row)
  local decoded = buffer.decode(self, row)
  return { row, decoded.path_range.start_byte }
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
  if self.state == "ready-hidden" or self.state == "ready-visible" then
    place()
  elseif self.state == "creating" then
    self:when_ready(function(ready_err)
      if ready_err == nil then place() end
    end)
  else
    require_ready(self)
  end
  return self
end

function Instance:_apply_pending_reveal(winid)
  local request = self._pending_reveal
  if not request or request.generation ~= self._reveal_generation or self._destroyed then
    return false
  end
  local position = self:get_pos(request.relative)
  winid = winid or window.select(self)
  if not position or not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_tabpage(winid) ~= request.tabpage
      or vim.api.nvim_win_get_buf(winid) ~= self.bufnr then return false end
  vim.api.nvim_win_set_cursor(winid, position)
  if self._pending_reveal == request then self._pending_reveal = nil end
  return true
end

function Instance:reveal(snapshot_path)
  if self._destroyed or self.state == "destroying" or self.state == "destroyed" then
    fail("instance is destroyed", 2)
  end
  require_ready(self)
  local relative, absolute = self:_normalize_snapshot_path(snapshot_path)
  if relative == "" then fail("the instance root has no revealable row", 2) end
  local segments = split_relative(relative)
  if not self.current_hidden_file then
    for _, segment in ipairs(segments) do
      if segment:sub(1, 1) == "." then
        fail("path is hidden; enable hidden files explicitly before reveal: " .. relative, 2)
      end
    end
  end

  local position = self:get_pos(relative)
  if not position then self:_require_projection_change() end

  self._reveal_generation = self._reveal_generation + 1
  local request = {
    generation = self._reveal_generation,
    tabpage = vim.api.nvim_get_current_tabpage(),
    relative = relative,
    absolute = absolute,
    active = true,
    synchronous = true,
  }
  self._pending_reveal = request

  local function current()
    return request.active and not self._destroyed
      and request.generation == self._reveal_generation
  end
  local function stop(err)
    if not current() then return end
    request.active = false
    if err then
      if self._pending_reveal == request then self._pending_reveal = nil end
      if request.synchronous then fail(err, 4) end
      self:_report_async_error(err)
      return
    end
    self:_apply_pending_reveal()
  end
  local function finish(parent)
    if not current() then return end
    local target = self.tree:find_child(parent, segments[#segments])
    if not target or self.nodes_by_path[target.path] ~= target then
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
    if not child.expanded then
      child.expanded = true
      local ok, err = pcall(self._render_success, self)
      if not ok then
        child.expanded = false
        self:_projection()
        stop(err)
        return
      end
      self:_sync_watchers()
    end
    if child.loaded then
      walk(child, index + 1)
    else
      self:_ensure_directory_loaded(child, function(err)
        if not current() then return end
        if err then stop(err); return end
        walk(child, index + 1)
      end)
    end
  end

  if position then
    stop(nil)
  else
    walk(self.root_node, 1)
  end
  request.synchronous = false
  return nil
end

local function schedule_refresh_completion(instance, callback, err)
  vim.schedule(function()
    if callback then
      local ok, callback_err = pcall(callback, err)
      if not ok and not instance._destroyed then instance:_report_async_error(callback_err) end
    elseif err ~= nil and not instance._destroyed then
      instance:_report_async_error(err)
    end
  end)
end

function Instance:_finish_refresh_request(request, err)
  if request.completed then return end
  request.completed = true
  if self._refresh_request == request then self._refresh_request = nil end
  schedule_refresh_completion(self, request.on_complete, err)
end

function Instance:_finish_initial_refresh(request, err)
  if request.completed then return end
  request.completed = true
  if self._initial_refresh_request == request then self._initial_refresh_request = nil end
  self.needs_refresh = err ~= nil
  schedule_refresh_completion(self, request.on_complete, err)
end

function Instance:_active_expanded_paths()
  local paths = {}
  local function visit(parent)
    for _, node in ipairs(parent.children_order or {}) do
      if node.kind == "directory" and node.expanded then
        paths[#paths + 1] = node.path
        if node.children_cached then visit(node) end
      end
    end
  end
  visit(self.root_node)
  return paths
end

function Instance:_new_refresh_candidate()
  local candidate = setmetatable({
    manager = self.manager,
    id = self.id,
    bufnr = self.bufnr,
    root = self.root,
    config = self.config,
    current_sort = self.current_sort,
    current_hidden_file = self.current_hidden_file,
    _next_node_id = self._next_node_id,
    nodes_by_id = {},
    nodes_by_path = {},
    view = nil,
    real_root = self.real_root,
  }, Instance)
  candidate.tree = Tree.clone(self.tree, candidate)
  return candidate
end

function Instance:_cancel_watch_refresh()
  local request = self._watch_refresh_request
  if not request then return false end
  request.completed = true
  self._watch_refresh_request = nil
  self._watch_refresh_generation = self._watch_refresh_generation + 1
  self:_mark_watch_pending()
  return true
end

function Instance:_finish_watch_refresh(request, err)
  if request.completed then return end
  request.completed = true
  if self._watch_refresh_request == request then self._watch_refresh_request = nil end
  if err ~= nil then
    self:_mark_watch_pending()
    self:_report_async_error("watch refresh failed for " .. request.path .. ": " .. tostring(err))
  end
end

function Instance:_commit_watch_refresh(request, candidate, prepared)
  if request.completed or self._watch_refresh_request ~= request
      or self._watch_refresh_generation ~= request.generation
      or request.tree_generation ~= self._tree_generation
      or not self:_watch_commit_safe(request.entry, request) then
    self:_cancel_watch_refresh()
    return
  end
  if vim.api.nvim_buf_get_changedtick(self.bufnr) ~= request.changedtick
      or vim.bo[self.bufnr].modified ~= request.modified then
    self:_finish_watch_refresh(request, "buffer changed during directory refresh")
    return
  end

  local buffer_snapshot = buffer.snapshot(self)
  local old = {
    tree = self.tree, root_node = self.root_node, nodes_by_id = self.nodes_by_id,
    nodes_by_path = self.nodes_by_path, next_node_id = self._next_node_id,
    real_root = self.real_root, result = self.result, error = self.error, view = self.view,
  }
  self.tree = candidate.tree
  self.tree.instance = self
  self.root_node = candidate.root_node
  self.nodes_by_id = candidate.nodes_by_id
  self.nodes_by_path = candidate.nodes_by_path
  self._next_node_id = candidate._next_node_id
  self.real_root = candidate.real_root
  self.result = self:_refresh_result(candidate)
  self.error = nil

  local ok, commit_result = pcall(buffer.commit, self, prepared)
  if not ok or commit_result == false then
    local commit_err = ok and "buffer projection commit failed" or commit_result
    self.tree = old.tree
    self.root_node = old.root_node
    self.nodes_by_id = old.nodes_by_id
    self.nodes_by_path = old.nodes_by_path
    self._next_node_id = old.next_node_id
    self.real_root = old.real_root
    self.result = old.result
    self.error = old.error
    self.view = old.view
    candidate.tree.instance = candidate
    local restore_ok, restore_err = pcall(buffer.restore, self, buffer_snapshot)
    if not restore_ok then
      commit_err = tostring(commit_err) .. "; rollback failed: " .. tostring(restore_err)
    end
    self:_finish_watch_refresh(request, commit_err)
    return
  end

  for _, node in pairs(old.nodes_by_id) do node.row_extmark = nil end
  request.completed = true
  if self._watch_refresh_request == request then self._watch_refresh_request = nil end
  self._tree_generation = self._tree_generation + 1
  self.needs_refresh = request.had_pending
    or self._watch_event_generation > request.watch_event_generation
  self:_sync_watchers(false)
  if self.needs_refresh then self:_schedule_watch_followup() end
end

function Instance:_start_watch_directory_refresh(entry, event_generation)
  self._watch_refresh_generation = self._watch_refresh_generation + 1
  local request = {
    generation = self._watch_refresh_generation,
    tree_generation = self._tree_generation,
    entry = entry,
    path = entry.path,
    node_id = entry.node_id,
    changedtick = vim.api.nvim_buf_get_changedtick(self.bufnr),
    modified = vim.bo[self.bufnr].modified,
    pending_generation = self._watch_pending_generation,
    had_pending = self.needs_refresh,
    watch_event_generation = event_generation,
    completed = false,
  }
  self._watch_refresh_request = request
  self.needs_refresh = true

  local candidate_ok, candidate = pcall(self._new_refresh_candidate, self)
  if not candidate_ok then self:_finish_watch_refresh(request, candidate); return end
  local node = candidate.nodes_by_id[request.node_id]
  if not node or node.path ~= request.path or node.kind ~= "directory"
      or not candidate:_active_directory(node) then
    self:_finish_watch_refresh(request, "watched directory is no longer active")
    return
  end
  node.load_generation = (node.load_generation or 0) + 1
  local load_generation = node.load_generation
  node.load_state = "refreshing"
  local finished = false
  local function done(err, children, real_path)
    if finished then return end
    finished = true
    vim.schedule(function()
      if request.completed or self._watch_refresh_request ~= request
          or self._watch_refresh_generation ~= request.generation then return end
      if not self:_watch_commit_safe(entry, request) then
        self:_cancel_watch_refresh()
        return
      end
      if candidate.nodes_by_id[request.node_id] ~= node
          or node.load_generation ~= load_generation then
        self:_finish_watch_refresh(request, "directory generation was superseded")
        return
      end
      if err ~= nil then self:_finish_watch_refresh(request, err); return end
      local reconcile_ok, reconcile_err = pcall(function()
        candidate.tree:reconcile(node, children or {}, function(a, b)
          return candidate.current_sort(
            candidate:_entry(node), candidate:_entry(a), candidate:_entry(b)
          )
        end)
        if real_path then node.real_path = real_path end
      end)
      if not reconcile_ok then self:_finish_watch_refresh(request, reconcile_err); return end
      local prepared_ok, prepared = pcall(candidate._prepare_projection, candidate, true)
      if not prepared_ok then self:_finish_watch_refresh(request, prepared); return end
      self:_commit_watch_refresh(request, candidate, prepared)
    end)
  end
  local adapter_ok, adapter_err = pcall(
    self.manager:get_fs_adapter().load, request.path, done
  )
  if not adapter_ok then done(adapter_err) end
end

function Instance:_refresh_result(candidate)
  local children = {}
  for _, node in ipairs(candidate.root_node.children_order or {}) do
    children[#children + 1] = {
      id = node.id, name = node.name, path = node.path, kind = node.kind,
    }
  end
  return { children = children, root = self.root }
end

function Instance:_sort_candidate_cache()
  local function visit(parent)
    if parent.loaded then
      table.sort(parent.children_order, function(a, b)
        return self.current_sort(self:_entry(parent), self:_entry(a), self:_entry(b))
      end)
    end
    for _, child in ipairs(parent.children_order or {}) do
      if child.kind == "directory" and child.children_cached then visit(child) end
    end
  end
  visit(self.root_node)
end

function Instance:_commit_refresh_candidate(request, candidate, prepared)
  if self._destroyed or self._refresh_request ~= request
      or self._refresh_generation ~= request.generation then
    self:_finish_refresh_request(request, "refresh was superseded")
    return
  end
  if request.write_token ~= nil then
    if not self.actions or self.actions.write ~= request.write_token
        or request.write_token.released then
      self:_finish_refresh_request(request, "write reconciliation lost its capability")
      return
    end
  elseif self.actions and self.actions.write then
    self:_finish_refresh_request(request, "instance became write-locked during refresh")
    return
  end
  if vim.api.nvim_buf_get_changedtick(self.bufnr) ~= request.changedtick
      or vim.bo[self.bufnr].modified ~= request.modified then
    self:_finish_refresh_request(request, "buffer changed during refresh")
    return
  end

  local buffer_snapshot = buffer.snapshot(self)
  local old = {
    tree = self.tree, root_node = self.root_node,
    nodes_by_id = self.nodes_by_id, nodes_by_path = self.nodes_by_path,
    next_node_id = self._next_node_id, real_root = self.real_root,
    result = self.result, error = self.error, view = self.view,
  }
  self.tree = candidate.tree
  self.tree.instance = self
  self.root_node = candidate.root_node
  self.nodes_by_id = candidate.nodes_by_id
  self.nodes_by_path = candidate.nodes_by_path
  self._next_node_id = candidate._next_node_id
  self.real_root = candidate.real_root
  self.result = self:_refresh_result(candidate)
  self.error = nil

  local ok, commit_result = pcall(buffer.commit, self, prepared)
  if not ok or commit_result == false then
    local commit_err = ok and "buffer projection commit failed" or commit_result
    self.tree = old.tree
    self.root_node = old.root_node
    self.nodes_by_id = old.nodes_by_id
    self.nodes_by_path = old.nodes_by_path
    self._next_node_id = old.next_node_id
    self.real_root = old.real_root
    self.result = old.result
    self.error = old.error
    self.view = old.view
    candidate.tree.instance = candidate
    local restore_ok, restore_err = pcall(buffer.restore, self, buffer_snapshot)
    if not restore_ok then
      commit_err = tostring(commit_err) .. "; rollback failed: " .. tostring(restore_err)
    end
    self.needs_refresh = true
    self:_finish_refresh_request(request, commit_err)
    return
  end

  for _, node in pairs(old.nodes_by_id) do node.row_extmark = nil end
  local followup = self._watch_event_generation > request.watch_event_generation
  self.needs_refresh = followup
  self._tree_generation = self._tree_generation + 1
  self:_sync_watchers(true)
  self:_finish_refresh_request(request, nil)
  if followup then self:_schedule_watch_followup() end
end

function Instance:_start_atomic_refresh(force, on_complete, write_token)
  self._refresh_generation = self._refresh_generation + 1
  local request = {
    generation = self._refresh_generation,
    force = force,
    on_complete = on_complete,
    changedtick = vim.api.nvim_buf_get_changedtick(self.bufnr),
    modified = vim.bo[self.bufnr].modified,
    completed = false,
    active_paths = self:_active_expanded_paths(),
    write_token = write_token,
    watch_event_generation = self._watch_event_generation,
  }
  self._refresh_request = request
  self.needs_refresh = true

  local candidate_ok, candidate = pcall(self._new_refresh_candidate, self)
  if not candidate_ok then
    self:_finish_refresh_request(request, candidate)
    return
  end
  request.candidate = candidate

  local function current()
    local capability_current = request.write_token == nil
      or (self.actions and self.actions.write == request.write_token
        and not request.write_token.released)
    return not request.completed and not self._destroyed
      and self._refresh_request == request
      and self._refresh_generation == request.generation
      and capability_current
  end
  local function finish_error(err)
    self.needs_refresh = true
    self:_finish_refresh_request(request, err)
  end
  local function reconcile(node, children, real_path)
    candidate.tree:reconcile(node, children or {}, function(a, b)
      return candidate.current_sort(
        candidate:_entry(node), candidate:_entry(a), candidate:_entry(b)
      )
    end)
    if real_path then node.real_path = real_path end
  end

  local scan
  scan = function(index)
    if not current() then
      if not request.completed then finish_error("refresh was superseded") end
      return
    end
    local scan_path = index == 0 and candidate.root or request.active_paths[index]
    if not scan_path then
      local sort_ok, sort_err = pcall(candidate._sort_candidate_cache, candidate)
      if not sort_ok then finish_error(sort_err); return end
      local prepared_ok, prepared = pcall(candidate._prepare_projection, candidate, true)
      if not prepared_ok then finish_error(prepared); return end
      self:_commit_refresh_candidate(request, candidate, prepared)
      return
    end

    local node = index == 0 and candidate.root_node or candidate.nodes_by_path[scan_path]
    if index > 0 and (not node or node.kind ~= "directory"
        or not candidate:_active_directory(node)) then
      scan(index + 1)
      return
    end
    node.load_generation = (node.load_generation or 0) + 1
    local load_generation = node.load_generation
    node.load_state = "refreshing"
    local finished = false
    local function done(err, children, real_path)
      if finished then return end
      finished = true
      vim.schedule(function()
        if not current() then
          if not request.completed then finish_error("refresh was superseded") end
          return
        end
        if candidate.nodes_by_path[scan_path] ~= node
            or node.load_generation ~= load_generation then
          finish_error("refresh directory generation was superseded")
          return
        end
        if err ~= nil then finish_error(err); return end
        local reconcile_ok, reconcile_err = pcall(reconcile, node, children, real_path)
        if not reconcile_ok then finish_error(reconcile_err); return end
        if index == 0 and real_path then candidate.real_root = real_path end
        scan(index + 1)
      end)
    end
    local adapter_ok, adapter_err = pcall(
      self.manager:get_fs_adapter().load, scan_path, done
    )
    if not adapter_ok then done(adapter_err) end
  end
  scan(0)
end

function Instance:_reconcile_write(token, on_complete)
  self:_require_write_capability(token)
  if type(on_complete) ~= "function" then fail("reconciliation callback must be a function", 3) end
  if self._refresh_request then fail("refresh is already in progress", 3) end
  self:_start_atomic_refresh(true, on_complete, token)
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

  if self._destroyed or self.state == "destroying" or self.state == "destroyed" then
    fail("instance is destroyed", 2)
  end
  if self.state == "creating" then fail("instance is still loading", 2) end
  if self.actions and self.actions.write then fail("instance is write-locked", 2) end
  if self._refresh_request then fail("refresh is already in progress", 2) end

  if self.state == "load-failed" then
    self.needs_refresh = true
    self:_cancel_pending_callbacks()
    local request = { on_complete = opts.on_complete, completed = false }
    self._initial_refresh_request = request
    self:_start_load(true, function(err)
      self:_finish_initial_refresh(request, err)
    end)
    return nil
  end
  if self.state ~= "ready-hidden" and self.state ~= "ready-visible" then
    fail("instance is not ready", 2)
  end
  for _, node in pairs(self.nodes_by_id) do
    if node.kind == "directory"
        and (node.load_state == "loading" or node.load_state == "refreshing") then
      fail("a directory load is already in progress", 2)
    end
  end
  if vim.bo[self.bufnr].modified and not force then
    fail("buffer is modified; pass force = true to discard changes", 2)
  end
  self:_cancel_watch_refresh()

  self:_start_atomic_refresh(force, opts.on_complete)
  return nil
end

function Instance:_on_visibility_enter()
  if self._destroyed then return end
  if not self.manager:gc_visibility_changed(self) then return end
  if self.state == "ready-hidden" then self.state = "ready-visible" end
  if self.state ~= "ready-visible" or not self.needs_refresh
      or self._pending_visibility_refresh or self._refresh_request
      or self._watch_refresh_request or vim.bo[self.bufnr].modified
      or (self.actions and self.actions.write) then return end
  if self._execution and not mutation_execute.is_terminal(self._execution) then return end
  for _, node in pairs(self.nodes_by_id) do
    if node.kind == "directory"
        and (node.load_state == "loading" or node.load_state == "refreshing") then return end
  end
  self._pending_visibility_refresh = true
  local ok, err = pcall(self.refresh, self, { on_complete = function(refresh_err)
    if self._destroyed then return end
    self._pending_visibility_refresh = false
    if refresh_err ~= nil then
      self.needs_refresh = true
      self:_report_async_error(refresh_err)
    end
  end })
  if not ok then
    self._pending_visibility_refresh = false
    self.needs_refresh = true
    self:_report_async_error(err)
  end
end

function Instance:open(layout)
  if self._destroyed then fail("instance is destroyed", 2) end
  local winid = window.open(self, layout)
  if self._pending_reveal then self:_apply_pending_reveal(winid) end
  self:_on_visibility_enter()
  return self, winid
end

function Instance:hidden()
  if self._destroyed then fail("instance is destroyed", 2) end
  return window.hidden(self)
end

function Instance:toggle(layout)
  if self._destroyed then fail("instance is destroyed", 2) end
  local result = window.toggle(self, layout)
  if type(result) == "number" then
    if self._pending_reveal then self:_apply_pending_reveal(result) end
    self:_on_visibility_enter()
    return self
  end
  return result
end

function Instance:prepare()
  if self._destroyed then fail("instance is destroyed", 2) end
  if self.actions and self.actions.write then fail("instance is write-locked", 2) end
  return mutation_prepare.prepare(self)
end

function Instance:_prepare_write(token)
  self:_require_write_capability(token)
  return mutation_prepare.prepare(self)
end

function Instance:_start_execution(plan, handlers)
  if self._execution and not mutation_execute.is_terminal(self._execution) then
    fail("an execution is already in progress", 3)
  end
  self:_cancel_watch_refresh()
  local execution
  execution = mutation_execute.start(
    self, plan, handlers, self.manager:get_mutation_adapter(), function(completed)
      if self._execution == completed then self._execution = nil end
      if not self._destroyed then self.manager:gc_reconsider(self, true) end
    end
  )
  self._execution = execution
  self.manager:gc_reconsider(self, false)
  return execution
end

function Instance:execute(plan, handlers)
  if self._destroyed or self.state == "destroying" or self.state == "destroyed" then
    fail("instance is destroyed", 2)
  end
  if self.actions and self.actions.write then fail("instance is write-locked", 2) end
  return self:_start_execution(plan, handlers)
end

function Instance:_execute_write(token, plan, handlers)
  self:_require_write_capability(token)
  self:_suspend_watchers_for_write(token)
  local ok, execution = pcall(self._start_execution, self, plan, handlers)
  if not ok then
    self:_sync_watchers(false)
    error(execution, 0)
  end
  return execution
end

function Instance:_start_destroy()
  local manager = self.manager
  self.state = "destroying"
  self._destroyed = true
  manager:get_gc_controller():stop(self)

  self._attempt = self._attempt + 1
  self._refresh_generation = self._refresh_generation + 1
  self._watch_refresh_generation = self._watch_refresh_generation + 1
  self._watch_event_generation = self._watch_event_generation + 1
  self._tree_generation = self._tree_generation + 1
  self._reveal_generation = self._reveal_generation + 1
  if self._pending_reveal then self._pending_reveal.active = false end
  self._pending_reveal = nil
  self._pending_initial_cursor = {}
  self._pending_visibility_refresh = false

  local ready_callbacks = self._ready_callbacks
  self._ready_callbacks = {}
  for _, callback in ipairs(ready_callbacks) do
    self:_schedule_callback(callback, "instance was destroyed before becoming ready")
  end
  if self._refresh_request then
    self:_finish_refresh_request(self._refresh_request, "instance was destroyed during refresh")
  end
  if self._initial_refresh_request then
    self:_finish_initial_refresh(
      self._initial_refresh_request, "instance was destroyed during refresh"
    )
  end
  if self._watch_refresh_request then self._watch_refresh_request.completed = true end
  self._watch_refresh_request = nil
  for _, node in pairs(self.nodes_by_id or {}) do
    if node.kind == "directory" then
      node.load_generation = (node.load_generation or 0) + 1
      node._load_waiters = {}
    end
  end

  if self._watchers then pcall(self._watchers.stop_all, self._watchers) end
  pcall(mapping.teardown, self)
end

function Instance:_finish_destroy()
  local manager = self.manager
  local bufnr = self.bufnr
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

  pcall(buffer.teardown, self)
  manager:remove(self)
  local retained = { id = true, root = true, bufnr = true, state = true, _destroyed = true }
  for key in pairs(self) do
    if not retained[key] then self[key] = nil end
  end
  self.state = "destroyed"
  return nil
end

function Instance:destroy()
  if self.state ~= "destroying" and self.state ~= "destroyed" then
    if self.actions and self.actions.write then fail("instance is write-locked", 2) end
    if self._execution and not mutation_execute.is_terminal(self._execution) then
      fail("cannot destroy an instance with an active execution", 2)
    end
  end
  if self.state == "destroying" then return self:_finish_destroy() end
  if self._destroyed or self.state == "destroyed" then
    fail("instance is destroyed", 2)
  end
  self:_start_destroy()
  return self:_finish_destroy()
end

local function invalidate_failed_constructor(self)
  self._destroyed = true
  for _, field in ipairs({
    "_attempt", "_refresh_generation", "_watch_refresh_generation",
    "_watch_event_generation", "_tree_generation", "_reveal_generation",
  }) do
    if type(self[field]) == "number" then self[field] = self[field] + 1 end
  end
  if self.root_node and type(self.root_node.load_generation) == "number" then
    self.root_node.load_generation = self.root_node.load_generation + 1
  end
  if self._pending_reveal then self._pending_reveal.active = false end
  self._pending_initial_cursor = {}
  for _, callback in ipairs(self._ready_callbacks or {}) do callback.active = false end
  self._ready_callbacks = {}
end

local function remove_failed_indexes(manager, self)
  pcall(manager.remove, manager, self)
  if manager.instances_by_id and manager.instances_by_id[self.id] == self then
    manager.instances_by_id[self.id] = nil
  end
  for bufnr, indexed in pairs(manager.instances_by_buf or {}) do
    if indexed == self then manager.instances_by_buf[bufnr] = nil end
  end
  for _, group in pairs(manager.groups or {}) do
    if group.instances and group.instances[self.id] == self then
      group.instances[self.id] = nil
    end
  end
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

local function cleanup_failed_constructor(manager, self, bufnr)
  if self._constructor_cleanup_done then return true end
  self._constructor_cleanup_done = true
  invalidate_failed_constructor(self)

  local gc_ok, gc_controller = pcall(manager.get_gc_controller, manager)
  if not gc_ok then gc_controller = manager._gc end
  if gc_controller then pcall(gc_controller.stop, gc_controller, self) end
  if self._watchers then pcall(self._watchers.stop_all, self._watchers) end
  pcall(buffer.teardown, self)
  if self._buffer_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self._buffer_augroup)
    self._buffer_augroup = nil
  end
  pcall(mapping.teardown, self)
  for _, item in ipairs(self._installed_mappings or {}) do
    pcall(vim.keymap.del, item.mode, item.lhs, { buffer = bufnr })
  end
  self._installed_mappings = nil
  self._mapping_installed = nil
  remove_failed_indexes(manager, self)
  return wipe_failed_buffer(bufnr)
end

function Instance.new(manager, root, effective)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local self = setmetatable({
    manager = manager,
    bufnr = bufnr,
    _destroyed = false,
  }, Instance)

  local ok, result = xpcall(function()
    self.id = manager:allocate_id()
    self.root = root
    self.config = copy(effective)
    self.state = "creating"
    self.error = nil
    self.result = nil
    self.real_root = nil
    self.current_sort = effective.sort
    self.current_hidden_file = effective.hidden_file
    self._attempt = 0
    self._attempt_done = {}
    self._ready_callbacks = {}
    self._refresh_generation = 0
    self._refresh_request = nil
    self._initial_refresh_request = nil
    self._watch_refresh_generation = 0
    self._watch_refresh_request = nil
    self._watch_pending_generation = 0
    self._watch_event_generation = 0
    self._watch_followup_scheduled = false
    self._tree_generation = 0
    self._pending_visibility_refresh = false
    self._execution = nil
    self._reveal_generation = 0
    self._pending_reveal = nil
    self._marker_width_stale = false
    self._pending_initial_cursor = {}
    self._last_layout_by_tab = {}
    self._next_node_id = 1
    self.nodes_by_id = {}
    self.nodes_by_path = {}
    self.view = { baseline = {}, marker_generation = 0 }
    self.needs_refresh = false

    vim.api.nvim_buf_set_name(bufnr, "fre://" .. tostring(self.id))
    for key, value in pairs(required_options) do
      vim.bo[bufnr][key] = value
    end
    for key, value in pairs(self.config.buffer.options or {}) do
      vim.bo[bufnr][key] = value
    end
    vim.bo[bufnr].filetype = "fre"
    vim.bo[bufnr].syntax = "fre"
    vim.b[bufnr].fre = {
      version = 1,
      instance_id = self.id,
      root = self.root,
      gc_group = self.config.gc.group,
    }
    for key, value in pairs(self.config.buffer.variables or {}) do
      if key ~= "fre" then vim.b[bufnr][key] = copy(value) end
    end

    self.tree = Tree.new(self, root)
    self._watchers = Watch.new(self, manager:get_watch_adapter())
    buffer.setup(self)
    mapping.setup(self)
    self:_set_lines({ self:_loading_line() })
    manager:register(self)
    self:_start_load(true)
    return self
  end, function(err) return err end)

  if ok then return result end
  local cleaned, cleanup_err = cleanup_failed_constructor(manager, self, bufnr)
  if not cleaned then
    error(tostring(result) .. "; cleanup failed: instance buffer " .. tostring(bufnr)
      .. " survived: " .. tostring(cleanup_err), 0)
  end
  error(result, 0)
end

return Instance
