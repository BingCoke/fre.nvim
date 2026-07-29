local fre = require("fre")
local manager_module = require("fre.manager")
local fs = require("tests.helpers.fs")
local window = require("fre.window")

local fixture
local instances = {}
local clock

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate, timeout)
  assert.is_true(vim.wait(timeout or 3000, predicate, 10))
end

local function assert_error_contains(callback, expected)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find(expected, 1, true), tostring(err))
end

local function wait_ready(instance)
  wait_for(function()
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
end

local function fake_clock()
  local value = 0
  local scheduled = {}
  local timers = {}
  local adapter = {}

  function adapter.now() return value end
  function adapter.new_timer()
    local timer = {
      active = false, stop_count = 0, close_count = 0, closed = false,
    }
    timers[#timers + 1] = timer
    return timer
  end
  function adapter.timer_start(timer, timeout, callback)
    timer.active = true
    timer.timeout = timeout
    timer.deadline = value + timeout
    timer.callback = callback
    return true
  end
  function adapter.timer_stop(timer)
    timer.stop_count = timer.stop_count + 1
    timer.active = false
    return true
  end
  function adapter.close(timer)
    timer.close_count = timer.close_count + 1
    timer.closed = true
    return true
  end
  function adapter.schedule(callback)
    scheduled[#scheduled + 1] = callback
    return true
  end

  local result = { adapter = adapter, timers = timers, scheduled = scheduled }
  function result:set_now(next_value) value = next_value end
  function result:now() return value end
  function result:drain()
    while #scheduled > 0 do
      local callback = table.remove(scheduled, 1)
      callback()
    end
  end
  function result:advance(amount)
    value = value + amount
    local due = {}
    for _, timer in ipairs(timers) do
      if timer.active and timer.deadline <= value then
        timer.active = false
        due[#due + 1] = timer
      end
    end
    table.sort(due, function(left, right) return left.deadline < right.deadline end)
    for _, timer in ipairs(due) do timer.callback() end
    self:drain()
  end
  function result:fire_stale(timer)
    assert.is_function(timer.callback)
    timer.callback()
    self:drain()
  end
  function result:assert_closed_once()
    for _, timer in ipairs(timers) do
      assert.are.equal(1, timer.stop_count, "GC timer was not stopped exactly once")
      assert.are.equal(1, timer.close_count, "GC timer was not closed exactly once")
      assert.is_true(timer.closed)
    end
  end
  return result
end

local function ready(opts)
  opts = vim.tbl_extend("force", { root = fixture.root, columns = {} }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function scratch()
  return vim.api.nvim_create_buf(false, true)
end

local function hide_all(instance)
  for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_set_buf(winid, scratch())
    end
  end
  window.sync_visibility(instance)
end

local function sorted_windows(bufnr)
  local result = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      result[#result + 1] = winid
    end
  end
  table.sort(result)
  return result
end

local function pending_mutation(pending)
  local function hold(_, done) pending.done = done end
  return {
    create_file = hold,
    create_directory = hold,
    copy = function(_, _, _, done) pending.done = done end,
    move = function(_, _, done) pending.done = done end,
    delete = function(_, _, done) pending.done = done end,
  }
end

local function lifecycle_snapshot(instance)
  local watcher_entries = {}
  for watch_path, entry in pairs(instance._watchers.entries) do
    watcher_entries[watch_path] = {
      entry = entry, handle = entry.handle, timer = entry.timer,
      handle_closed = entry.handle and entry.handle.closed,
      timer_closed = entry.timer and entry.timer.closed,
    }
  end
  return {
    state = instance.state,
    destroyed = instance._destroyed,
    text = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false),
    modified = vim.bo[instance.bufnr].modified,
    modifiable = vim.bo[instance.bufnr].modifiable,
    buftype = vim.bo[instance.bufnr].buftype,
    windows = sorted_windows(instance.bufnr),
    timer = instance._gc_timer,
    timer_generation = instance._gc_generation,
    hidden_since = instance.hidden_since,
    watchers = instance._watchers,
    watcher_entries = watcher_entries,
    id_index = instance.manager.instances_by_id[instance.id],
    buf_index = instance.manager.instances_by_buf[instance.bufnr],
    group_index = instance.manager.groups[instance.config.gc.group].instances[instance.id],
    actions = instance.actions,
    execution = instance._execution,
  }
end

local function assert_lifecycle_snapshot(instance, expected)
  assert.are.equal(expected.state, instance.state)
  assert.are.equal(expected.destroyed, instance._destroyed)
  assert.are.same(expected.text, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
  assert.are.equal(expected.modified, vim.bo[instance.bufnr].modified)
  assert.are.equal(expected.modifiable, vim.bo[instance.bufnr].modifiable)
  assert.are.equal(expected.buftype, vim.bo[instance.bufnr].buftype)
  assert.are.same(expected.windows, sorted_windows(instance.bufnr))
  assert.are.equal(expected.timer, instance._gc_timer)
  assert.are.equal(expected.timer_generation, instance._gc_generation)
  assert.are.equal(expected.hidden_since, instance.hidden_since)
  assert.are.equal(expected.watchers, instance._watchers)
  for watch_path, snapshot in pairs(expected.watcher_entries) do
    local entry = instance._watchers.entries[watch_path]
    assert.are.equal(snapshot.entry, entry)
    assert.are.equal(snapshot.handle, entry.handle)
    assert.are.equal(snapshot.timer, entry.timer)
    assert.are.equal(snapshot.handle_closed, entry.handle and entry.handle.closed)
    assert.are.equal(snapshot.timer_closed, entry.timer and entry.timer.closed)
  end
  assert.are.equal(expected.id_index, instance.manager.instances_by_id[instance.id])
  assert.are.equal(expected.buf_index, instance.manager.instances_by_buf[instance.bufnr])
  assert.are.equal(expected.group_index,
    instance.manager.groups[instance.config.gc.group].instances[instance.id])
  assert.are.equal(expected.actions, instance.actions)
  assert.are.equal(expected.execution, instance._execution)
end

local function set_modified(instance, modified)
  vim.bo[instance.bufnr].modified = modified
  vim.api.nvim_exec_autocmds("BufModifiedSet", {
    buffer = instance.bufnr, modeline = false,
  })
end

local function fake_watcher()
  local adapter = { handles = {}, timers = {} }
  function adapter.new_fs_event()
    local handle = { close_count = 0, stop_count = 0, closed = false }
    adapter.handles[#adapter.handles + 1] = handle
    adapter.pending_handle = handle
    return handle
  end
  function adapter.fs_event_start(handle, watch_path, callback)
    handle.path = watch_path
    handle.callback = callback
    return true
  end
  function adapter.new_timer()
    local timer = { close_count = 0, stop_count = 0, closed = false }
    adapter.timers[#adapter.timers + 1] = timer
    adapter.pending_handle.timer = timer
    adapter.pending_handle = nil
    return timer
  end
  function adapter.timer_start(timer, _, callback)
    timer.callback = callback
    return true
  end
  function adapter.timer_stop(resource)
    if resource then resource.stop_count = resource.stop_count + 1 end
    return true
  end
  function adapter.close(resource)
    if resource and not resource.closed then
      resource.closed = true
      resource.close_count = resource.close_count + 1
    end
    return true
  end
  function adapter.schedule(callback)
    vim.schedule(callback)
    return true
  end
  return adapter
end

local function drain_editor()
  vim.wait(30, function() return false end, 5)
end

describe("fre ticket 19 destroy and GC", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture = fs.new()
    fixture:tree({ ["one.txt"] = "one" })
    instances = {}
    clock = fake_clock()
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
    fre._reset_watch_adapter()
    fre._set_gc_adapter(clock.adapter)
    fre.setup({
      default_file_explorer = false,
      columns = {},
      gc = { ttl_ms = 0, groups = { default = 0, project = 0 } },
    })
  end)

  after_each(function()
    fre._reset_mutation_adapter()
    fre._reset_fs_adapter()
    fre._reset_watch_adapter()
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then
        if instance.actions and instance.actions.write then
          pcall(instance._release_write_lock, instance, instance.actions.write)
          clock:drain()
        end
        local execution = instance._execution
        if execution then
          local status = execution:get_status().state
          if status == "running" then execution:cancel() end
          vim.wait(500, function()
            local state = execution:get_status().state
            return state == "succeeded" or state == "failed" or state == "canceled"
          end, 10)
          clock:drain()
        end
        if instance.state ~= "destroyed" then pcall(instance.destroy, instance) end
      end
    end
    clock:drain()
    clock:assert_closed_once()
    fre._reset_gc_adapter()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture:cleanup()
  end)

  it("rejects lock and nonterminal Execution before changing any lifecycle state", function()
    local locked = ready({ gc = { ttl_ms = 100 } })
    local token = locked:_acquire_write_lock()
    local locked_snapshot = lifecycle_snapshot(locked)
    assert_error_contains(function() locked:destroy() end, "write-locked")
    assert_lifecycle_snapshot(locked, locked_snapshot)
    assert.are.equal(token, locked.actions.write)
    clock:advance(100)
    assert.are_not.equal("destroyed", locked.state)
    assert.are.equal(0, locked.hidden_since)
    locked:_release_write_lock(token)
    clock:drain()
    assert.are.equal("destroyed", locked.state)

    local pending = {}
    fre._set_mutation_adapter(pending_mutation(pending))
    local executing = ready({ gc = { ttl_ms = 100 } })
    local execution = executing:execute({ operations = {
      { type = "create_file", path = "held" },
    } })
    wait_for(function() return pending.done ~= nil end)
    local execution_snapshot = lifecycle_snapshot(executing)
    assert_error_contains(function() executing:destroy() end, "active execution")
    assert_lifecycle_snapshot(executing, execution_snapshot)
    assert.are.equal(execution, executing._execution)
    clock:advance(100)
    assert.are_not.equal("destroyed", executing.state)
    assert.are.equal(100, executing.hidden_since)
    pending.done(nil)
    wait_for(function() return execution:get_status().state == "succeeded" end)
    clock:drain()
    assert.are.equal("destroyed", executing.state)
  end)

  it("force-destroys a modified multi-tab instance and drops all resources and mutable state", function()
    local instance = ready({ gc = { ttl_ms = 100 } })
    instance:open({ position = "current" })
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, instance.bufnr)
    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, instance.bufnr)
    window.sync_visibility(instance)
    assert.are.equal(3, #sorted_windows(instance.bufnr))
    vim.bo[instance.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, { "unsaved draft" })
    vim.bo[instance.bufnr].modified = true

    local id, bufnr, root = instance.id, instance.bufnr, instance.root
    local watchers = instance._watchers
    local timer = instance._gc_timer
    instance:destroy()

    assert.are.equal("destroyed", instance.state)
    assert.is_true(instance._destroyed)
    assert.are.equal(id, instance.id)
    assert.are.equal(bufnr, instance.bufnr)
    assert.are.equal(root, instance.root)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.are.same({}, sorted_windows(bufnr))
    assert.is_true(watchers.destroyed)
    if timer then assert.are.equal(1, timer.handle.close_count or 1) end
    assert.is_nil(manager_module.default.instances_by_id[id])
    assert.is_nil(manager_module.default.instances_by_buf[bufnr])
    for _, group in pairs(manager_module.default.groups) do assert.is_nil(group.instances[id]) end
    for _, field in ipairs({
      "manager", "config", "tree", "root_node", "nodes_by_id", "nodes_by_path", "view",
      "actions", "_execution", "_watchers", "_buffer_augroup", "_mapping_installed",
      "_installed_mappings", "_pending_reveal", "_last_layout_by_tab",
      "hidden_since", "_gc_timer", "_gc_expired_reconsider", "needs_refresh",
      "result", "error", "real_root",
    }) do
      assert.is_nil(instance[field], field .. " survived destruction")
    end

    local calls = {
      function() instance:destroy() end,
      function() instance:when_ready(function() end) end,
      function() instance:open() end,
      function() instance:hidden() end,
      function() instance:toggle() end,
      function() instance:refresh() end,
      function() instance:execute({ operations = {} }) end,
      function() instance:prepare() end,
      function() instance:get_entry(1) end,
      function() instance:get_pos("one.txt") end,
      function() instance:set_sort(function() return false end) end,
      function() instance:set_hidden_file(true) end,
      function() instance:setGroup("project") end,
      function() instance:expand("one.txt") end,
      function() instance:collapse("one.txt") end,
      function() instance:reveal("one.txt") end,
    }
    for _, call in ipairs(calls) do assert_error_contains(call, "destroyed") end
  end)

  it("defers idempotent terminal cleanup after external buffer deletion", function()
    local watcher = fake_watcher()
    fre._set_watch_adapter(watcher)
    local manager = manager_module.default

    for _, case in ipairs({
      { command = "bdelete!", valid_after_command = true },
      { command = "bwipeout!", valid_after_command = false },
    }) do
      local instance = ready({ gc = { ttl_ms = 100 } })
      local id, bufnr = instance.id, instance.bufnr
      local group_name = instance.config.gc.group
      local watchers = instance._watchers
      local gc_timer = assert(instance._gc_timer).handle
      local scheduled = {}
      local original_schedule = vim.schedule
      vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
      local ok, err = pcall(vim.cmd, case.command .. " " .. tostring(bufnr))
      vim.schedule = original_schedule
      assert.is_true(ok, tostring(err))

      assert.are.equal(case.valid_after_command, vim.api.nvim_buf_is_valid(bufnr))
      assert.is_false(vim.api.nvim_buf_is_loaded(bufnr))
      assert.are.equal("ready-hidden", instance.state)
      assert.is_false(instance._destroyed)
      assert.are.equal(instance, fre.get_instance(bufnr))
      assert.are.equal(instance, fre.get_instance_by_id(id))
      assert.are.equal(instance, manager:find_by_buf(bufnr))
      assert.are.equal(instance, manager:find_by_group(group_name)[id])
      assert.is_false(watchers.destroyed)
      assert.are.equal(0, gc_timer.stop_count)
      assert.are.equal(0, gc_timer.close_count)
      assert.are.equal(1, #scheduled)

      local cleanup = table.remove(scheduled, 1)
      cleanup()

      assert.are.same({}, scheduled)
      assert.are.equal("destroyed", instance.state)
      assert.is_true(instance._destroyed)
      assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
      assert.is_nil(fre.get_instance(bufnr))
      assert.is_nil(fre.get_instance_by_id(id))
      assert.is_nil(manager:find_by_buf(bufnr))
      assert.is_nil(manager:find_by_group(group_name)[id])
      assert.is_true(watchers.destroyed)
      assert.are.equal(1, gc_timer.stop_count)
      assert.are.equal(1, gc_timer.close_count)
      assert.is_true(#watcher.handles > 0)
      assert.is_true(#watcher.timers > 0)
      for _, handle in ipairs(watcher.handles) do
        assert.are.equal(1, handle.close_count)
      end
      for _, timer in ipairs(watcher.timers) do
        assert.are.equal(1, timer.stop_count)
        assert.are.equal(1, timer.close_count)
      end
    end
  end)

  it("finishes external cleanup when destroy start raises after transitioning", function()
    local instance = ready({ gc = { ttl_ms = 100 } })
    local manager = manager_module.default
    local id, bufnr = instance.id, instance.bufnr
    local group_name = instance.config.gc.group
    local reported = {}
    local original_start = instance._start_destroy
    instance._start_destroy = function(self)
      original_start(self)
      error("start failed after transition")
    end
    instance._report_async_error = function(_, err) reported[#reported + 1] = tostring(err) end

    local scheduled = {}
    local original_schedule = vim.schedule
    vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
    local ok, err = pcall(vim.cmd, "bwipeout! " .. tostring(bufnr))
    vim.schedule = original_schedule
    assert.is_true(ok, tostring(err))
    assert.are.equal("ready-hidden", instance.state)
    assert.are.equal(1, #scheduled)

    table.remove(scheduled, 1)()

    assert.are.same({}, scheduled)
    assert.are.equal("destroyed", instance.state)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_nil(fre.get_instance(bufnr))
    assert.is_nil(fre.get_instance_by_id(id))
    assert.is_nil(manager:find_by_buf(bufnr))
    assert.is_nil(manager:find_by_group(group_name)[id])
    assert.are.equal(1, #reported)
    assert.is_truthy(reported[1]:find("start failed after transition", 1, true))
  end)

  it("finalizes a retained destroying instance after external buffer wipeout", function()
    local watcher = fake_watcher()
    fre._set_watch_adapter(watcher)
    local instance = ready({ gc = { ttl_ms = 100 } })
    local manager = manager_module.default
    local id, bufnr = instance.id, instance.bufnr
    local group_name = instance.config.gc.group
    local watchers = instance._watchers
    local gc_timer = assert(instance._gc_timer).handle
    local original_delete = vim.api.nvim_buf_delete
    local original_call = vim.api.nvim_buf_call
    vim.api.nvim_buf_delete = function() error("API delete failed") end
    vim.api.nvim_buf_call = function() error("fallback delete failed") end
    local destroy_ok, destroy_err = pcall(instance.destroy, instance)
    vim.api.nvim_buf_delete = original_delete
    vim.api.nvim_buf_call = original_call

    assert.is_false(destroy_ok)
    assert.is_truthy(tostring(destroy_err):find("fallback delete failed", 1, true))
    assert.are.equal("destroying", instance.state)
    assert.is_true(instance._destroyed)
    assert.are.equal(instance, manager.instances_by_id[id])
    assert.are.equal(instance, manager.instances_by_buf[bufnr])
    assert.are.equal(instance, manager.groups[group_name].instances[id])

    local scheduled = {}
    local original_schedule = vim.schedule
    vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
    local wipe_ok, wipe_err = pcall(vim.cmd, "bwipeout! " .. tostring(bufnr))
    vim.schedule = original_schedule
    assert.is_true(wipe_ok, tostring(wipe_err))

    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.are.equal("destroying", instance.state)
    assert.are.equal(instance, fre.get_instance(bufnr))
    assert.are.equal(instance, fre.get_instance_by_id(id))
    assert.are.equal(instance, manager:find_by_buf(bufnr))
    assert.are.equal(instance, manager:find_by_group(group_name)[id])
    assert.are.equal(1, #scheduled)

    table.remove(scheduled, 1)()

    assert.are.same({}, scheduled)
    assert.are.equal("destroyed", instance.state)
    assert.is_nil(fre.get_instance(bufnr))
    assert.is_nil(fre.get_instance_by_id(id))
    assert.is_nil(manager:find_by_buf(bufnr))
    assert.is_nil(manager:find_by_group(group_name)[id])
    assert.is_true(watchers.destroyed)
    assert.are.equal(1, gc_timer.stop_count)
    assert.are.equal(1, gc_timer.close_count)
    for _, handle in ipairs(watcher.handles) do assert.are.equal(1, handle.close_count) end
    for _, timer in ipairs(watcher.timers) do
      assert.are.equal(1, timer.stop_count)
      assert.are.equal(1, timer.close_count)
    end
  end)

  it("keeps failed buffer deletion indexed and retries finalization exactly once", function()
    local watcher = fake_watcher()
    fre._set_watch_adapter(watcher)
    local instance = ready({ gc = { ttl_ms = 100 } })
    local manager = manager_module.default
    local id, bufnr = instance.id, instance.bufnr
    local gc_timer = assert(instance._gc_timer).handle
    local original_delete = vim.api.nvim_buf_delete
    local original_call = vim.api.nvim_buf_call
    vim.api.nvim_buf_delete = function() error("API delete failed") end
    vim.api.nvim_buf_call = function() error("fallback delete failed") end
    local ok, err = pcall(instance.destroy, instance)
    vim.api.nvim_buf_delete = original_delete
    vim.api.nvim_buf_call = original_call

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("fallback delete failed", 1, true), tostring(err))
    assert.are.equal("destroying", instance.state)
    assert.is_true(instance._destroyed)
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    assert.are.equal(instance, manager.instances_by_id[id])
    assert.are.equal(instance, manager.instances_by_buf[bufnr])
    assert.are.equal(instance, manager.groups[instance.config.gc.group].instances[id])
    assert.is_table(instance.config)
    assert.is_true(instance._watchers.destroyed)
    assert.are.equal(1, gc_timer.stop_count)
    assert.are.equal(1, gc_timer.close_count)
    for _, handle in ipairs(watcher.handles) do assert.are.equal(1, handle.close_count) end
    for _, timer in ipairs(watcher.timers) do assert.are.equal(1, timer.close_count) end

    instance:destroy()
    assert.are.equal("destroyed", instance.state)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_nil(manager.instances_by_id[id])
    assert.is_nil(manager.instances_by_buf[bufnr])
    assert.are.equal(1, gc_timer.stop_count)
    assert.are.equal(1, gc_timer.close_count)
    for _, handle in ipairs(watcher.handles) do assert.are.equal(1, handle.close_count) end
    for _, timer in ipairs(watcher.timers) do assert.are.equal(1, timer.close_count) end

    local post_effect = ready({ gc = { ttl_ms = 100 } })
    local post_id, post_buf = post_effect.id, post_effect.bufnr
    vim.api.nvim_buf_delete = function(...)
      original_delete(...)
      error("delete failed after effect")
    end
    local post_ok, post_err = pcall(post_effect.destroy, post_effect)
    vim.api.nvim_buf_delete = original_delete
    assert.is_true(post_ok, tostring(post_err))
    assert.are.equal("destroyed", post_effect.state)
    assert.is_false(vim.api.nvim_buf_is_valid(post_buf))
    assert.is_nil(manager.instances_by_id[post_id])
    assert_error_contains(function() post_effect:destroy() end, "destroyed")
  end)

  it("makes late load, refresh, watch, visibility, and timer callbacks inert", function()
    local initial_done
    fre._set_fs_adapter({ load = function(_, done) initial_done = done end })
    local loading = keep(fre.new({
      root = fixture.root, columns = {}, gc = { ttl_ms = 50 },
    }))
    local stale_timer = assert(loading._gc_timer).handle
    local loading_buf = loading.bufnr
    loading:destroy()
    initial_done(nil, {}, fixture.root)
    clock:fire_stale(stale_timer)
    drain_editor()
    assert.are.equal("destroyed", loading.state)
    assert.is_false(vim.api.nvim_buf_is_valid(loading_buf))

    fre._reset_fs_adapter()
    local refreshing = ready({ gc = { ttl_ms = 50 } })
    local refresh_done
    local refresh_callbacks = 0
    fre._set_fs_adapter({ load = function(_, done) refresh_done = done end })
    refreshing:refresh({ on_complete = function() refresh_callbacks = refresh_callbacks + 1 end })
    refreshing:destroy()
    refresh_done(nil, {}, fixture.root)
    wait_for(function() return refresh_callbacks == 1 end)
    drain_editor()
    assert.are.equal(1, refresh_callbacks)
    assert.are.equal("destroyed", refreshing.state)

    fre._reset_fs_adapter()
    local watcher = fake_watcher()
    fre._set_watch_adapter(watcher)
    local watched = ready({ gc = { ttl_ms = 50 } })
    local event = assert(watcher.handles[1]).callback
    local debounce = watcher.timers[1] and watcher.timers[1].callback
    watched:destroy()
    event(nil, "late", {})
    if debounce then debounce() end
    drain_editor()
    for _, handle in ipairs(watcher.handles) do assert.are.equal(1, handle.close_count) end
    for _, timer in ipairs(watcher.timers) do assert.are.equal(1, timer.close_count) end
    assert.are.equal("destroyed", watched.state)

    fre._reset_watch_adapter()
  end)

  it("delivers queued and already-scheduled when_ready observers exactly once on destroy", function()
    local initial_done
    fre._set_fs_adapter({ load = function(_, done) initial_done = done end })
    local loading = keep(fre.new({ root = fixture.root, columns = {} }))
    local queued_calls, queued_errors = 0, {}
    local original_schedule = vim.schedule
    local reported_callback_error
    loading:when_ready(function(err)
      queued_calls = queued_calls + 1
      queued_errors[#queued_errors + 1] = err
    end)
    loading:when_ready(function(err)
      queued_calls = queued_calls + 1
      queued_errors[#queued_errors + 1] = err
      vim.schedule = function(callback) reported_callback_error = callback end
      error("destroy observer exploded")
    end)
    loading:destroy()
    assert.are.equal(0, queued_calls)
    initial_done(nil, {}, fixture.root)
    local waited, wait_err = pcall(wait_for, function() return queued_calls == 2 end)
    vim.schedule = original_schedule
    if not waited then error(wait_err, 0) end

    assert.are.equal("destroyed", loading.state)
    assert.are.equal(2, queued_calls)
    assert.is_function(reported_callback_error)
    for _, err in ipairs(queued_errors) do
      assert.is_truthy(tostring(err):find("destroyed", 1, true), tostring(err))
    end
    drain_editor()
    assert.are.equal(2, queued_calls)

    fre._reset_fs_adapter()
    local ready_instance = ready()
    local ready_calls, ready_error = 0, false
    ready_instance:when_ready(function(err)
      ready_calls = ready_calls + 1
      ready_error = err
    end)
    ready_instance:destroy()
    wait_for(function() return ready_calls == 1 end)
    drain_editor()
    assert.are.equal(1, ready_calls)
    assert.is_nil(ready_error)
  end)

  it("tracks actual multi-view continuous hidden intervals and rejects stale timer generations", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 100, groups = { default = 0, project = 0 },
    } })
    local instance = ready()
    local registration_timer = assert(instance._gc_timer).handle
    clock:advance(40)
    instance:open({ position = "current" })
    assert.is_nil(instance.hidden_since)
    assert.are.equal(1, registration_timer.close_count)

    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, instance.bufnr)
    vim.cmd("tabnew")
    vim.api.nvim_win_set_buf(0, instance.bufnr)
    window.sync_visibility(instance)
    local views = sorted_windows(instance.bufnr)
    vim.api.nvim_win_set_buf(views[1], scratch())
    window.sync_visibility(instance)
    assert.is_nil(instance.hidden_since)
    vim.api.nvim_win_set_buf(views[2], scratch())
    window.sync_visibility(instance)
    assert.is_nil(instance.hidden_since)
    vim.api.nvim_win_set_buf(views[3], scratch())
    window.sync_visibility(instance)
    assert.are.equal(40, instance.hidden_since)
    local final_timer = assert(instance._gc_timer).handle

    clock:fire_stale(registration_timer)
    assert.are.equal("ready-hidden", instance.state)
    clock:advance(99)
    assert.are.equal("ready-hidden", instance.state)
    instance:open({ position = "current" })
    assert.is_nil(instance.hidden_since)
    hide_all(instance)
    assert.are.equal(139, instance.hidden_since)
    local reset_timer = assert(instance._gc_timer).handle
    clock:fire_stale(final_timer)
    assert.are.equal("ready-hidden", instance.state)
    clock:advance(100)
    assert.are.equal("destroyed", instance.state)
    assert.are.equal(1, reset_timer.close_count)
  end)

  it("defers expired registration and final-hide arms and invalidates stale intervals", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 1, groups = { default = 0, project = 0 },
    } })
    local ordinary_now = clock.adapter.now
    local registration_now_calls = 0
    clock.adapter.now = function()
      registration_now_calls = registration_now_calls + 1
      return registration_now_calls == 1 and 0 or 2
    end
    local expired_registration = ready()
    assert.are.equal("ready-hidden", expired_registration.state)
    assert.are.equal(0, #clock.timers)
    assert.are.equal(1, #clock.scheduled)
    clock:drain()
    assert.are.equal("destroyed", expired_registration.state)

    clock.adapter.now = ordinary_now
    clock:set_now(10)
    local final_hide = ready()
    local registration_timer = assert(final_hide._gc_timer).handle
    final_hide:open({ position = "current" })
    assert.are.equal(1, registration_timer.close_count)
    local hide_now_calls = 0
    clock.adapter.now = function()
      hide_now_calls = hide_now_calls + 1
      return hide_now_calls == 1 and 20 or 22
    end
    hide_all(final_hide)
    assert.are.equal("ready-hidden", final_hide.state)
    assert.are.equal(1, #clock.timers)
    assert.are.equal(1, #clock.scheduled)

    final_hide:open({ position = "current" })
    clock.adapter.now = ordinary_now
    clock:set_now(30)
    hide_all(final_hide)
    assert.are.equal(30, final_hide.hidden_since)
    local current_timer = assert(final_hide._gc_timer).handle
    clock:drain()
    assert.are.equal("ready-hidden", final_hide.state)
    assert.are.equal(30, final_hide.hidden_since)
    clock:advance(1)
    assert.are.equal("destroyed", final_hide.state)
    assert.are.equal(1, current_timer.close_count)
  end)

  it("keeps TTL and capacity zero-disable behavior independent", function()
    assert_error_contains(function() fre._set_gc_adapter({}) end, "provide now")
    fre.setup({ columns = {}, gc = {
      ttl_ms = 10, groups = { default = 0, project = 0 },
    } })
    local ttl = ready()
    assert_error_contains(function()
      fre._set_gc_adapter(fake_clock().adapter)
    end, "while live instances exist")
    clock:advance(10)
    assert.are.equal("destroyed", ttl.state)

    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 1, project = 0 },
    } })
    local older = ready()
    clock:advance(1)
    local newer = ready()
    assert.are.equal("destroyed", older.state)
    assert.are_not.equal("destroyed", newer.state)
    clock:advance(1000)
    assert.are_not.equal("destroyed", newer.state)
  end)

  it("uses one live-index and actual-window eligibility filter", function()
    local manager = manager_module.default
    local base = ready({ gc = { ttl_ms = 0, include_modified = false } })
    assert.is_true(manager:is_gc_eligible(base))
    base:open({ position = "current" })
    assert.is_false(manager:is_gc_eligible(base))
    hide_all(base)
    assert.is_true(manager:is_gc_eligible(base))
    set_modified(base, true)
    assert.is_false(manager:is_gc_eligible(base))
    set_modified(base, false)
    clock:drain()
    local token = base:_acquire_write_lock()
    assert.is_false(manager:is_gc_eligible(base))
    base:_release_write_lock(token)
    clock:drain()
    assert.is_true(manager:is_gc_eligible(base))

    local included = ready({ gc = { ttl_ms = 0, include_modified = true } })
    set_modified(included, true)
    assert.is_true(manager:is_gc_eligible(included))

    local pending = {}
    fre._set_mutation_adapter(pending_mutation(pending))
    local execution = base:execute({ operations = {
      { type = "create_file", path = "held" },
    } })
    wait_for(function() return pending.done ~= nil end)
    assert.is_false(manager:is_gc_eligible(base))
    pending.done(nil)
    wait_for(function() return execution:get_status().state == "succeeded" end)
    clock:drain()
    assert.is_true(manager:is_gc_eligible(base))

    manager:remove(included)
    assert.is_false(manager:is_gc_eligible(included))
    assert.is_true(vim.api.nvim_buf_is_valid(included.bufnr))
    included:destroy()
  end)

  it("filters modified TTL by the snapshotted include_modified policy", function()
    local protected = ready({ gc = { ttl_ms = 20, include_modified = false } })
    set_modified(protected, true)
    clock:advance(20)
    assert.are_not.equal("destroyed", protected.state)
    assert.are.equal(0, protected.hidden_since)
    assert.is_nil(protected._gc_timer)
    set_modified(protected, false)
    wait_for(function()
      clock:drain()
      return protected.state == "destroyed"
    end)
    assert.are.equal("destroyed", protected.state)

    local discarded = ready({ gc = { ttl_ms = 20, include_modified = true } })
    vim.api.nvim_buf_set_lines(discarded.bufnr, 0, -1, false, { "discard me" })
    set_modified(discarded, true)
    clock:advance(20)
    assert.are.equal("destroyed", discarded.state)
  end)

  it("migrates GC membership and metadata without resetting the hidden TTL interval", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 100, groups = { default = 0, project = 0 },
    } })
    local instance = ready()
    local timer = instance._gc_timer
    local generation = instance._gc_generation
    local hidden_since = instance.hidden_since
    clock:advance(25)

    assert.are.equal(instance, instance:setGroup("project"))
    assert.is_nil(manager_module.default.groups.default.instances[instance.id])
    assert.are.equal(instance, manager_module.default.groups.project.instances[instance.id])
    assert.are.equal("project", instance.config.gc.group)
    assert.are.equal("project", vim.b[instance.bufnr].fre.gc_group)
    assert.is_true(manager_module.default:is_gc_eligible(instance))
    assert.are.equal(timer, instance._gc_timer)
    assert.are.equal(generation, instance._gc_generation)
    assert.are.equal(hidden_since, instance.hidden_since)

    assert.are.equal(instance, instance:setGroup("project"))
    assert.are.equal(timer, instance._gc_timer)
    assert.are.equal(generation, instance._gc_generation)
    assert.are.equal(hidden_since, instance.hidden_since)

    clock:advance(74)
    assert.are_not.equal("destroyed", instance.state)
    clock:advance(1)
    assert.are.equal("destroyed", instance.state)
    assert.is_nil(manager_module.default.groups.project.instances[instance.id])
  end)

  it("atomically rejects invalid and unregistered group migrations", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 100, groups = { default = 0, project = 0 },
    } })
    local instance = ready()
    local timer = instance._gc_timer
    local generation = instance._gc_generation
    local hidden_since = instance.hidden_since
    local metadata = vim.b[instance.bufnr].fre

    for _, invalid in ipairs({ false, 1, {}, "" }) do
      assert_error_contains(function() instance:setGroup(invalid) end,
        "group must be a non-empty string")
    end
    assert_error_contains(function() instance:setGroup("missing") end, "unknown GC group")

    assert.are.equal("default", instance.config.gc.group)
    assert.are.equal(instance, manager_module.default.groups.default.instances[instance.id])
    assert.is_nil(manager_module.default.groups.project.instances[instance.id])
    assert.are.same(metadata, vim.b[instance.bufnr].fre)
    assert.are.equal(timer, instance._gc_timer)
    assert.are.equal(generation, instance._gc_generation)
    assert.are.equal(hidden_since, instance.hidden_since)

    instance.manager:remove(instance)
    assert_error_contains(function() instance:setGroup("project") end, "not registered")
    assert.are.equal("default", instance.config.gc.group)
    assert.are.equal("default", vim.b[instance.bufnr].fre.gc_group)
  end)

  it("enforces target capacity while protecting the moved instance", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 0, project = 1 },
    } })
    local existing = ready({ gc = { group = "project" } })
    clock:advance(1)
    local moved = ready()

    moved:setGroup("project")

    assert.are.equal("destroyed", existing.state)
    assert.are_not.equal("destroyed", moved.state)
    assert.is_nil(manager_module.default.groups.default.instances[moved.id])
    assert.are.equal(moved, manager_module.default.groups.project.instances[moved.id])
    assert.are.equal("project", moved.config.gc.group)
    assert.are.equal("project", vim.b[moved.bufnr].fre.gc_group)
  end)

  it("rolls back migration when target capacity enforcement fails", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 100, groups = { default = 0, project = 1 },
    } })
    local existing = ready({ gc = { group = "project" } })
    clock:advance(1)
    local moved = ready()
    local timer = moved._gc_timer
    local generation = moved._gc_generation
    local hidden_since = moved.hidden_since
    local destroy = existing.destroy
    existing.destroy = function() error("injected target destroy failure") end

    local ok, err = pcall(moved.setGroup, moved, "project")
    existing.destroy = destroy
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected target destroy failure", 1, true))

    assert.are_not.equal("destroyed", existing.state)
    assert.are.equal(existing, manager_module.default.groups.project.instances[existing.id])
    assert.are.equal(moved, manager_module.default.groups.default.instances[moved.id])
    assert.is_nil(manager_module.default.groups.project.instances[moved.id])
    assert.are.equal("default", moved.config.gc.group)
    assert.are.equal("default", vim.b[moved.bufnr].fre.gc_group)
    assert.are.equal(timer, moved._gc_timer)
    assert.are.equal(generation, moved._gc_generation)
    assert.are.equal(hidden_since, moved.hidden_since)
  end)

  it("protects registration self and performs deterministic same-pass multi-eviction", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 1, project = 0 },
    } })
    local first = ready()
    clock:advance(1)
    local second = ready()
    assert.are.equal("destroyed", first.state)
    assert.are_not.equal("destroyed", second.state)

    second:destroy()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, include_modified = false,
      groups = { default = 2, project = 0 },
    } })
    local candidates = {}
    for index = 1, 3 do
      local instance = ready()
      candidates[index] = instance
      set_modified(instance, true)
      clock:drain()
      clock:advance(1)
    end
    for _, instance in ipairs(candidates) do set_modified(instance, false) end
    local newest = ready()
    assert.are.equal("destroyed", candidates[1].state)
    assert.are.equal("destroyed", candidates[2].state)
    assert.are_not.equal("destroyed", candidates[3].state)
    assert.are_not.equal("destroyed", newest.state)
    local members = manager_module.default:find_by_group("default")
    assert.are.equal(candidates[3], members[candidates[3].id])
    assert.are.equal(newest, members[newest.id])
  end)

  it("enforces setup capacity replacement and atomically rejects live group removal", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0,
      groups = { default = 0, project = 0, temporary = 0 },
    } })
    local oldest = ready({ gc = { group = "temporary" } })
    clock:advance(1)
    local newest = ready({ gc = { group = "temporary" } })
    local before_invalid = manager_module.default:get_setup_defaults()
    local before_capacity = manager_module.default.groups.temporary.capacity

    assert_error_contains(function()
      fre.setup({ columns = {}, gc = { groups = { default = 0, project = 0 } } })
    end, "cannot remove GC group")
    assert.are.same(before_invalid, manager_module.default:get_setup_defaults())
    assert.are.equal(before_capacity, manager_module.default.groups.temporary.capacity)
    assert.are.equal(oldest,
      manager_module.default.groups.temporary.instances[oldest.id])
    assert.are.equal(newest,
      manager_module.default.groups.temporary.instances[newest.id])

    fre.setup({ columns = {}, gc = {
      ttl_ms = 0,
      groups = { default = 0, project = 0, temporary = 1 },
    } })
    assert.are.equal("destroyed", oldest.state)
    assert.are_not.equal("destroyed", newest.state)
    assert.are.equal(1, manager_module.default.groups.temporary.capacity)

    newest:destroy()
    fre.setup({ columns = {}, gc = { groups = { default = 0, project = 0 } } })
    assert.is_nil(manager_module.default.groups.temporary)
  end)
end)
