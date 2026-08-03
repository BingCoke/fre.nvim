local buffer = require("fre.instance.buffer")
local fre = require("fre")
local path = require("fre.path")
local real_fs = require("fre.fs").default
local fs = require("tests.helpers.fs")

local fixture
local instances = {}
local watcher
local original_notify
local active_load
local fs_adapter

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate, timeout)
  assert.is_true(vim.wait(timeout or 3000, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function()
    return instance:status() == "ready"
      or instance:status() == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance:status(), tostring(instance:failure()))
  return instance
end

local function ready(entries, opts)
  fixture:tree(entries or {})
  opts = vim.tbl_extend("force", { root = fixture.root, columns = {} }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function wait_idle(instance)
  wait_for(function()
    if instance.sync:is_busy() then return false end
    for _, node in pairs(instance.tree.nodes_by_id) do
      if node.kind == "directory"
          and (node.load_state == "loading" or node.load_state == "refreshing") then
        return false
      end
    end
    return true
  end)
end

local function complete_refresh(instance, opts)
  local done, completion_error = false, nil
  opts = vim.tbl_extend("force", opts or {}, { on_complete = function(err)
    completion_error = err
    done = true
  end })
  instance:refresh(opts)
  wait_for(function() return done end)
  return completion_error
end

local function projected_paths(instance)
  local result = {}
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(instance.buffer:decode(row))
    if decoded.row_kind == "entry" then result[#result + 1] = decoded.path end
  end
  return result
end

local function fake_watcher()
  local adapter = {
    debounce_ms = 20,
    handles = {},
    timers = {},
  }

  function adapter.new_fs_event()
    local handle = { kind = "event", closed = false, stop_count = 0, close_count = 0 }
    adapter.handles[#adapter.handles + 1] = handle
    adapter.pending_handle = handle
    return handle
  end

  function adapter.fs_event_start(handle, watch_path, callback)
    handle.path = watch_path
    handle.callback = callback
    handle.started = true
    return true
  end

  function adapter.new_timer()
    local timer = {
      kind = "timer", closed = false, stop_count = 0, close_count = 0,
      callbacks = {}, handle = adapter.pending_handle,
    }
    adapter.pending_handle.timer = timer
    adapter.pending_handle = nil
    adapter.timers[#adapter.timers + 1] = timer
    return timer
  end

  function adapter.timer_start(timer, timeout, callback)
    timer.timeout = timeout
    timer.callbacks[#timer.callbacks + 1] = callback
    return true
  end

  function adapter.timer_stop(timer)
    if timer then timer.stop_count = timer.stop_count + 1 end
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

  function adapter:latest(watch_path)
    for index = #self.handles, 1, -1 do
      local handle = self.handles[index]
      if handle.path == watch_path and not handle.closed then return handle end
    end
  end

  function adapter:emit(watch_path, err, filename)
    local handle = assert(self:latest(watch_path), "missing watcher for " .. watch_path)
    handle.callback(err, filename, {})
    return handle
  end

  function adapter:fire(watch_path, index)
    local handle = assert(self:latest(watch_path), "missing watcher for " .. watch_path)
    local callbacks = handle.timer.callbacks
    assert(callbacks[index or #callbacks], "missing debounce callback for " .. watch_path)()
    return handle
  end

  return adapter
end

local function loader_counts()
  local counts = {}
  active_load = function(scan_path, done)
    counts[scan_path] = (counts[scan_path] or 0) + 1
    real_fs.load(scan_path, done)
  end
  return counts
end

local function delayed_first_scans()
  local counts, pending = {}, {}
  active_load = function(scan_path, done)
    counts[scan_path] = (counts[scan_path] or 0) + 1
    if counts[scan_path] == 1 then
      pending[scan_path] = done
    else
      real_fs.load(scan_path, done)
    end
  end
  local function complete(scan_path)
    local done = assert(pending[scan_path], "missing pending scan for " .. scan_path)
    pending[scan_path] = nil
    real_fs.load(scan_path, done)
  end
  return counts, pending, complete
end

local function snapshot(instance)
  return {
    tree = instance.tree,
    root_node = instance.tree.root,
    nodes_by_id = instance.tree.nodes_by_id,
    nodes_by_path = instance.tree.nodes_by_path,
    view = instance.buffer.view,
    text = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false),
    baseline = vim.deepcopy(instance.buffer.view.baseline),
    projection_ranges = vim.deepcopy(instance.buffer.projection_ranges),
    row_extmarks = vim.deepcopy(instance.buffer.row_extmarks),
    extmarks = vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}),
    modified = vim.bo[instance.bufnr].modified,
    modifiable = vim.bo[instance.bufnr].modifiable,
  }
end

local function assert_snapshot(instance, expected)
  assert.are.equal(expected.tree, instance.tree)
  assert.are.equal(expected.root_node, instance.tree.root)
  assert.are.equal(expected.nodes_by_id, instance.tree.nodes_by_id)
  assert.are.equal(expected.nodes_by_path, instance.tree.nodes_by_path)
  assert.are.equal(expected.view, instance.buffer.view)
  assert.are.same(expected.text, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
  assert.are.same(expected.baseline, instance.buffer.view.baseline)
  assert.are.same(expected.projection_ranges, instance.buffer.projection_ranges)
  assert.are.same(expected.row_extmarks, instance.buffer.row_extmarks)
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}))
  assert.are.equal(expected.modified, vim.bo[instance.bufnr].modified)
  assert.are.equal(expected.modifiable, vim.bo[instance.bufnr].modifiable)
end

describe("fre ticket 15 directory watchers", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture = fs.new()
    instances = {}
    original_notify = vim.notify
    active_load = real_fs.load
    fs_adapter = { load = function(...) return active_load(...) end }
    fre._set_fs_adapter(fs_adapter)
    watcher = fake_watcher()
    fre._set_watch_adapter(watcher)
  end)

  after_each(function()
    vim.notify = original_notify
    for _, instance in ipairs(instances) do
      if instance:status() ~= "destroyed" then pcall(instance.destroy, instance) end
    end
    fre._reset_fs_adapter()
    fre._reset_watch_adapter()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture:cleanup()
  end)

  it("watches only root and active expanded ancestor chains", function()
    local instance = ready({ ["a/n/deep.txt"] = "x", ["b/other.txt"] = "y" })
    assert.are.equal(fs_adapter, instance.sync.fs_adapter)
    assert.are.equal(watcher, instance.sync.watch.adapter)
    assert.are.same({ instance.root }, instance.sync:watcher_paths())

    instance:expand("a/n")
    wait_for(function() return instance:get_pos("a/n/deep.txt") ~= nil end)
    wait_idle(instance)
    assert.are.same({ instance.root, path.resolve(instance.root, "a"),
      path.resolve(instance.root, "a/n") },
      instance.sync:watcher_paths())

    local root_handle = watcher:latest(instance.root)
    local a_handle = watcher:latest(path.resolve(instance.root, "a"))
    local nested_handle = watcher:latest(path.resolve(instance.root, "a/n"))
    assert.is_nil(complete_refresh(instance))
    assert.are.equal(root_handle, watcher:latest(instance.root))
    assert.are.equal(a_handle, watcher:latest(path.resolve(instance.root, "a")))
    assert.are.equal(nested_handle, watcher:latest(path.resolve(instance.root, "a/n")))
    assert.is_false(root_handle.closed)
    assert.is_false(a_handle.closed)
    assert.is_false(nested_handle.closed)
    instance:collapse("a")
    assert.are.same({ instance.root }, instance.sync:watcher_paths())
    assert.is_true(a_handle.closed)
    assert.is_true(nested_handle.closed)

    instance:expand("a")
    assert.are.same({ instance.root, path.resolve(instance.root, "a"),
      path.resolve(instance.root, "a/n") },
      instance.sync:watcher_paths())
    assert.are_not.equal(a_handle, watcher:latest(path.resolve(instance.root, "a")))
  end)

  it("collapse_all closes descendant watchers and makes their stale callbacks inert", function()
    local instance = ready({ ["a/n/deep.txt"] = "x", ["b/other.txt"] = "y" })
    instance:expand("a/n")
    instance:expand("b")
    wait_idle(instance)
    instance:open()
    local a = fixture:path("a")
    local n = fixture:path("a", "n")
    local b = fixture:path("b")
    local a_handle = watcher:latest(a)
    local n_handle = watcher:latest(n)
    local b_handle = watcher:latest(b)
    watcher:emit(a, nil, "old")
    local stale_timer = a_handle.timer.callbacks[#a_handle.timer.callbacks]
    local counts = loader_counts()

    instance:collapse_all()
    assert.are.same({ instance.root }, instance.sync:watcher_paths())
    for _, handle in ipairs({ a_handle, n_handle, b_handle }) do
      assert.is_true(handle.closed)
      assert.is_true(handle.timer.closed)
    end
    a_handle.callback(nil, "late", {})
    stale_timer()
    vim.wait(40, function() return false end, 10)
    assert.is_nil(counts[a])
    assert.is_nil(counts[n])
    assert.is_nil(counts[b])
    assert.is_false(instance.tree.nodes_by_path[a].expanded)
    assert.is_false(instance.tree.nodes_by_path[n].expanded)
    assert.is_false(instance.tree.nodes_by_path[b].expanded)

    instance:expand("a")
    assert.are.same({ instance.root, a }, instance.sync:watcher_paths())
    assert.are_not.equal(a_handle, watcher:latest(a))
    assert.is_false(instance.tree.nodes_by_path[n].expanded)
    wait_idle(instance)
    assert.are.same({ instance.root, a }, instance.sync:watcher_paths())
  end)

  it("follows canceled root watch refreshes after asynchronous projection changes and a no-op", function()
    local instance = ready({ ["dir/old.txt"] = "old" })
    instance:expand("dir")
    wait_idle(instance)
    instance:open()
    local counts, pending = {}, {}
    local dir_path = fixture:path("dir")
    local delay_next_root, delay_next_dir = false, false
    local pending_dir
    active_load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      if scan_path == instance.root and delay_next_root then
        delay_next_root = false
        pending[#pending + 1] = done
      elseif scan_path == dir_path and delay_next_dir then
        delay_next_dir = false
        pending_dir = done
      else
        real_fs.load(scan_path, done)
      end
    end

    local function start_delayed_root_watch(filename)
      fixture:write(filename, filename)
      delay_next_root = true
      watcher:emit(instance.root, nil, filename)
      watcher:fire(instance.root)
      wait_for(function()
        return pending[#pending] ~= nil and instance.sync:is_busy()
      end)
    end

    instance:collapse("dir")
    delay_next_dir = true
    start_delayed_root_watch("after-expand.txt")
    local first_stale = pending[1]
    instance:expand("dir")
    wait_for(function() return pending_dir ~= nil end)
    assert.is_true(instance.sync:is_dirty())
    real_fs.load(dir_path, pending_dir)
    wait_for(function()
      return instance:get_pos("after-expand.txt") ~= nil
        and not instance.sync:is_dirty()
        and not instance.sync:is_busy()
    end)

    start_delayed_root_watch("after-noop.txt")
    local second_stale = pending[2]
    instance:collapse_all()
    wait_for(function()
      return instance:get_pos("after-noop.txt") ~= nil
        and not instance.sync:is_dirty()
        and not instance.sync:is_busy()
        and not instance.sync:is_followup_scheduled()
    end)

    real_fs.load(instance.root, first_stale)
    real_fs.load(instance.root, second_stale)
    vim.wait(40, function() return false end, 10)
    assert.are.equal(4, counts[instance.root])
    assert.is_false(instance.sync:is_dirty())
    assert.is_false(instance.sync:is_busy())
  end)

  it("debounces each directory independently and ignores event filenames", function()
    local instance = ready({ ["a/old.txt"] = "a", ["b/old.txt"] = "b" })
    instance:expand("a")
    instance:expand("b")
    wait_idle(instance)
    instance:open()

    local a = fixture:path("a")
    local b = fixture:path("b")
    local counts, pending_a = {}, nil
    active_load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      if scan_path == a and counts[scan_path] == 1 then
        pending_a = done
      else
        real_fs.load(scan_path, done)
      end
    end

    fixture:write("a/new.txt", "a")
    fixture:write("b/new.txt", "b")
    local a_handle = watcher:emit(a, nil, "wrong-one")
    local b_handle = watcher:emit(b, nil, "wrong-two")
    watcher:emit(b, nil, "wrong-three")
    assert.are.equal(1, #a_handle.timer.callbacks)
    assert.are.equal(2, #b_handle.timer.callbacks)

    a_handle.timer.callbacks[1]()
    wait_for(function() return pending_a ~= nil end)
    assert.are.equal(1, counts[a])
    assert.is_nil(counts[b])

    local generation_after_a = instance.sync:watch_event_generation_value()
    b_handle.timer.callbacks[1]()
    vim.wait(30, function() return false end, 10)
    assert.are.equal(generation_after_a, instance.sync:watch_event_generation_value())
    b_handle.timer.callbacks[2]()
    wait_for(function()
      return instance.sync:watch_event_generation_value() == generation_after_a + 1
    end)
    assert.is_true(instance.sync:is_dirty())
    assert.is_nil(counts[b])

    local complete_a = pending_a
    pending_a = nil
    real_fs.load(a, complete_a)
    wait_for(function()
      return counts[instance.root] == 1 and counts[a] == 2 and counts[b] == 1
        and instance:get_pos("a/new.txt") ~= nil
        and instance:get_pos("b/new.txt") ~= nil
        and not instance.sync:is_dirty()
        and not instance.sync:is_busy()
    end)

    vim.wait(40, function() return false end, 10)
    assert.is_false(instance.sync:is_followup_scheduled())
    assert.are.equal(1, counts[instance.root])
    assert.are.equal(2, counts[a])
    assert.are.equal(1, counts[b])
    assert.are.equal(a_handle, watcher:latest(a))
    assert.are.equal(b_handle, watcher:latest(b))
    assert.is_false(a_handle.closed)
    assert.is_false(b_handle.closed)
  end)

  it("refreshes exactly the affected direct-child boundary atomically", function()
    local counts = loader_counts()
    local instance = ready({ ["a/old.txt"] = "a", ["b/old.txt"] = "b" })
    instance:expand("a")
    instance:expand("b")
    wait_idle(instance)
    instance:open()
    counts = loader_counts()
    local b_before = instance.tree.nodes_by_path[fixture:path("b", "old.txt")].id

    fixture:write("a/new.txt", "new")
    fixture:write("b/dormant.txt", "not scanned")
    watcher:emit(fixture:path("a"), nil, "b/dormant.txt")
    watcher:fire(fixture:path("a"))
    wait_for(function() return instance:get_pos("a/new.txt") ~= nil end)

    assert.are.equal(1, counts[fixture:path("a")])
    assert.is_nil(counts[fixture.root])
    assert.is_nil(counts[fixture:path("b")])
    assert.are.equal(b_before, instance.tree.nodes_by_path[fixture:path("b", "old.txt")].id)
    assert.is_nil(instance.tree.nodes_by_path[fixture:path("b", "dormant.txt")])
    assert.is_false(instance.sync:is_dirty())
  end)

  it("only marks pending while hidden, modified, or write-locked", function()
    local function exercise(make_unsafe, restore)
      local counts = loader_counts()
      local instance = ready({ ["old.txt"] = "old" })
      instance:open()
      make_unsafe(instance)
      counts = loader_counts()
      local before = snapshot(instance)
      watcher:emit(instance.root, nil, "new.txt")
      watcher:fire(instance.root)
      wait_for(function() return instance.sync:is_dirty() end)
      assert_snapshot(instance, before)
      assert.is_nil(counts[instance.root])
      if restore then restore(instance) end
      instance:destroy()
    end

    exercise(function(instance)
      vim.cmd("enew")
      assert.is_nil(fre.view.inspect(instance))
    end)
    exercise(function(instance)
      vim.bo[instance.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, { "draft" })
    end)
    local request
    exercise(function(instance) request = instance.work:_acquire_write() end,
      function(instance) instance.work:_release_write(request) end)
  end)

  it("performs one pending full refresh on presentation without Manager registration", function()
    local counts = loader_counts()
    local instance = ready({ ["dir/old.txt"] = "old" })
    instance:expand("dir")
    wait_idle(instance)
    counts = loader_counts()
    fixture:write("root-new.txt", "root")
    fixture:write("dir/new.txt", "new")

    watcher:emit(instance.root, nil, "ignored")
    watcher:fire(instance.root)
    wait_for(function() return instance.sync:is_dirty() end)
    local manager = require("fre.manager").default
    manager.instances_by_id[instance.id] = nil
    manager.instances_by_buf[instance.bufnr] = nil
    instance:open()
    instance:open()
    manager.instances_by_id[instance.id] = instance
    manager.instances_by_buf[instance.bufnr] = instance
    wait_for(function()
      return not instance.sync:is_dirty() and instance:get_pos("root-new.txt") ~= nil
        and instance:get_pos("dir/new.txt") ~= nil
    end)

    assert.are.equal("ready", instance:status())
    assert.are.equal(1, counts[instance.root])
    assert.are.equal(1, counts[fixture:path("dir")])
  end)

  it("follows a public refresh when an event arrives after its boundary scan", function()
    local instance = ready({ ["dir/old.txt"] = "old" })
    instance:expand("dir")
    wait_idle(instance)
    instance:open()
    local counts, pending, complete = delayed_first_scans()
    local callbacks, refresh_error, first_saw_late = 0, nil, nil
    instance:refresh({ on_complete = function(err)
      callbacks = callbacks + 1
      refresh_error = err
      first_saw_late = instance:get_pos("late.txt") ~= nil
    end })
    wait_for(function() return pending[instance.root] ~= nil end)
    complete(instance.root)
    local directory = fixture:path("dir")
    wait_for(function() return pending[directory] ~= nil end)

    fixture:write("late.txt", "late")
    local generation = instance.sync:watch_event_generation_value()
    watcher:emit(instance.root, nil, "ignored")
    watcher:fire(instance.root)
    wait_for(function() return instance.sync:watch_event_generation_value() > generation end)
    complete(directory)

    wait_for(function()
      return callbacks == 1 and not instance.sync:is_dirty()
        and instance:get_pos("late.txt") ~= nil and not instance.sync:is_busy()
    end)
    vim.wait(40, function() return false end, 10)
    assert.is_nil(refresh_error)
    assert.is_false(first_saw_late)
    assert.are.equal(1, callbacks)
    assert.are.equal(2, counts[instance.root])
    assert.are.equal(2, counts[directory])
  end)

  it("follows write reconciliation after a post-scan event and unlocks once", function()
    local instance = ready({ ["dir/old.txt"] = "old" })
    instance:expand("dir")
    wait_idle(instance)
    instance:open()
    local counts, pending, complete = delayed_first_scans()
    local request = instance.work:_acquire_write()
    local callbacks, reconciliation_error, first_saw_late = 0, nil, nil
    instance.sync:write_reconcile(function(_, finish)
      finish(nil, true)
    end, function(_, err)
      callbacks = callbacks + 1
      reconciliation_error = err
      first_saw_late = instance:get_pos("write-late.txt") ~= nil
      assert.is_true(instance.work:_release_write(request))
    end)
    wait_for(function() return pending[instance.root] ~= nil end)
    complete(instance.root)
    local directory = fixture:path("dir")
    wait_for(function() return pending[directory] ~= nil end)

    fixture:write("write-late.txt", "late")
    local generation = instance.sync:watch_event_generation_value()
    watcher:emit(instance.root, nil, "ignored")
    watcher:fire(instance.root)
    wait_for(function() return instance.sync:watch_event_generation_value() > generation end)
    complete(directory)

    wait_for(function()
      return callbacks == 1 and request.released and not instance.sync:is_dirty()
        and instance:get_pos("write-late.txt") ~= nil and not instance.sync:is_busy()
    end)
    vim.wait(40, function() return false end, 10)
    assert.is_nil(reconciliation_error)
    assert.is_false(first_saw_late)
    assert.are.equal(1, callbacks)
    assert.are.equal(2, counts[instance.root])
    assert.are.equal(2, counts[directory])
    assert.is_false(instance.work:is_write_active())
  end)

  it("reports each failed handle once, stops it, and recreates after refresh", function()
    local notices = {}
    vim.notify = function(message) notices[#notices + 1] = message end
    local instance = ready({ ["old.txt"] = "old" })
    local failed = watcher:latest(instance.root)
    failed.callback("watch exploded", "ignored", {})
    failed.callback("duplicate error", "ignored", {})
    wait_for(function() return #notices == 1 end)

    assert.is_true(failed.closed)
    assert.is_true(failed.timer.closed)
    assert.is_true(instance.sync:is_dirty())
    assert.is_nil(watcher:latest(instance.root))
    assert.is_truthy(notices[1]:find(instance.root, 1, true))
    assert.is_truthy(notices[1]:find("watch exploded", 1, true))

    assert.is_nil(complete_refresh(instance))
    local replacement = watcher:latest(instance.root)
    assert.is_not_nil(replacement)
    assert.are_not.equal(failed, replacement)
    assert.is_false(instance.sync:is_dirty())
    assert.are.equal(1, #notices)
  end)

  it("drops callbacks from collapse and destruction", function()
    local counts = loader_counts()
    local instance = ready({ ["dir/old.txt"] = "old" })
    instance:expand("dir")
    wait_idle(instance)
    instance:open()
    counts = loader_counts()

    local directory = fixture:path("dir")
    local collapsed = watcher:emit(directory, nil, "old")
    local collapsed_timer = collapsed.timer.callbacks[#collapsed.timer.callbacks]
    instance:collapse("dir")
    collapsed.callback(nil, "late", {})
    collapsed_timer()
    vim.wait(40, function() return false end, 10)
    assert.is_nil(counts[directory])


    local destroyed = watcher:emit(instance.root, nil, "old")
    local destroyed_timer = destroyed.timer.callbacks[#destroyed.timer.callbacks]
    instance:destroy()
    destroyed.callback(nil, "late", {})
    destroyed_timer()
    vim.wait(40, function() return false end, 10)
    assert.are.equal("destroyed", instance:status())
  end)

  it("commits a directory loader completion at most once", function()
    local instance = ready({ ["old.txt"] = "old" })
    instance:open()
    local pending, calls = nil, 0
    active_load = function(scan_path, done)
      assert.are.equal(instance.root, scan_path)
      calls = calls + 1
      pending = done
    end
    local generation = instance.buffer.view.projection_generation
    watcher:emit(instance.root, nil, "ignored")
    watcher:fire(instance.root)
    wait_for(function() return pending ~= nil end)
    pending(nil, {
      { name = "old.txt", kind = "file" },
      { name = "new.txt", kind = "file" },
    }, instance.root)
    pending(nil, { { name = "duplicate.txt", kind = "file" } }, instance.root)
    wait_for(function() return instance.buffer.view.projection_generation == generation + 1 end)
    vim.wait(30, function() return false end, 10)
    assert.are.equal(1, calls)
    assert.are.same({ "new.txt", "old.txt" }, projected_paths(instance))
    assert.are.equal(generation + 1, instance.buffer.view.projection_generation)
  end)

  it("recreates the active watcher set after write reconciliation", function()
    local instance = ready({ ["dir/old.txt"] = "old" })
    instance:expand("dir")
    wait_idle(instance)
    local previous_root = watcher:latest(instance.root)
    local previous_dir = watcher:latest(fixture:path("dir"))
    local request = instance.work:_acquire_write()
    assert.is_not_nil(watcher:latest(instance.root))
    local done, reconciliation_error = false, nil
    instance.sync:write_reconcile(function(execute)
      execute(function(finish)
        if path.is_windows(instance.root) then
          assert.are.same({}, instance.sync:watcher_paths())
        else
          assert.are.same({ instance.root, fixture:path("dir") }, instance.sync:watcher_paths())
        end
        finish(nil, true)
      end)
    end, function(_, err)
      reconciliation_error = err
      instance.work:_release_write(request)
      done = true
    end)
    wait_for(function() return done end)
    assert.is_nil(reconciliation_error)
    assert.are.same({ instance.root, fixture:path("dir") }, instance.sync:watcher_paths())
    if path.is_windows(instance.root) then
      assert.is_true(previous_root.closed)
      assert.is_true(previous_dir.closed)
      assert.are_not.equal(previous_root, watcher:latest(instance.root))
      assert.are_not.equal(previous_dir, watcher:latest(fixture:path("dir")))
    else
      assert.is_false(previous_root.closed)
      assert.is_false(previous_dir.closed)
      assert.are.equal(previous_root, watcher:latest(instance.root))
      assert.are.equal(previous_dir, watcher:latest(fixture:path("dir")))
    end
  end)


  it("closes every instance-owned event and timer", function()
    local instance = ready({ ["a/n/file.txt"] = "x" })
    instance:expand("a/n")
    wait_idle(instance)
    instance:collapse("a")
    instance:expand("a")
    wait_idle(instance)
    instance:destroy()

    for _, handle in ipairs(watcher.handles) do
      assert.is_true(handle.closed)
      assert.are.equal(1, handle.close_count)
    end
    for _, timer in ipairs(watcher.timers) do
      assert.is_true(timer.closed)
      assert.are.equal(1, timer.close_count)
    end
  end)

  it("observes one bounded real local fs event", function()
    fre._reset_watch_adapter()
    local instance = ready({ ["old.txt"] = "old" })
    instance:open()
    fixture:write("real-event.txt", "event")
    wait_for(function() return instance:get_pos("real-event.txt") ~= nil end, 5000)
    assert.is_false(instance.sync:is_dirty())
  end)
end)
