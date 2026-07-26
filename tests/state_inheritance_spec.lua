local buffer = require("fre.buffer")
local columns = require("fre.columns")
local fre = require("fre")
local inheritance = require("fre.inheritance")
local path = require("fre.path")
local real_fs = require("fre.fs").default
local fs = require("tests.helpers.fs")

local fixture
local instances = {}
local original_notify

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate, timeout)
  assert.is_true(vim.wait(timeout or 3000, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function()
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
end

local function wait_loaded(instance, relative)
  local absolute = path.resolve(instance.root, relative)
  wait_for(function()
    local node = instance.nodes_by_path[absolute]
    return node and node.loaded
  end)
  return instance.nodes_by_path[absolute]
end

local function counting_loader(failures)
  local counts = {}
  return {
    load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      if failures and failures[scan_path] then
        done(failures[scan_path])
      else
        real_fs.load(scan_path, done)
      end
    end,
  }, counts
end

local function deferred_loader()
  local pending = {}
  local counts = {}
  local adapter = {
    load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      real_fs.load(scan_path, function(...)
        local values = { n = select("#", ...), ... }
        pending[scan_path] = pending[scan_path] or {}
        pending[scan_path][#pending[scan_path] + 1] = function(override)
          if override then done(override) else done(unpack(values, 1, values.n)) end
        end
      end)
    end,
  }
  local function release(scan_path, index, override)
    index = index or 1
    wait_for(function() return pending[scan_path] and pending[scan_path][index] end)
    pending[scan_path][index](override)
  end
  return adapter, counts, pending, release
end

local function flatten(trie)
  local result = {}
  local function visit(node, prefix)
    local names = {}
    for name in pairs(node.children) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local child = node.children[name]
      local relative = prefix == "" and name or (prefix .. "/" .. name)
      result[relative] = child.desired
      visit(child, relative)
    end
  end
  visit(trie, "")
  return result
end

local function custom_column(id)
  return columns.custom({
    id = id,
    render = function() return id end,
    parse = function(suffix) return suffix:match("^(%S+)%s+(.*)$") end,
    equals = function() return true end,
  })
end

local function fake_watch_adapter()
  local adapter = { debounce_ms = 10, handles = {}, pending = nil }
  function adapter.new_fs_event()
    local handle = { closed = false }
    adapter.handles[#adapter.handles + 1] = handle
    adapter.pending = handle
    return handle
  end
  function adapter.fs_event_start(handle, watch_path, callback)
    handle.path, handle.callback = watch_path, callback
    return true
  end
  function adapter.new_timer()
    local timer = { closed = false }
    adapter.pending.timer = timer
    adapter.pending = nil
    return timer
  end
  function adapter.timer_start(_, _, _) return true end
  function adapter.timer_stop(_) return true end
  function adapter.close(resource) resource.closed = true; return true end
  function adapter.schedule(callback) vim.schedule(callback); return true end
  return adapter
end

local function atomic_state(instance)
  local result = {
    lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false),
    baseline = vim.deepcopy(instance.view.baseline),
    extmarks = vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}),
    column_widths = vim.deepcopy(instance.view.column_widths),
    projection_generation = instance.view.projection_generation,
    next_node_id = instance._next_node_id,
    nodes_by_id = {},
    nodes_by_path = {},
    visibility = {},
    visible_ids = {},
  }
  for id, node in pairs(instance.nodes_by_id) do
    result.nodes_by_id[id] = node
    result.visibility[id] = {
      node.visible_size, node.visible_start, node.visible_end,
      vim.deepcopy(node.visible_range), node.row_extmark,
    }
  end
  for node_path, node in pairs(instance.nodes_by_path) do
    result.nodes_by_path[node_path] = node
  end
  for _, node in ipairs(instance.view.visible_nodes) do
    result.visible_ids[#result.visible_ids + 1] = node.id
  end
  return result
end

local function assert_atomic_state(instance, expected)
  assert.are.same(expected.lines, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
  assert.are.same(expected.baseline, instance.view.baseline)
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}))
  assert.are.same(expected.column_widths, instance.view.column_widths)
  assert.are.equal(expected.projection_generation, instance.view.projection_generation)
  assert.are.equal(expected.next_node_id, instance._next_node_id)
  local id_count, path_count = 0, 0
  for id, node in pairs(instance.nodes_by_id) do
    id_count = id_count + 1
    assert.are.equal(expected.nodes_by_id[id], node)
    assert.are.same(expected.visibility[id], {
      node.visible_size, node.visible_start, node.visible_end,
      vim.deepcopy(node.visible_range), node.row_extmark,
    })
  end
  for node_path, node in pairs(instance.nodes_by_path) do
    path_count = path_count + 1
    assert.are.equal(expected.nodes_by_path[node_path], node)
  end
  assert.are.equal(vim.tbl_count(expected.nodes_by_id), id_count)
  assert.are.equal(vim.tbl_count(expected.nodes_by_path), path_count)
  local visible_ids = {}
  local line_count = vim.api.nvim_buf_line_count(instance.bufnr)
  for row, node in ipairs(instance.view.visible_nodes) do
    visible_ids[#visible_ids + 1] = node.id
    assert.is_true(row <= line_count)
    assert.are.equal(node, instance.nodes_by_id[node.id])
    assert.are.equal(row, node.visible_start)
    assert.is_not_nil(buffer.decode(instance, row))
  end
  assert.are.same(expected.visible_ids, visible_ids)
end

describe("fre ticket 18 state inheritance", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    original_notify = vim.notify
    vim.notify = function() end
    fre._reset_fs_adapter()
    fre._reset_watch_adapter()
    fre.setup({})
  end)

  after_each(function()
    vim.notify = original_notify
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then instance:destroy() end
    end
    fre._reset_fs_adapter()
    fre._reset_watch_adapter()
    fre.setup({})
    fixture:cleanup()
  end)

  it("captures cached expanded descendants behind a collapsed barrier and resumes them", function()
    fixture:tree({ ["a/b/c/leaf.txt"] = "x" })
    fre._set_watch_adapter(fake_watch_adapter())
    local predecessor = wait_ready(keep(fre.new({ root = fixture.root, columns = {} })))
    predecessor:expand("a/b/c")
    wait_for(function() return predecessor:get_pos("a/b/c/leaf.txt") ~= nil end)
    predecessor:collapse("a")
    assert.is_true(predecessor.nodes_by_path[fixture:path("a", "b")].expanded)

    local adapter, counts = counting_loader()
    fre._set_fs_adapter(adapter)
    local child = wait_ready(keep(fre.new({
      root = fixture.root, inherit = predecessor, columns = {},
    })))
    vim.wait(40, function() return false end, 10)
    assert.is_false(child.nodes_by_path[fixture:path("a")].expanded)
    assert.is_nil(counts[fixture:path("a")])
    assert.is_nil(child.nodes_by_path[fixture:path("a", "b")])
    assert.are.same({ child.root }, child._watchers:paths())

    child:expand("a")
    wait_for(function() return child:get_pos("a/b/c/leaf.txt") ~= nil end)
    assert.are.equal(1, counts[fixture:path("a")])
    assert.are.equal(1, counts[fixture:path("a", "b")])
    assert.are.equal(1, counts[fixture:path("a", "b", "c")])
    assert.are.same({
      child.root, fixture:path("a"), fixture:path("a", "b"), fixture:path("a", "b", "c"),
    }, child._watchers:paths())
  end)

  it("loads every shared x/x/x x/y and y/x trie prefix at most once", function()
    fixture:tree({
      ["x/x/x/leaf.txt"] = "x",
      ["x/y/leaf.txt"] = "y",
      ["y/x/leaf.txt"] = "z",
    })
    local predecessor = wait_ready(keep(fre.new({ root = fixture.root, columns = {} })))
    predecessor:expand("x/x/x")
    predecessor:expand("x/y")
    predecessor:expand("y/x")
    wait_for(function()
      return predecessor:get_pos("x/x/x/leaf.txt")
        and predecessor:get_pos("x/y/leaf.txt")
        and predecessor:get_pos("y/x/leaf.txt")
    end)

    local adapter, counts = counting_loader()
    fre._set_fs_adapter(adapter)
    local child = wait_ready(keep(fre.new({
      root = fixture.root, inherit = predecessor, columns = {},
    })))
    wait_for(function()
      return child:get_pos("x/x/x/leaf.txt")
        and child:get_pos("x/y/leaf.txt")
        and child:get_pos("y/x/leaf.txt")
    end)
    for _, relative in ipairs({ "x", "x/x", "x/x/x", "x/y", "y", "y/x" }) do
      assert.are.equal(1, counts[fixture:path(unpack(vim.split(relative, "/", { plain = true })))], relative)
    end
    for row, node in ipairs(child.view.visible_nodes) do
      assert.are.equal(node.path, child.view.baseline[node.id])
      assert.are.equal(row, node.visible_start)
      assert.is_not_nil(node.visible_range)
      assert.is_not_nil(node.row_extmark)
    end
    assert.is_true(#vim.api.nvim_buf_get_extmarks(
      child.bufnr, buffer.namespace, 0, -1, {}) > 0)
  end)

  it("compiles same below above unrelated and Windows-shaped roots by components", function()
    local snapshot = {
      root = "/project/src",
      states = {
        { path = "/project/src/a", expanded = true },
        { path = "/project/src/a/barrier", expanded = false },
        { path = "/project/src/a/barrier/deep", expanded = true },
      },
    }
    assert.are.same({
      a = true, ["a/barrier"] = false, ["a/barrier/deep"] = true,
    }, flatten(inheritance.compile(snapshot, "/project/src")))
    assert.are.same({
      barrier = false, ["barrier/deep"] = true,
    }, flatten(inheritance.compile(snapshot, "/project/src/a")))
    assert.are.same({
      src = true, ["src/a"] = true, ["src/a/barrier"] = false,
      ["src/a/barrier/deep"] = true,
    }, flatten(inheritance.compile(snapshot, "/project")))
    assert.are.same({}, flatten(inheritance.compile(snapshot, "/project-other")))

    local windows = {
      root = "C:/Work/Src",
      states = {
        { path = "c:/work/src/X", expanded = true },
        { path = "C:/WORK/SRC/X/Stop", expanded = false },
        { path = "C:/work/src/x/stop/Deep", expanded = true },
      },
    }
    assert.are.same({
      X = true, ["X/Stop"] = false, ["X/Stop/Deep"] = true,
    }, flatten(inheritance.compile(windows, "c:/WORK/src")))
    assert.are.same({}, flatten(inheritance.compile(windows, "C:/Workshop")))
  end)

  it("isolates missing file and failed inherited branches while a sibling restores", function()
    fixture:tree({
      ["missing/deep/leaf.txt"] = "m",
      ["changed/deep/leaf.txt"] = "c",
      ["changed-link/deep/leaf.txt"] = "l",
      ["failed/deep/leaf.txt"] = "f",
      ["good/deep/leaf.txt"] = "g",
    })
    local predecessor = wait_ready(keep(fre.new({ root = fixture.root, columns = {} })))
    for _, relative in ipairs({
      "missing/deep", "changed/deep", "changed-link/deep", "failed/deep", "good/deep",
    }) do
      predecessor:expand(relative)
    end
    wait_for(function() return predecessor:get_pos("good/deep/leaf.txt") ~= nil end)

    fs.remove_tree(fixture:path("missing"))
    fs.remove_tree(fixture:path("changed"))
    fixture:write("changed", "now a file")
    local failed_path = fixture:path("failed")
    fre._set_fs_adapter({
      load = function(scan_path, done)
        if path.equal(scan_path, failed_path) then
          done("scripted branch failure")
          return
        end
        real_fs.load(scan_path, function(err, children, real_path)
          if not err and path.equal(scan_path, fixture.root) then
            for _, entry in ipairs(children) do
              if entry.name == "changed-link" then entry.kind = "symlink" end
            end
          end
          done(err, children, real_path)
        end)
      end,
    })
    local child = wait_ready(keep(fre.new({
      root = fixture.root, inherit = predecessor, columns = {},
    })))
    wait_for(function() return child:get_pos("good/deep/leaf.txt") ~= nil end)
    wait_for(function()
      return child._last_async_error
        and child._last_async_error:find("scripted branch failure", 1, true)
    end)

    assert.is_truthy(child.state:find("ready", 1, true))
    assert.is_nil(child.nodes_by_path[fixture:path("missing")])
    assert.are.equal("file", child.nodes_by_path[fixture:path("changed")].kind)
    assert.are.equal("symlink", child.nodes_by_path[fixture:path("changed-link")].kind)
    assert.is_false(child.nodes_by_path[failed_path].loaded)
    assert.is_not_nil(child:get_pos("good/deep/leaf.txt"))
  end)

  it("rolls back inherited reconcile and render failure while siblings and retry continue", function()
    fixture:tree({
      ["bad/deep/leaf.txt"] = "bad",
      ["good/deep/leaf.txt"] = "good",
    })
    fre._set_watch_adapter(fake_watch_adapter())
    local predecessor = wait_ready(keep(fre.new({ root = fixture.root, columns = {} })))
    predecessor:expand("bad/deep")
    predecessor:expand("good/deep")
    wait_for(function()
      return predecessor:get_pos("bad/deep/leaf.txt")
        and predecessor:get_pos("good/deep/leaf.txt")
    end)

    local bad_deep_path = fixture:path("bad", "deep")
    local fail_render = true
    local descriptor = columns.custom({
      id = "inherited-fault",
      render = function(entry)
        if fail_render and path.equal(entry.absolute_path, bad_deep_path) then
          error("inherited render exploded")
        end
        return entry.name
      end,
      parse = function(suffix)
        local value, rest = suffix:match("^(%S+)%s+(.*)$")
        return value, rest
      end,
      equals = function() return true end,
    })
    local adapter, counts, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local child = keep(fre.new({
      root = fixture.root, inherit = predecessor, columns = { descriptor },
    }))
    release(child.root)
    wait_ready(child)

    local bad_path = fixture:path("bad")
    local good_path = fixture:path("good")
    local good_deep_path = fixture:path("good", "deep")
    wait_for(function() return pending[bad_path] and pending[good_path] end)
    local bad = child.nodes_by_path[bad_path]
    local before = atomic_state(child)
    local before_children_by_name = bad.children_by_name
    local before_children_order = bad.children_order
    local before_real_path = bad.real_path
    local waiter_calls, waiter_error = 0, nil
    child:_ensure_directory_loaded(bad, function(err)
      waiter_calls = waiter_calls + 1
      waiter_error = err
    end)

    release(bad_path)
    pending[bad_path][1]()
    wait_for(function() return waiter_calls == 1 end)
    wait_for(function()
      return child._last_async_error
        and child._last_async_error:find("inherited render exploded", 1, true)
    end)
    assert.is_truthy(tostring(waiter_error):find("inherited render exploded", 1, true))
    assert.is_truthy(child.state:find("ready", 1, true))
    assert_atomic_state(child, before)
    assert.are.equal(before_children_by_name, bad.children_by_name)
    assert.are.equal(before_children_order, bad.children_order)
    assert.are.equal(before_real_path, bad.real_path)
    assert.are.equal("unloaded", bad.load_state)
    assert.is_false(bad.loaded)
    assert.is_false(bad.children_cached)
    assert.is_nil(child.nodes_by_path[bad_deep_path])
    assert.are.equal("dropped", child._inheritance_trie.children.bad.status)
    local watched = {}
    for _, watch_path in ipairs(child._watchers:paths()) do watched[watch_path] = true end
    assert.is_nil(watched[bad_deep_path])

    release(good_path)
    wait_for(function() return pending[good_deep_path] ~= nil end)
    release(good_deep_path)
    wait_for(function() return child:get_pos("good/deep/leaf.txt") ~= nil end)
    assert.are.equal(1, counts[good_path])
    assert.are.equal(1, counts[good_deep_path])
    assert.is_not_nil(child:get_pos("good/deep/leaf.txt"))
    watched = {}
    for _, watch_path in ipairs(child._watchers:paths()) do watched[watch_path] = true end
    assert.is_nil(watched[bad_deep_path])
    assert.is_true(watched[good_deep_path])

    fail_render = false
    child:expand("bad")
    wait_for(function() return pending[bad_path] and pending[bad_path][2] end)
    release(bad_path, 2)
    wait_for(function() return child.nodes_by_path[bad_deep_path] ~= nil end)
    assert.are.equal(2, counts[bad_path])
    assert.are.equal("loaded", bad.load_state)
    assert.is_true(bad.loaded)
    assert.is_true(bad.children_cached)
    assert.is_false(child.nodes_by_path[bad_deep_path].expanded)
    assert.is_nil(counts[bad_deep_path])
    assert.are.equal("dropped", child._inheritance_trie.children.bad.status)
    assert.is_not_nil(child:get_pos("bad/deep"))
  end)

  it("inherits current sort and hidden state with explicit priority only at creation", function()
    fixture:tree({ ["a.txt"] = "a", ["z.txt"] = "z", [".hidden"] = "h" })
    local setup_sort = function(_, left, right) return left.name < right.name end
    local predecessor_sort = function(_, left, right) return left.name > right.name end
    local explicit_sort = function(_, left, right) return left.name == "a.txt" and right.name ~= "a.txt" end
    fre.setup({ sort = setup_sort, hidden_file = false, columns = {} })
    local predecessor = wait_ready(keep(fre.new({ root = fixture.root })))
    predecessor:set_hidden_file(true)
    predecessor:set_sort(predecessor_sort)
    wait_for(function() return not predecessor._refresh_request end)

    local inherited = wait_ready(keep(fre.new({ root = fixture.root, inherit = predecessor })))
    local explicit = wait_ready(keep(fre.new({
      root = fixture.root, inherit = predecessor, sort = explicit_sort, hidden_file = false,
    })))
    assert.are.equal(predecessor_sort, inherited.current_sort)
    assert.is_true(inherited.current_hidden_file)
    assert.are.equal(explicit_sort, explicit.current_sort)
    assert.is_false(explicit.current_hidden_file)

    predecessor:set_hidden_file(false)
    assert.is_true(inherited.current_hidden_file)
    predecessor:set_sort(setup_sort)
    wait_for(function() return not predecessor._refresh_request end)
    assert.are.equal(predecessor_sort, inherited.current_sort)
    inherited:set_hidden_file(false)
    inherited:set_sort(setup_sort)
    wait_for(function() return not inherited._refresh_request end)
    assert.are.equal(setup_sort, predecessor.current_sort)
    assert.are.equal(setup_sort, inherited.current_sort)
    assert.are.equal(explicit_sort, explicit.current_sort)
    assert.is_false(explicit.current_hidden_file)
  end)

  it("keeps every non-view config family at setup plus explicit child overrides", function()
    fixture:write("file.txt", "x")
    local setup_map = function() end
    local predecessor_map = function() end
    local child_map = function() end
    fre.setup({
      columns = { custom_column("setup") },
      gc = { ttl_ms = 111, include_modified = false, default_group = "default" },
      mapping = { n = { s = setup_map } },
      buffer = { options = { textwidth = 11 }, variables = { origin = "setup" } },
      window = { options = { cursorline = true } },
      layout = { position = "right", size = 31 },
    })
    local predecessor = wait_ready(keep(fre.new({
      root = fixture.root,
      columns = { custom_column("predecessor") },
      gc = { ttl_ms = 222, include_modified = true, group = "project" },
      mapping = { n = { p = predecessor_map } },
      buffer = { options = { textwidth = 22 }, variables = { origin = "predecessor" } },
      window = { options = { cursorline = false } },
      layout = { position = "left", size = 22 },
    })))
    local child = wait_ready(keep(fre.new({ root = fixture.root, inherit = predecessor })))
    assert.are.equal("setup", child.config.columns[1].id)
    assert.are.same({ ttl_ms = 111, include_modified = false, group = "default" }, child.config.gc)
    assert.are.equal(setup_map, child.config.mapping.n.s)
    assert.is_nil(child.config.mapping.n.p)
    assert.are.equal(11, child.config.buffer.options.textwidth)
    assert.are.equal("setup", child.config.buffer.variables.origin)
    assert.is_true(child.config.window.options.cursorline)
    assert.are.same({ position = "right", size = 31 }, child.config.layout)

    local explicit = wait_ready(keep(fre.new({
      root = fixture.root, inherit = predecessor,
      columns = {}, gc = { ttl_ms = 333, include_modified = true, group = "project" },
      mapping = { n = { c = child_map } },
      buffer = { options = { textwidth = 33 }, variables = { origin = "child" } },
      window = { options = { cursorline = false } },
      layout = { position = "bottom", size = 13 },
    })))
    assert.are.same({}, explicit.config.columns)
    assert.are.same({ ttl_ms = 333, include_modified = true, group = "project" }, explicit.config.gc)
    assert.are.equal(child_map, explicit.config.mapping.n.c)
    assert.is_nil(explicit.config.mapping.n.p)
    assert.are.equal(33, explicit.config.buffer.options.textwidth)
    assert.are.equal("child", explicit.config.buffer.variables.origin)
    assert.is_false(explicit.config.window.options.cursorline)
    assert.are.same({ position = "bottom", size = 13 }, explicit.config.layout)
  end)

  it("detaches nodes IDs buffers markers watchers and suppresses stale inherited callbacks", function()
    fixture:tree({ ["a/b/leaf.txt"] = "x" })
    local watch_adapter = fake_watch_adapter()
    fre._set_watch_adapter(watch_adapter)
    local predecessor = wait_ready(keep(fre.new({ root = fixture.root, columns = {} })))
    predecessor:expand("a/b")
    wait_for(function() return predecessor:get_pos("a/b/leaf.txt") ~= nil end)

    local adapter, counts, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local child = keep(fre.new({ root = fixture.root, inherit = predecessor, columns = {} }))
    predecessor:collapse("a")
    release(child.root)
    wait_ready(child)
    local a_path = fixture:path("a")
    wait_for(function() return pending[a_path] and pending[a_path][1] end)

    local predecessor_a = predecessor.nodes_by_path[a_path]
    local child_a = child.nodes_by_path[a_path]
    assert.are_not.equal(predecessor.id, child.id)
    assert.are_not.equal(predecessor.bufnr, child.bufnr)
    assert.are_not.equal(predecessor_a, child_a)
    assert.are_not.equal(buffer.marker(predecessor.id, predecessor_a.id),
      buffer.marker(child.id, child_a.id))
    assert.are_not.equal(predecessor._watchers, child._watchers)
    assert.are_not.equal(predecessor._watchers.entries[predecessor.root],
      child._watchers.entries[child.root])
    assert.are_not.equal(predecessor._watchers.entries[predecessor.root].handle,
      child._watchers.entries[child.root].handle)
    assert.is_true(#vim.api.nvim_buf_get_extmarks(
      predecessor.bufnr, buffer.namespace, 0, -1, {}) > 0)
    assert.is_true(#vim.api.nvim_buf_get_extmarks(
      child.bufnr, buffer.namespace, 0, -1, {}) > 0)

    child:collapse("a")
    release(a_path, 1)
    vim.wait(40, function() return false end, 10)
    assert.is_nil(child.nodes_by_path[fixture:path("a", "b")])
    assert.are.equal("unloaded", child_a.load_state)

    child:expand("a")
    wait_for(function() return pending[a_path] and pending[a_path][2] end)
    predecessor:destroy()
    release(a_path, 2)
    local b_path = fixture:path("a", "b")
    wait_for(function() return pending[b_path] and pending[b_path][1] end)
    release(b_path, 1)
    wait_for(function() return child:get_pos("a/b/leaf.txt") ~= nil end)
    assert.are.equal(2, counts[a_path])
    assert.are.equal(1, counts[b_path])
    assert.is_true(child.nodes_by_path[a_path].expanded)
    assert.is_true(child.nodes_by_path[b_path].expanded)
  end)
end)
