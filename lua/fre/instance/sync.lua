local path = require("fre.path")
local Watch = require("fre.instance.watch")
local Tree = require("fre.instance.tree")

local Sync = {}
Sync.__index = Sync

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function split_relative(relative)
  local result = {}
  for segment in relative:gmatch("[^/]+") do result[#result + 1] = segment end
  return result
end

function Sync.new(options)
  if type(options) ~= "table" then fail("sync options are required", 2) end
  local self = setmetatable({
    root = assert(options.root),
    tree = assert(options.tree),
    buffer = assert(options.buffer),
    config = assert(options.config),
    load = assert(options.load),
    schedule = assert(options.schedule),
    bufnr = assert(options.bufnr),
    is_alive = assert(options.is_alive),
    is_modified = assert(options.is_modified),
    is_write_locked = assert(options.is_write_locked),
    is_ready = assert(options.is_ready),
    is_execution_active = assert(options.is_execution_active),
    is_presented = assert(options.is_presented),
    on_initial_complete = assert(options.on_initial_complete),
    on_followup_needed = assert(options.on_followup_needed),
    report_error = assert(options.report_error),
    tree_generation = 0,
    real_root = nil,
    result = nil,
    dirty = false,
    load_requests = {},
    refresh_generation = 0,
    refresh_request = nil,
    initial_refresh_request = nil,
    watch_refresh_generation = 0,
    watch_refresh_request = nil,
    watch_pending_generation = 0,
    watch_event_generation = 0,
    watch_followup_scheduled = false,
  }, Sync)
  self.watch = Watch.new({
    adapter = assert(options.watch_adapter),
    on_error = function(event, err) self:_on_watch_error(event, err) end,
    on_event = function(event) self:_on_watch_event(event) end,
  })
  self.on_changed = function() if self.is_ready() then self:sync_watchers() end end
  return self
end

function Sync:normalize_snapshot_path(snapshot_path)
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

function Sync:_cached_node(relative)
  local node = self.tree:root_node()
  for _, segment in ipairs(split_relative(relative)) do
    if node.kind ~= "directory" or node.load_state ~= "loaded" then return nil end
    node = self.tree:find_child(node, segment)
    if not node then return nil end
  end
  return node
end

function Sync:_directory_or_fail(node, relative)
  if not node then fail("snapshot path does not exist: " .. relative, 3) end
  if node.kind ~= "directory" then
    fail(relative .. " is a " .. tostring(node.kind) .. " and cannot be expanded", 3)
  end
  return node
end

function Sync:_commit_tree_candidate(candidate)
  local ok, prepared = pcall(self.buffer.prepare_projection, self.buffer, false, candidate)
  if not ok then return nil, prepared end
  local commit_ok, result = pcall(self.buffer.commit, self.buffer, prepared)
  if not commit_ok then return nil, result end
  if result == false then return nil, "buffer projection commit failed" end
  self.tree:adopt(candidate)
  self.on_changed()
  return true
end

function Sync:_load_directory(node, mode, callback)
  node = self.tree:node_by_id(node.id)
  if mode == "loading" and node.loaded then callback(nil); return end
  local node_id = node.id
  local request = self.load_requests[node_id]
  if request and node.load_generation == request.generation and node.load_state == request.mode then
    request.waiters[#request.waiters + 1] = callback
    return
  end
  if request then self.load_requests[node_id] = nil end
  local generation = self.tree:begin_load(node, mode)
  request = { generation = generation, mode = mode, waiters = { callback } }
  self.load_requests[node_id] = request
  local load_path = node.path
  local finished = false
  local function done(err, children, real_path)
    if finished then return end
    finished = true
    self.schedule(function()
      local current = self.tree:node_by_id(node_id)
      if not self.is_alive() or self.load_requests[node_id] ~= request
          or not current or not self.tree:is_current_load(current, generation, mode) then
        if self.load_requests[node_id] == request then self.load_requests[node_id] = nil end
        return
      end
      if self.is_modified() or self.is_write_locked()
          or not self.tree:is_active_directory(current) then
        self.load_requests[node_id] = nil
        if mode == "loading" then self.tree:mark_unloaded(current)
        else self.tree:mark_loaded(current) end
        return
      end
      self.load_requests[node_id] = nil
      local waiters = request.waiters
      if not err then
        local candidate = Tree.clone(self.tree)
        local candidate_node = candidate:node_by_id(node_id)
        local reconcile_ok, reconcile_err = pcall(function()
          candidate:reconcile(candidate_node, children or {})
          if real_path then candidate_node.real_path = real_path end
        end)
        if not reconcile_ok then
          err = reconcile_err
        else
          local committed, commit_err = self:_commit_tree_candidate(candidate)
          if not committed then err = commit_err end
        end
      end
      if err then
        current = self.tree:node_by_id(node_id)
        if current then
          if mode == "loading" then self.tree:mark_unloaded(current)
          else self.tree:mark_loaded(current) end
        end
      end
      if self.dirty then self:_schedule_followup() end
      for _, waiter in ipairs(waiters) do waiter(err) end
    end)
  end
  local ok, adapter_err = pcall(self.load, load_path, done)
  if not ok then done(adapter_err) end
end

function Sync:ensure_loaded(node, callback, opts)
  self:_load_directory(node, "loading", callback, opts)
end

function Sync:rescan(node, callback)
  if not node.loaded then return end
  self:_load_directory(node, "refreshing", callback or function(err)
    if err then self.report_error(err) end
  end)
end

function Sync:_apply_configured_expansions(on_complete)
  local completed = false
  local function finish(err)
    if completed then return end
    completed = true
    on_complete(err)
  end
  local function apply(index)
    local relative = self.config.expanded[index]
    if relative == nil then finish(nil); return end
    local ok, err = pcall(self.expand, self, relative, function(expand_err)
      if expand_err ~= nil then
        finish("initial expansion failed for " .. relative .. ": " .. tostring(expand_err))
      else
        apply(index + 1)
      end
    end, true)
    if not ok then finish("initial expansion failed for " .. relative .. ": " .. tostring(err)) end
  end
  apply(1)
end

function Sync:_finish_initial(generation, err, children, real_root, on_complete)
  if not self.is_alive() or self.tree:root_node().load_generation ~= generation then return end
  local value
  if err == nil then
    local ok, result = pcall(function()
      local candidate = Tree.clone(self.tree)
      local ordered = candidate:reconcile(candidate:root_node(), children or {})
      local snapshot = {}
      for _, node in ipairs(ordered) do
        snapshot[#snapshot + 1] = {
          id = node.id, name = node.name, path = node.path, kind = node.kind,
        }
      end
      local committed, commit_err = self:_commit_tree_candidate(candidate)
      if not committed then error(commit_err, 0) end
      return { children = snapshot, root = self.root }
    end)
    if ok then value = result else err = result end
  end
  if err == nil then
    self:_apply_configured_expansions(function(expand_err)
      if expand_err ~= nil then
        self.dirty = true
        self.result = nil
        self.on_initial_complete(expand_err, nil, nil, on_complete)
      else
        self.real_root = real_root
        self.tree_generation = self.tree_generation + 1
        self.dirty = false
        self.result = value
        self.on_initial_complete(nil, value, real_root, on_complete)
      end
    end)
    return
  end
  self.tree:mark_unloaded(self.tree:root_node())
  self.dirty = true
  self.result = nil
  self.on_initial_complete(err, nil, nil, on_complete)
end

function Sync:load_initial(on_complete)
  local completion = on_complete
  if on_complete then
    local request = { on_complete = on_complete, completed = false }
    self.initial_refresh_request = request
    completion = function(err)
      if request.completed then return end
      request.completed = true
      if self.initial_refresh_request == request then self.initial_refresh_request = nil end
      self:_schedule_completion(request.on_complete, err)
    end
  end
  self.dirty = true
  self.result = nil
  local generation = self.tree:begin_load(self.tree:root_node())
  self.buffer:set_lines({ "" })
  local finished = false
  local function done(err, children, real_root)
    if finished then return end
    finished = true
    self.schedule(function()
      if not self.is_alive() or generation ~= self.tree:root_node().load_generation then return end
      self:_finish_initial(generation, err, children, real_root, completion)
    end)
  end
  local ok, adapter_err = pcall(self.load, self.root, done)
  if not ok then done(adapter_err) end
end

function Sync:_change_expanded(node, expanded)
  local candidate = Tree.clone(self.tree)
  local candidate_node = candidate:node_by_id(node.id)
  candidate:set_expanded(candidate_node, expanded)
  if not expanded then candidate:invalidate_loads(candidate_node) end
  local committed, err = self:_commit_tree_candidate(candidate)
  if not committed then return nil, err end
  return self.tree:node_by_id(node.id)
end

function Sync:expand(snapshot_path, on_complete, initializing, opts)
  opts = opts or {}
  if not initializing then
    if self.is_modified() then fail("buffer is modified; write or discard changes before changing the tree", 3) end
    if self.is_write_locked() then fail("instance is write-locked", 3) end
  end
  local relative = self:normalize_snapshot_path(snapshot_path)
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
      self.report_error(expand_err)
    end
  end
  local auto_expand
  local function resume_auto(parent)
    local ok, expand_err = pcall(auto_expand, parent)
    if not ok then stop(expand_err) end
  end
  auto_expand = function(parent)
    if not request.active or not self.tree:contains(parent)
        or not self.tree:is_active_directory(parent) then return end
    local children = parent.children_order or {}
    if #children ~= 1 then stop(nil); return end
    local child = children[1]
    if child.kind ~= "directory"
        or (not self.buffer:hidden_files() and child.name:sub(1, 1) == ".") then
      stop(nil)
      return
    end
    local became_expanded = not child.expanded
    local child_id = child.id
    local function continue(load_err)
      if load_err then stop(load_err); return end
      local current = self.tree:node_by_id(child_id)
      if current then resume_auto(current) else stop("expanded directory disappeared") end
    end
    if child.loaded then
      if became_expanded then
        local changed, change_err = self:_change_expanded(child, true)
        if not changed then stop(change_err); return end
        child = changed
      end
      self:rescan(child, continue)
    else
      if became_expanded then
        local changed, change_err = self:_change_expanded(child, true)
        if not changed then stop(change_err); return end
        child = changed
      end
      self:ensure_loaded(child, continue)
    end
  end
  local walk
  local function resume(parent, index)
    if request.synchronous then walk(parent, index); return end
    local ok, walk_err = pcall(walk, parent, index)
    if not ok then stop(walk_err) end
  end
  local function continue_explicit(child, index, became_expanded)
    if index < #segments then
      resume(child, index + 1)
    elseif opts.auto_expand ~= false and self.config.auto_expand_single_directory
        and (became_expanded or initializing) then
      resume_auto(child)
    else
      stop(nil)
    end
  end
  walk = function(parent, index)
    if not request.active then return end
    local child = self.tree:find_child(parent, segments[index])
    local prefix = table.concat(vim.list_slice(segments, 1, index), "/")
    if not child then stop("snapshot path does not exist: " .. prefix); return end
    if child.kind ~= "directory" then
      stop(prefix .. " is a " .. tostring(child.kind) .. " and cannot be expanded")
      return
    end
    local became_expanded = not child.expanded
    local child_id = child.id
    local function continue(load_err)
      if load_err then stop(load_err); return end
      local current = self.tree:node_by_id(child_id)
      if not current then stop("expanded directory disappeared"); return end
      continue_explicit(current, index, became_expanded)
    end
    if child.loaded then
      if became_expanded then
        local changed, change_err = self:_change_expanded(child, true)
        if not changed then stop(change_err); return end
        child = changed
      end
      local rescan_for_initial_auto = opts.auto_expand ~= false and initializing
        and index == #segments and self.config.auto_expand_single_directory
      if opts.rescan_loaded ~= false and (became_expanded or rescan_for_initial_auto) then
        if opts.auto_expand ~= false and self.config.auto_expand_single_directory then
          self:rescan(child, continue)
        else
          self:rescan(child)
          continue(nil)
        end
      else continue(nil) end
    else
      if became_expanded then
        local changed, change_err = self:_change_expanded(child, true)
        if not changed then stop(change_err); return end
        child = changed
      end
      self:ensure_loaded(child, continue)
    end
  end
  resume(self.tree:root_node(), 1)
  request.synchronous = false
  return nil
end

function Sync:collapse(snapshot_path)
  local relative = self:normalize_snapshot_path(snapshot_path)
  if relative == "" then fail("the instance root cannot be collapsed", 2) end
  local node = self:_directory_or_fail(self:_cached_node(relative), relative)
  local changed, err = self:_change_expanded(node, false)
  if not changed then error(err, 0) end
end

function Sync:collapse_all()
  local candidate = Tree.clone(self.tree)
  local changed = candidate:collapse_all()
  if not changed then return false end
  candidate:invalidate_loads(candidate:root_node())
  local committed, err = self:_commit_tree_candidate(candidate)
  if not committed then error(err, 0) end
  return true
end

function Sync:toggle_expand(snapshot_path)
  local relative = self:normalize_snapshot_path(snapshot_path)
  if relative == "" then fail("the instance root cannot be toggled", 2) end
  local node = self:_directory_or_fail(self:_cached_node(relative), relative)
  if node.expanded then return self:collapse(relative) end
  return self:expand(relative)
end

function Sync:watch_specs()
  local specs = {}
  for _, node in ipairs(self.tree:active_directories()) do
    specs[#specs + 1] = { path = node.path, node_id = node.id }
  end
  return specs
end

function Sync:sync_watchers(recreate_failed)
  if not self.is_alive() then return end
  self.watch:sync(self:watch_specs(), { recreate_failed = recreate_failed == true })
end

function Sync:suspend_watchers()
  self.watch:suspend()
end

function Sync:stop_watchers()
  self.watch:stop_all()
end

function Sync:watch_paths()
  return self.watch:paths()
end

function Sync:_schedule_completion(callback, err)
  self.schedule(function()
    if callback then
      local ok, callback_err = pcall(callback, err)
      if not ok and self.is_alive() then self.report_error(callback_err) end
    elseif err ~= nil and self.is_alive() then
      self.report_error(err)
    end
  end)
end

function Sync:_finish_request(request, err)
  if request.completed then return end
  request.completed = true
  if self.refresh_request == request then self.refresh_request = nil end
  if self.watch_refresh_request == request then self.watch_refresh_request = nil end
  if self.initial_refresh_request == request then self.initial_refresh_request = nil end
  if err ~= nil then self.dirty = true end
  self:_schedule_completion(request.on_complete, err)
end

function Sync:_new_refresh_candidate()
  return { root = self.root, real_root = self.real_root, tree = Tree.clone(self.tree) }
end

function Sync:_refresh_result(candidate)
  local children = {}
  for _, node in ipairs(candidate.tree:root_node().children_order or {}) do
    children[#children + 1] = {
      id = node.id, name = node.name, path = node.path, kind = node.kind,
    }
  end
  return { children = children, root = self.root }
end

function Sync:_current_request(request)
  if request.completed then return false end
  if request.kind == "watch" then
    return self.watch_refresh_request == request
      and self.watch_refresh_generation == request.generation
  end
  return self.refresh_request == request
    and self.refresh_generation == request.generation
end

function Sync:_watch_commit_safe(event, request)
  if not self.is_alive() or not self.is_presented() or self.is_modified()
      or self.is_write_locked() or self.is_execution_active() then return false end
  if self.refresh_request and self.refresh_request ~= request then return false end
  if not request and (self.watch_refresh_request or self.dirty) then return false end
  local node = self.tree:node_by_id(event.node_id)
  if not node or node.path ~= event.path or node.kind ~= "directory"
      or not node.loaded or not self.tree:is_active_directory(node) then return false end
  if request and self.watch_refresh_request ~= request then return false end
  for _, current in self.tree:iter_nodes() do
    if current.kind == "directory"
        and (current.load_state == "loading" or current.load_state == "refreshing") then
      return false
    end
  end
  return true
end

function Sync:_finish_watch_refresh(request, err)
  if request.completed then return end
  if err ~= nil then self.dirty = true end
  self:_finish_request(request, err)
end

function Sync:_commit_candidate(request, candidate, prepared)
  if not self:_current_request(request) then
    self:_finish_request(request, "refresh was superseded")
    return
  end
  if request.kind == "watch" and not self:_watch_commit_safe(request.event, request) then
    self.dirty = true
    self:_finish_request(request, nil)
    self:_schedule_followup()
    return
  end
  if vim.api.nvim_buf_get_changedtick(self.bufnr) ~= request.changedtick
      or vim.bo[self.bufnr].modified ~= request.modified then
    self:_finish_request(request, "buffer changed during refresh")
    return
  end
  local ok, commit_result = pcall(self.buffer.commit, self.buffer, prepared)
  if not ok or commit_result == false then
    local commit_err = ok and "buffer projection commit failed" or commit_result
    self.dirty = true
    self:_finish_request(request, commit_err)
    return
  end
  self.tree:adopt(candidate.tree)
  self.real_root = candidate.real_root
  self.result = self:_refresh_result(candidate)
  self.tree_generation = self.tree_generation + 1
  local followup = self.watch_event_generation > request.watch_event_generation
  if request.kind == "watch" then followup = request.had_dirty or followup end
  self.dirty = followup
  self:sync_watchers(true)
  self:_finish_request(request, nil)
  if self.dirty then self:_schedule_followup() end
end

function Sync:_scan_candidate(request, candidate, paths, index)
  if not self:_current_request(request) then
    self:_finish_request(request, "refresh was superseded")
    return
  end
  local scan_path = paths[index]
  if not scan_path then
    local sort_ok, sort_err = pcall(candidate.tree.sort_cached, candidate.tree)
    if not sort_ok then self:_finish_request(request, sort_err); return end
    local prepared_ok, prepared = pcall(
      self.buffer.prepare_projection, self.buffer, true, candidate.tree
    )
    if not prepared_ok then self:_finish_request(request, prepared); return end
    self:_commit_candidate(request, candidate, prepared)
    return
  end
  local node = candidate.tree:node_by_path(scan_path)
  if not node then self:_scan_candidate(request, candidate, paths, index + 1); return end
  if node.kind ~= "directory" or not candidate.tree:is_active_directory(node) then
    self:_scan_candidate(request, candidate, paths, index + 1)
    return
  end
  local load_generation = candidate.tree:begin_load(node, "refreshing")
  local finished = false
  local function done(err, children, real_path)
    if finished then return end
    finished = true
    self.schedule(function()
      if not self:_current_request(request) then return end
      if not candidate.tree:is_current_load(node, load_generation, "refreshing") then
        self:_finish_request(request, "refresh directory generation was superseded")
        return
      end
      if err ~= nil then self:_finish_request(request, err); return end
      local reconcile_ok, reconcile_err = pcall(function()
        candidate.tree:reconcile(node, children or {})
        if real_path then node.real_path = real_path end
        if index == 1 and request.kind == "full" then candidate.real_root = real_path end
      end)
      if not reconcile_ok then self:_finish_request(request, reconcile_err); return end
      self:_scan_candidate(request, candidate, paths, index + 1)
    end)
  end
  local ok, adapter_err = pcall(self.load, scan_path, done)
  if not ok then done(adapter_err) end
end

function Sync:_start_refresh(request, paths)
  local candidate_ok, candidate = pcall(self._new_refresh_candidate, self)
  if not candidate_ok then self:_finish_request(request, candidate); return end
  request.candidate = candidate
  self:_scan_candidate(request, candidate, paths, 1)
end

function Sync:refresh(force, on_complete, write_reconciliation)
  self.refresh_generation = self.refresh_generation + 1
  local request = {
    kind = "full",
    generation = self.refresh_generation,
    force = force == true,
    write_reconciliation = write_reconciliation == true,
    on_complete = on_complete,
    changedtick = vim.api.nvim_buf_get_changedtick(self.bufnr),
    modified = vim.bo[self.bufnr].modified,
    active_paths = self.tree:active_expanded_paths(),
    had_dirty = self.dirty,
    watch_event_generation = self.watch_event_generation,
    completed = false,
  }
  self.refresh_request = request
  self.dirty = true
  local paths = { self.root }
  for _, active_path in ipairs(request.active_paths) do paths[#paths + 1] = active_path end
  self:_start_refresh(request, paths)
end

function Sync:_reconcile_write(on_complete)
  return self:refresh(true, on_complete, true)
end

function Sync:presentation_refresh(on_complete)
  return self:refresh(false, on_complete, false)
end

function Sync:_schedule_followup()
  if not self.is_alive() or not self.dirty or self.watch_followup_scheduled then return end
  self.watch_followup_scheduled = true
  self.schedule(function()
    if not self.is_alive() then return end
    self.watch_followup_scheduled = false
    if self.dirty and self.is_presented() then self.on_followup_needed() end
  end)
end

function Sync:_next_watch_event_generation()
  self.watch_event_generation = self.watch_event_generation + 1
  return self.watch_event_generation
end

function Sync:_mark_watch_pending(generation)
  generation = generation or self:_next_watch_event_generation()
  self.watch_pending_generation = math.max(self.watch_pending_generation, generation)
  self.dirty = true
end

function Sync:_on_watch_error(event, err)
  if not self.is_alive() then return end
  self:_mark_watch_pending()
  self.report_error("watch failed for " .. event.path .. ": " .. tostring(err))
end

function Sync:_on_watch_event(event)
  if not self.is_alive() then return end
  local generation = self:_next_watch_event_generation()
  if not self:_watch_commit_safe(event) then
    self:_mark_watch_pending(generation)
    return
  end
  self.watch_refresh_generation = self.watch_refresh_generation + 1
  local request = {
    kind = "watch",
    generation = self.watch_refresh_generation,
    event = event,
    path = event.path,
    changedtick = vim.api.nvim_buf_get_changedtick(self.bufnr),
    modified = vim.bo[self.bufnr].modified,
    had_dirty = self.dirty,
    watch_event_generation = generation,
    on_complete = nil,
    completed = false,
  }
  self.watch_refresh_request = request
  self.dirty = true
  self:_start_refresh(request, { event.path })
end

function Sync:cancel_active_watch_refresh()
  local request = self.watch_refresh_request
  if not request then return false end
  request.completed = true
  self.watch_refresh_request = nil
  self.watch_refresh_generation = self.watch_refresh_generation + 1
  self:_mark_watch_pending()
  self:_schedule_followup()
  return true
end

function Sync:write_reconcile(run, on_complete)
  local completed = false

  local function restore_watchers()
    self:sync_watchers(true)
    if self.dirty then self:_schedule_followup() end
  end

  local function complete(outcome, reconcile)
    if completed then return false end
    completed = true
    if reconcile == false then
      on_complete(outcome, nil, false)
      restore_watchers()
      return true
    end
    local ok, err = pcall(self._reconcile_write, self, function(reconciliation_error)
      on_complete(outcome, reconciliation_error, true)
      restore_watchers()
    end)
    if not ok then
      on_complete(outcome, err, true)
      restore_watchers()
    end
    return true
  end

  local function execute(start_execution)
    if path.is_windows(self.root) then self.watch:suspend() end
    local ok, result = pcall(start_execution, complete)
    if ok then return result end
    complete(nil, false)
    error(result, 0)
  end

  local ok, result = pcall(run, execute, complete)
  if ok then return result end
  complete(nil, false)
  error(result, 0)
end

function Sync:schedule_followup()
  self:_schedule_followup()
end

function Sync:is_followup_scheduled()
  return self.watch_followup_scheduled
end

function Sync:watch_event_generation_value()
  return self.watch_event_generation
end

function Sync:is_busy()
  return self.refresh_request ~= nil or self.watch_refresh_request ~= nil
end

function Sync:is_full_refresh_busy()
  return self.refresh_request ~= nil
end

function Sync:is_dirty()
  return self.dirty
end

function Sync:real_root_value()
  return self.real_root
end

function Sync:result_value()
  return self.result
end

function Sync:watcher_paths()
  return self.watch:paths()
end

function Sync:destroy()
  if self.refresh_request then
    self:_finish_request(self.refresh_request, "instance was destroyed during refresh")
  end
  if self.initial_refresh_request then
    self:_finish_request(self.initial_refresh_request, "instance was destroyed during refresh")
  end
  if self.watch_refresh_request then self.watch_refresh_request.completed = true end
  self.refresh_generation = self.refresh_generation + 1
  self.watch_refresh_generation = self.watch_refresh_generation + 1
  self.watch_event_generation = self.watch_event_generation + 1
  self.watch_followup_scheduled = false
  self.load_requests = {}
  self.refresh_request = nil
  self.watch_refresh_request = nil
  self.initial_refresh_request = nil
  self.watch:stop_all()
end

return Sync
