local buffer = require("fre.instance.buffer")
local columns = require("fre.columns")
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
  local windows = {}
  for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
    windows[winid] = {
      cursor = vim.api.nvim_win_get_cursor(winid),
      view = vim.api.nvim_win_call(winid, vim.fn.winsaveview),
    }
  end
  local watcher_paths = instance.sync:watcher_paths()
  local watcher_handles = {}
  for _, watch_path in ipairs(watcher_paths) do
    watcher_handles[watch_path] = watcher:latest(watch_path)
  end
  local visible_columns = {}
  for _, descriptor in ipairs(instance.buffer.visible_columns) do
    visible_columns[#visible_columns + 1] = descriptor.id
  end
  return {
    tree = instance.tree,
    root_node = instance.tree.root,
    nodes_by_id = instance.tree.nodes_by_id,
    nodes_by_path = instance.tree.nodes_by_path,
    view = instance.buffer.view,
    text = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false),
    baseline = vim.deepcopy(instance.buffer.view.baseline),
    column_widths = vim.deepcopy(instance.buffer.view.column_widths),
    projection_generation = instance.buffer.view.projection_generation,
    projection_ranges = vim.deepcopy(instance.buffer.projection_ranges),
    row_extmarks = vim.deepcopy(instance.buffer.row_extmarks),
    render_cache = vim.deepcopy(instance.buffer.render_cache),
    hidden_columns = instance:get_hidden_columns(),
    visible_columns = visible_columns,
    pending_initial_cursor = vim.deepcopy(instance.buffer.pending_initial_cursor),
    extmarks = vim.api.nvim_buf_get_extmarks(instance.bufnr, -1, 0, -1, { details = true }),
    modified = vim.bo[instance.bufnr].modified,
    modifiable = vim.bo[instance.bufnr].modifiable,
    result = vim.deepcopy(instance.sync:result_value()),
    tree_generation = instance.sync.tree_generation,
    real_root = instance.sync:real_root_value(),
    watcher_paths = watcher_paths,
    watcher_handles = watcher_handles,
    windows = windows,
    focused_tab = vim.api.nvim_get_current_tabpage(),
    focused_window = vim.api.nvim_get_current_win(),
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
  assert.are.same(expected.column_widths, instance.buffer.view.column_widths)
  assert.are.equal(expected.projection_generation, instance.buffer.view.projection_generation)
  assert.are.same(expected.projection_ranges, instance.buffer.projection_ranges)
  assert.are.same(expected.row_extmarks, instance.buffer.row_extmarks)
  assert.are.same(expected.render_cache, instance.buffer.render_cache)
  assert.are.same(expected.hidden_columns, instance:get_hidden_columns())
  local visible_columns = {}
  for _, descriptor in ipairs(instance.buffer.visible_columns) do
    visible_columns[#visible_columns + 1] = descriptor.id
  end
  assert.are.same(expected.visible_columns, visible_columns)
  assert.are.same(expected.pending_initial_cursor, instance.buffer.pending_initial_cursor)
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, -1, 0, -1, { details = true }))
  assert.are.equal(expected.modified, vim.bo[instance.bufnr].modified)
  assert.are.equal(expected.modifiable, vim.bo[instance.bufnr].modifiable)
  assert.are.same(expected.result, instance.sync:result_value())
  assert.are.equal(expected.tree_generation, instance.sync.tree_generation)
  assert.are.equal(expected.real_root, instance.sync:real_root_value())
  assert.are.same(expected.watcher_paths, instance.sync:watcher_paths())
  for watch_path, handle in pairs(expected.watcher_handles) do
    assert.are.equal(handle, watcher:latest(watch_path))
    assert.is_false(handle.closed)
  end
  assert.are.equal(expected.focused_tab, vim.api.nvim_get_current_tabpage())
  assert.are.equal(expected.focused_window, vim.api.nvim_get_current_win())
  assert.are.equal(vim.tbl_count(expected.windows), #vim.fn.win_findbuf(instance.bufnr))
  for winid, saved in pairs(expected.windows) do
    assert.is_true(vim.api.nvim_win_is_valid(winid))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(winid))
    assert.are.same(saved.cursor, vim.api.nvim_win_get_cursor(winid))
    assert.are.same(saved.view, vim.api.nvim_win_call(winid, vim.fn.winsaveview))
  end
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
    fre._reset_mutation_adapter()
  end)

  after_each(function()
    vim.notify = original_notify
    for _, instance in ipairs(instances) do
      if instance:status() ~= "destroyed" then pcall(instance.destroy, instance) end
    end
    fre._reset_fs_adapter()
    fre._reset_watch_adapter()
    fre._reset_mutation_adapter()
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

  it("batches sibling ready paths into one targeted projection", function()
    local instance = ready({ ["a/old.txt"] = "a", ["b/old.txt"] = "b" })
    instance:expand("a")
    instance:expand("b")
    wait_idle(instance)
    instance:open()
    local a = fixture:path("a")
    local b = fixture:path("b")
    local counts = loader_counts()
    local projection_generation = instance.buffer.view.projection_generation

    fixture:write("a/new.txt", "a")
    fixture:write("b/new.txt", "b")
    watcher:emit(a, nil, "untrusted-a")
    watcher:emit(b, nil, "untrusted-b")
    watcher:fire(a)
    watcher:fire(b)
    wait_for(function()
      return instance:get_pos("a/new.txt") ~= nil
        and instance:get_pos("b/new.txt") ~= nil
        and not instance.sync:is_busy() and not instance.sync:is_dirty()
    end)

    assert.is_nil(counts[instance.root])
    assert.are.equal(1, counts[a])
    assert.are.equal(1, counts[b])
    assert.are.equal(projection_generation + 1,
      instance.buffer.view.projection_generation)
  end)


  it("retains every batched path when a later directory scan fails", function()
    local notices = {}
    vim.notify = function(message) notices[#notices + 1] = tostring(message) end
    local instance = ready({ ["a/old.txt"] = "a", ["b/old.txt"] = "b" })
    instance:expand("a")
    instance:expand("b")
    wait_idle(instance)
    instance:open()
    local a = fixture:path("a")
    local b = fixture:path("b")
    local counts = {}
    local fail_b = true
    active_load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      if scan_path == b and fail_b then
        done("batched second scan exploded")
      else
        real_fs.load(scan_path, done)
      end
    end
    fixture:write("a/new.txt", "a")
    fixture:write("b/new.txt", "b")
    local before = snapshot(instance)
    watcher:emit(a, nil, "ignored-a")
    watcher:emit(b, nil, "ignored-b")
    watcher:fire(a)
    watcher:fire(b)
    wait_for(function()
      return #notices == 1 and not instance.sync:is_busy()
        and instance.sync:is_dirty()
    end)
    assert.is_truthy(notices[1]:find("batched second scan exploded", 1, true))
    assert.are.equal(1, counts[a])
    assert.are.equal(1, counts[b])
    assert_snapshot(instance, before)

    fail_b = false
    watcher:emit(a, nil, "retry-a")
    watcher:fire(a)
    wait_for(function()
      return instance:get_pos("a/new.txt") ~= nil
        and instance:get_pos("b/new.txt") ~= nil
        and not instance.sync:is_busy() and not instance.sync:is_dirty()
    end)
    assert.is_nil(counts[instance.root])
    assert.are.equal(2, counts[a])
    assert.are.equal(2, counts[b])
    assert.are.equal(before.projection_generation + 1,
      instance.buffer.view.projection_generation)
  end)


  it("revalidates child targets after shallow parent reconciliation", function()
    local instance = ready({ ["a/b/old.txt"] = "old" })
    instance:expand("a/b")
    wait_idle(instance)
    instance:open()
    local parent = fixture:path("a")
    local child = fixture:path("a", "b")
    local order = {}
    active_load = function(scan_path, done)
      order[#order + 1] = scan_path
      real_fs.load(scan_path, done)
    end

    fixture:write("a/b/new.txt", "new")
    watcher:emit(parent, nil, "ignored-parent")
    watcher:emit(child, nil, "ignored-child")
    watcher:fire(parent)
    watcher:fire(child)
    wait_for(function()
      return instance:get_pos("a/b/new.txt") ~= nil
        and not instance.sync:is_busy() and not instance.sync:is_dirty()
    end)
    assert.are.same({ parent, child }, order)

    order = {}
    local old_child_handle = watcher:latest(child)
    fs.remove_tree(child)
    watcher:emit(parent, nil, "ignored-parent")
    watcher:emit(child, nil, "ignored-child")
    watcher:fire(parent)
    watcher:fire(child)
    wait_for(function()
      return instance.tree.nodes_by_path[child] == nil
        and not instance.sync:is_busy() and not instance.sync:is_dirty()
    end)
    assert.are.same({ parent }, order)
    assert.is_true(old_child_handle.closed)
    assert.is_nil(watcher:latest(child))
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
      return counts[a] == 1 and counts[b] == 1
        and instance:get_pos("a/new.txt") ~= nil
        and instance:get_pos("b/new.txt") ~= nil
        and not instance.sync:is_dirty()
        and not instance.sync:is_busy()
    end)

    vim.wait(40, function() return false end, 10)
    assert.is_false(instance.sync:is_followup_scheduled())
    assert.is_nil(counts[instance.root])
    assert.are.equal(1, counts[a])
    assert.are.equal(1, counts[b])
    assert.are.equal(a_handle, watcher:latest(a))
    assert.are.equal(b_handle, watcher:latest(b))
    assert.is_false(a_handle.closed)
    assert.is_false(b_handle.closed)
  end)

  it("skips projection and cache mutation for an exact no-change event", function()
    local calls = 0
    local descriptor = columns.custom({
      id = "stable", metadata = {},
      render = function(entry) calls = calls + 1; return entry.name end,
      parse = function(suffix)
        local value, rest = suffix:match("^(%S+)%s+(.*)$")
        return value, rest
      end,
      equals = function() return true end,
    })
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" }, {
      columns = { descriptor },
    })
    instance:open()
    calls = 0
    local counts = loader_counts()
    local root_node = instance.tree.root
    local nodes_by_id = instance.tree.nodes_by_id
    local nodes_by_path = instance.tree.nodes_by_path
    local a_node = instance.tree.nodes_by_path[fixture:path("a.txt")]
    local view = instance.buffer.view
    local render_cache = instance.buffer.render_cache
    local projection_generation = view.projection_generation
    local tree_generation = instance.sync.tree_generation
    local root_handle = watcher:latest(instance.root)

    watcher:emit(instance.root, nil, "untrusted-name.txt")
    watcher:fire(instance.root)
    wait_for(function()
      return counts[instance.root] == 1 and not instance.sync:is_busy()
        and not instance.sync:is_dirty()
    end)

    assert.are.equal(0, calls)
    assert.are.equal(root_node, instance.tree.root)
    assert.are.equal(nodes_by_id, instance.tree.nodes_by_id)
    assert.are.equal(nodes_by_path, instance.tree.nodes_by_path)
    assert.are.equal(a_node, instance.tree.nodes_by_path[fixture:path("a.txt")])
    assert.are.equal(view, instance.buffer.view)
    assert.are.equal(render_cache, instance.buffer.render_cache)
    assert.are.equal(projection_generation, instance.buffer.view.projection_generation)
    assert.are.equal(tree_generation, instance.sync.tree_generation)
    assert.are.equal(root_handle, watcher:latest(instance.root))
    assert.is_false(root_handle.closed)
  end)


  it("publishes a changed watched-root canonical path", function()
    local instance = ready({ ["a.txt"] = "a" })
    instance:open()
    local replacement = instance.sync:real_root_value() .. "-retargeted"
    active_load = function(scan_path, done)
      real_fs.load(scan_path, function(err, children)
        done(err, children, replacement)
      end)
    end
    local tree_generation = instance.sync.tree_generation
    watcher:emit(instance.root, nil, "ignored")
    watcher:fire(instance.root)
    wait_for(function()
      return instance.sync.tree_generation == tree_generation + 1
        and not instance.sync:is_busy() and not instance.sync:is_dirty()
    end)
    assert.are.equal(replacement, instance.sync:real_root_value())
    assert.are.equal(replacement, instance.tree.root.real_path)
  end)

  it("restores a renamed-entry cursor through the detached candidate Tree", function()
    local descriptor = columns.custom({
      id = "wide", metadata = {},
      render = function(entry)
        return entry.name == "selected.txt" and string.rep("W", 40) or "x"
      end,
      parse = function(suffix)
        local value, rest = suffix:match("^(%S+)%s+(.*)$")
        return value, rest
      end,
      equals = function() return true end,
    })
    local instance = ready({ ["selected.txt"] = "selected" }, {
      columns = { descriptor },
    })
    instance:open()
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(winid, instance:get_pos("selected.txt"))
    local renamed = "renamed.txt"
    local ok, rename_err = vim.uv.fs_rename(
      fixture:path("selected.txt"), fixture:path(renamed)
    )
    assert.is_truthy(ok, tostring(rename_err))
    watcher:emit(instance.root, nil, "ignored")
    watcher:fire(instance.root)
    wait_for(function()
      return instance:get_pos(renamed) ~= nil
        and not instance.sync:is_busy() and not instance.sync:is_dirty()
    end)
    assert.are.same(instance:get_pos(renamed), vim.api.nvim_win_get_cursor(winid))
  end)


  it("invalidates only new or metadata-dependent entry-column pairs", function()
    local calls = {}
    local function descriptor(id, declaration, field)
      local opts = {
        id = id,
        render = function(entry, ctx)
          calls[id] = calls[id] or {}
          calls[id][entry.name] = (calls[id][entry.name] or 0) + 1
          local metadata = ctx.metadata or {}
          local mtime = metadata.mtime or {}
          local value = metadata[field] or mtime.sec or "none"
          return id .. ":" .. tostring(value) .. ":" .. entry.name
        end,
        parse = function(suffix)
          local value, rest = suffix:match("^(%S+)%s+(.*)$")
          return value, rest
        end,
        equals = function() return true end,
      }
      if declaration then opts[declaration] = field and { field } or {} end
      return columns.custom(opts)
    end
    local descriptors = {
      descriptor("kind", "metadata", "kind"),
      descriptor("mode", "metadata", "mode"),
      descriptor("size", "metadata", "size"),
      descriptor("mtime", "metadata", "mtime"),
      descriptor("empty", "metadata", nil),
      descriptor("legacy", "requires", "size"),
      descriptor("undeclared", nil, nil),
      descriptor("hidden", "metadata", "size"),
    }
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" }, {
      columns = descriptors, hidden_columns = { "hidden" },
    })
    instance:open()
    instance:show_columns({ "hidden" })
    instance:hide_columns({ "hidden" })
    calls = {}

    local overrides = {}
    active_load = function(scan_path, done)
      real_fs.load(scan_path, function(err, children, real_path)
        for _, entry in ipairs(children or {}) do
          local override = overrides[entry.name]
          if override then
            entry.stat = vim.deepcopy(entry.stat or {})
            if override.mode ~= nil then entry.stat.mode = override.mode end
            if override.size ~= nil then entry.stat.size = override.size end
            if override.mtime ~= nil then entry.stat.mtime = vim.deepcopy(override.mtime) end
          end
        end
        done(err, children, real_path)
      end)
    end
    local function trigger()
      local generation = instance.sync.tree_generation
      watcher:emit(instance.root, nil, "ignored")
      watcher:fire(instance.root)
      wait_for(function()
        return instance.sync.tree_generation == generation + 1
          and not instance.sync:is_busy() and not instance.sync:is_dirty()
      end)
    end

    local a = instance.tree.nodes_by_path[fixture:path("a.txt")]
    overrides["a.txt"] = { size = (a.stat.size or 0) + 100 }
    trigger()
    assert.are.same({
      size = { ["a.txt"] = 1 },
      legacy = { ["a.txt"] = 1 },
      undeclared = { ["a.txt"] = 1 },
    }, calls)

    calls = {}
    instance:show_columns({ "hidden" })
    assert.are.same({ hidden = { ["a.txt"] = 1 } }, calls)
    instance:hide_columns({ "hidden" })
    calls = {}

    local b = instance.tree.nodes_by_path[fixture:path("b.txt")]
    overrides["b.txt"] = { mode = (b.mode or 0) + 1 }
    trigger()
    assert.are.same({
      mode = { ["b.txt"] = 1 },
      undeclared = { ["b.txt"] = 1 },
    }, calls)

    calls = {}
    a = instance.tree.nodes_by_path[fixture:path("a.txt")]
    overrides["a.txt"].mtime = {
      sec = (a.mtime.sec or 0) + 1, nsec = (a.mtime.nsec or 0) + 1,
    }
    trigger()
    assert.are.same({
      mtime = { ["a.txt"] = 1 },
      undeclared = { ["a.txt"] = 1 },
    }, calls)

    calls = {}
    local long_name = "00-a-new-entry-with-a-wide-column.txt"
    fixture:write(long_name, "new")
    local a_id = instance.tree.nodes_by_path[fixture:path("a.txt")].id
    local b_id = instance.tree.nodes_by_path[fixture:path("b.txt")].id
    trigger()
    local new_calls = {}
    for _, id in ipairs({ "kind", "mode", "size", "mtime", "empty", "legacy", "undeclared" }) do
      new_calls[id] = { [long_name] = 1 }
    end
    assert.are.same(new_calls, calls)
    assert.are.equal(a_id, instance.tree.nodes_by_path[fixture:path("a.txt")].id)
    assert.are.equal(b_id, instance.tree.nodes_by_path[fixture:path("b.txt")].id)

    calls = {}
    fs.remove_tree(fixture:path("b.txt"))
    trigger()
    assert.are.same({}, calls)
    assert.is_nil(instance.buffer.render_cache[b_id])

    calls = {}
    local renamed = "zz-renamed.txt"
    local ok, rename_err = vim.uv.fs_rename(fixture:path("a.txt"), fixture:path(renamed))
    assert.is_truthy(ok, tostring(rename_err))
    overrides[renamed] = overrides["a.txt"]
    overrides["a.txt"] = nil
    trigger()
    local renamed_calls = {}
    for _, id in ipairs({ "kind", "mode", "size", "mtime", "empty", "legacy", "undeclared" }) do
      renamed_calls[id] = { [renamed] = 1 }
    end
    assert.are.same(renamed_calls, calls)
    assert.is_nil(instance.tree.nodes_by_path[fixture:path("a.txt")])
    assert.is_nil(instance.buffer.render_cache[a_id])
    assert.are_not.equal(a_id, instance.tree.nodes_by_path[fixture:path(renamed)].id)
  end)


  it("rolls back targeted watch failures without replacing published state", function()
    local render_epoch = 0
    local explode_render = false
    local value = columns.custom({
      id = "value", metadata = {},
      render = function(entry)
        if explode_render then error("watch render exploded") end
        return entry.name .. ":" .. render_epoch
      end,
      parse = function(suffix)
        local parsed, rest = suffix:match("^(%S+)%s+(.*)$")
        return parsed, rest
      end,
      equals = function() return true end,
    })
    local icon = columns.icon({
      provider = function() return "X", "FreWatchFailureIcon" end,
    })
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" }, {
      columns = { icon, value },
    })
    instance:open()
    local first = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(first, instance:get_pos("a.txt"))
    vim.api.nvim_win_call(first, function() vim.cmd("normal! zt") end)
    vim.cmd("tabnew")
    instance:open()
    local second = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(second, instance:get_pos("b.txt"))
    vim.api.nvim_win_call(second, function() vim.cmd("normal! zb") end)

    instance.sync:suspend_watchers()
    for index = 1, 30 do
      fixture:write(string.format("00-watch-%02d.txt", index), tostring(index))
    end
    instance.sync:sync_watchers()
    local messages = {}
    vim.notify = function(message) messages[#messages + 1] = tostring(message) end

    local function failed_watch(expected, setup, cleanup)
      render_epoch = render_epoch + 1
      if setup then setup() end
      local before = snapshot(instance)
      local message_count = #messages
      watcher:emit(instance.root, nil, "ignored")
      watcher:fire(instance.root)
      wait_for(function()
        return not instance.sync:is_busy() and instance.sync:is_dirty()
          and #messages > message_count
      end)
      if cleanup then cleanup() end
      assert.is_truthy(messages[#messages]:find(expected, 1, true), messages[#messages])
      assert_snapshot(instance, before)
      instance.sync.dirty = false
    end

    local original_load = active_load
    failed_watch("watch scan exploded", function()
      active_load = function(_, done) done("watch scan exploded") end
    end, function() active_load = original_load end)

    local original_sort = instance.tree:get_comparator()
    failed_watch("watch sort exploded", function()
      instance.tree:set_comparator(function() error("watch sort exploded") end)
    end, function() instance.tree:set_comparator(original_sort) end)

    failed_watch("watch render exploded", function() explode_render = true end,
      function() explode_render = false end)

    local original_prepare = buffer.prepare_watch_projection
    failed_watch("watch prepare exploded", function()
      buffer.prepare_watch_projection = function() error("watch prepare exploded") end
    end, function() buffer.prepare_watch_projection = original_prepare end)

    local original_set_extmark = vim.api.nvim_buf_set_extmark
    local row_extmark_injected = false
    failed_watch("watch row extmark exploded", function()
      vim.api.nvim_buf_set_extmark = function(bufnr, namespace, row, col, opts)
        if not row_extmark_injected and namespace == buffer.namespace then
          row_extmark_injected = true
          error("watch row extmark exploded")
        end
        return original_set_extmark(bufnr, namespace, row, col, opts)
      end
    end, function() vim.api.nvim_buf_set_extmark = original_set_extmark end)
    assert.is_true(row_extmark_injected)

    local highlight_injected = false
    failed_watch("watch highlight exploded", function()
      vim.api.nvim_buf_set_extmark = function(bufnr, namespace, row, col, opts)
        if not highlight_injected and opts and opts.hl_group == "FreWatchFailureIcon" then
          highlight_injected = true
          error("watch highlight exploded")
        end
        return original_set_extmark(bufnr, namespace, row, col, opts)
      end
    end, function() vim.api.nvim_buf_set_extmark = original_set_extmark end)
    assert.is_true(highlight_injected)

    instance.buffer.pending_initial_cursor[second] = true
    local original_place_initial_cursor = buffer.place_initial_cursor
    local late_commit_injected = false
    failed_watch("watch late commit exploded", function()
      buffer.place_initial_cursor = function()
        late_commit_injected = true
        error("watch late commit exploded")
      end
    end, function() buffer.place_initial_cursor = original_place_initial_cursor end)
    assert.is_true(late_commit_injected)
    instance.buffer.pending_initial_cursor[second] = nil
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
      vim.wait(20, function() return false end, 5)
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

  it("runs the pending targeted refresh on presentation without Manager registration", function()
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
        and not instance.sync:is_busy()
    end)

    assert.are.equal("ready", instance:status())
    assert.are.equal(1, counts[instance.root])
    assert.is_nil(counts[fixture:path("dir")])
    assert.is_nil(instance:get_pos("dir/new.txt"))
  end)

  it("keeps watcher paths pending without scanning during direct execution", function()
    local mutation_done
    fre._set_mutation_adapter({
      create_file = function(_, done) mutation_done = done end,
      create_directory = function(_, done) mutation_done = done end,
      copy = function(_, _, _, done) mutation_done = done end,
      move = function(_, _, done) mutation_done = done end,
      delete = function(_, _, done) mutation_done = done end,
    })
    local instance = ready({ ["dir/old.txt"] = "old" })
    instance:expand("dir")
    wait_idle(instance)
    instance:open()
    local directory = fixture:path("dir")
    local counts = loader_counts()
    local execution = instance:execute({ operations = {
      { type = "create_file", path = fixture:path("execution-placeholder") },
    } })
    assert.are.equal("running", execution:get_status().state)
    wait_for(function() return mutation_done ~= nil end)

    fixture:write("dir/during-execution.txt", "new")
    watcher:emit(directory, nil, "ignored")
    watcher:fire(directory)
    wait_for(function() return instance.sync:is_dirty() end)
    vim.wait(40, function() return false end, 10)
    assert.is_nil(counts[instance.root])
    assert.is_nil(counts[directory])
    assert.is_nil(instance:get_pos("dir/during-execution.txt"))
    assert.are.equal("running", execution:get_status().state)

    mutation_done(nil)
    wait_for(function()
      return execution:get_status().state == "succeeded"
        and instance:get_pos("dir/during-execution.txt") ~= nil
        and not instance.sync:is_busy() and not instance.sync:is_dirty()
    end)
    assert.is_nil(counts[instance.root])
    assert.are.equal(1, counts[directory])
  end)

  it("lets full refresh and write consume only their starting pending paths", function()
    local function exercise(mode)
      local directory_name = mode .. "-dir"
      local instance = ready({ [directory_name .. "/old.txt"] = "old" })
      instance:expand(directory_name)
      wait_idle(instance)
      instance:open()
      vim.cmd("enew")
      local directory = fixture:path(directory_name)
      local counts = loader_counts()
      fixture:write(directory_name .. "/pending.txt", "pending")
      watcher:emit(instance.root, nil, "ignored-root")
      watcher:emit(directory, nil, "ignored-directory")
      watcher:fire(instance.root)
      watcher:fire(directory)
      wait_for(function() return instance.sync:is_dirty() end)

      if mode == "public" then
        assert.is_nil(complete_refresh(instance))
      else
        local request = instance.work:_acquire_write()
        local completed, reconciliation_error = false, nil
        instance.sync:write_reconcile(function(_, finish)
          finish(nil, true)
        end, function(_, err)
          reconciliation_error = err
          assert.is_true(instance.work:_release_write(request))
          completed = true
        end)
        wait_for(function() return completed end)
        assert.is_nil(reconciliation_error)
      end
      assert.are.equal(1, counts[instance.root])
      assert.are.equal(1, counts[directory])
      assert.is_false(instance.sync:is_dirty())

      instance:open()
      local later = mode .. "-later.txt"
      fixture:write(later, "later")
      watcher:emit(instance.root, nil, "ignored-later")
      watcher:fire(instance.root)
      wait_for(function()
        return instance:get_pos(later) ~= nil
          and not instance.sync:is_busy() and not instance.sync:is_dirty()
      end)
      assert.are.equal(2, counts[instance.root])
      assert.are.equal(1, counts[directory])
      instance:destroy()
    end

    exercise("public")
    exercise("write")
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
    assert.are.equal(1, counts[directory])
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
    assert.are.equal(1, counts[directory])
    assert.is_false(instance.work:is_write_active())
  end)

  it("rescans failed watcher paths once and recreates only active handles", function()
    local notices = {}
    vim.notify = function(message) notices[#notices + 1] = tostring(message) end
    local instance = ready({ ["a/b/old.txt"] = "old" })
    instance:expand("a/b")
    wait_idle(instance)
    instance:open()
    local counts = loader_counts()

    local failed_root = watcher:latest(instance.root)
    failed_root.callback("root watch exploded", "ignored", {})
    wait_for(function()
      return #notices == 1 and not instance.sync:is_busy()
        and not instance.sync:is_dirty()
    end)
    local replacement = watcher:latest(instance.root)
    assert.is_true(failed_root.closed)
    assert.are.equal(1, counts[instance.root])
    assert.is_not_nil(replacement)
    assert.are_not.equal(failed_root, replacement)

    counts = loader_counts()
    local child = fixture:path("a", "b")
    local failed_child = watcher:latest(child)
    failed_child.callback("child watch exploded", "ignored", {})
    instance:collapse("a")
    wait_for(function()
      return #notices == 2 and not instance.sync:is_busy()
        and not instance.sync:is_dirty()
    end)
    assert.is_true(failed_child.closed)
    assert.is_nil(counts[child])
    assert.is_nil(watcher:latest(child))
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
