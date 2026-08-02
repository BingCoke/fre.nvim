local buffer = require("fre.instance.buffer")
local columns = require("fre.columns")
local fre = require("fre")
local path = require("fre.path")
local real_fs = require("fre.fs").default
local fs = require("tests.helpers.fs")

local fixture
local instances = {}

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(2500, predicate, 10))
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
  opts = vim.tbl_extend("force", { root = fixture.root }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function lines(instance)
  return vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
end

local function set_lines(instance, replacement)
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, replacement)
  vim.bo[instance.bufnr].modifiable = modifiable
end

local function error_text(callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  return tostring(err)
end

local function projected_paths(instance)
  local result = {}
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(instance.buffer:decode(row))
    if decoded.row_kind == "entry" then result[#result + 1] = decoded.path end
  end
  return result
end

local function deferred_loader()
  local requests = {}
  local counts = {}
  local adapter = {
    load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      real_fs.load(scan_path, function(...)
        local values = { n = select("#", ...), ... }
        requests[scan_path] = requests[scan_path] or {}
        requests[scan_path][#requests[scan_path] + 1] = {
          done = done,
          values = values,
        }
      end)
    end,
  }
  local function release(scan_path, index, override_error)
    index = index or 1
    wait_for(function()
      return requests[scan_path] ~= nil and requests[scan_path][index] ~= nil
    end)
    local request = requests[scan_path][index]
    if override_error ~= nil then request.done(override_error)
    else request.done(unpack(request.values, 1, request.values.n)) end
  end
  return adapter, counts, requests, release
end

local function complete_refresh(instance, opts)
  local completed = false
  local completion_error
  opts = vim.tbl_extend("force", opts or {}, {
    on_complete = function(err)
      completion_error = err
      completed = true
    end,
  })
  instance:refresh(opts)
  wait_for(function() return completed end)
  return completion_error
end

local function snapshot(instance)
  local nodes = {}
  for id, node in pairs(instance.tree.nodes_by_id) do
    local order = {}
    for _, child in ipairs(node.children_order or {}) do order[#order + 1] = child.id end
    nodes[id] = {
      ref = node,
      path = node.path,
      kind = node.kind,
      parent = node.parent,
      expanded = node.expanded,
      loaded = node.loaded,
      children_cached = node.children_cached,
      load_state = node.load_state,
      load_generation = node.load_generation,
      order = order,
    }
  end
  return {
    tree = instance.tree,
    root_node = instance.tree.root,
    nodes_by_id = instance.tree.nodes_by_id,
    nodes_by_path = instance.tree.nodes_by_path,
    view = instance.buffer.view,
    baseline = vim.deepcopy(instance.buffer.view.baseline),
    widths = vim.deepcopy(instance.buffer.view.column_widths),
    projection_generation = instance.buffer.view.projection_generation,
    projection_ranges = vim.deepcopy(instance.buffer.projection_ranges),
    row_extmarks = vim.deepcopy(instance.buffer.row_extmarks),
    text = lines(instance),
    modified = vim.bo[instance.bufnr].modified,
    extmarks = vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}),
    nodes = nodes,
  }
end

local function assert_snapshot(instance, expected)
  assert.are.equal(expected.tree, instance.tree)
  assert.are.equal(expected.root_node, instance.tree.root)
  assert.are.equal(expected.nodes_by_id, instance.tree.nodes_by_id)
  assert.are.equal(expected.nodes_by_path, instance.tree.nodes_by_path)
  assert.are.equal(expected.view, instance.buffer.view)
  assert.are.same(expected.baseline, instance.buffer.view.baseline)
  assert.are.same(expected.widths, instance.buffer.view.column_widths)
  assert.are.equal(expected.projection_generation, instance.buffer.view.projection_generation)
  assert.are.same(expected.projection_ranges, instance.buffer.projection_ranges)
  assert.are.same(expected.row_extmarks, instance.buffer.row_extmarks)
  assert.are.same(expected.text, lines(instance))
  assert.are.equal(expected.modified, vim.bo[instance.bufnr].modified)
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}))
  for id, value in pairs(expected.nodes) do
    local node = instance.tree.nodes_by_id[id]
    assert.are.equal(value.ref, node)
    assert.are.equal(value.path, node.path)
    assert.are.equal(value.kind, node.kind)
    assert.are.equal(value.parent, node.parent)
    assert.are.equal(value.expanded, node.expanded)
    assert.are.equal(value.loaded, node.loaded)
    assert.are.equal(value.children_cached, node.children_cached)
    assert.are.equal(value.load_state, node.load_state)
    assert.are.equal(value.load_generation, node.load_generation)
    local order = {}
    for _, child in ipairs(node.children_order or {}) do order[#order + 1] = child.id end
    assert.are.same(value.order, order)
  end
end

local function value_column(render, parse)
  return columns.custom({
    id = "value",
    render = render,
    parse = parse or function(suffix)
      local value, rest = suffix:match("^(%S+) +(.*)$")
      return value, rest
    end,
    equals = function(entry, value, ctx)
      return value == ctx.descriptor.render(entry, ctx)
    end,
  })
end

describe("fre ticket 08 atomic refresh", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
  end)

  after_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    for _, instance in ipairs(instances) do
      if instance:status() ~= "destroyed" then instance:destroy() end
    end
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("validates the exact option shape synchronously before I/O or state changes", function()
    local calls = 0
    fre._set_fs_adapter({
      load = function(scan_path, done)
        calls = calls + 1
        real_fs.load(scan_path, done)
      end,
    })
    local instance = ready({ ["a.txt"] = "a" })
    local initial_calls = calls
    local needs_refresh = instance.sync:is_dirty()
    local cases = {
      function() instance:refresh(false) end,
      function() instance:refresh("bad") end,
      function() instance:refresh({ unknown = true }) end,
      function() instance:refresh({ force = 1 }) end,
      function() instance:refresh({ on_complete = true }) end,
    }
    for _, operation in ipairs(cases) do
      local err = error_text(operation)
      assert.is_truthy(err:find("refresh", 1, true), err)
      assert.are.equal(initial_calls, calls)
      assert.are.equal(needs_refresh, instance.sync:is_dirty())
      assert.is_false(instance.sync:is_busy())
    end
  end)

  it("rejects lifecycle write-lock load and concurrent conflicts synchronously", function()
    local initial_done
    local calls = 0
    fre._set_fs_adapter({ load = function(_, done) calls = calls + 1; initial_done = done end })
    local creating = keep(fre.new({ root = fixture.root }))
    assert.is_truthy(error_text(function() creating:refresh() end):find("still loading", 1, true))
    assert.are.equal(1, calls)
    initial_done(nil, {}, fixture.root)
    wait_ready(creating)


    local pending
    fre._set_fs_adapter({ load = function(_, done) calls = calls + 1; pending = done end })
    local first_count = 0
    creating:refresh({ on_complete = function() first_count = first_count + 1 end })
    assert.is_truthy(error_text(function()
      creating:refresh({ on_complete = function() error("must not run") end })
    end):find("already in progress", 1, true))
    assert.are.equal(2, calls)
    pending(nil, {}, fixture.root)
    wait_for(function() return first_count == 1 end)

    creating:destroy()
    assert.is_truthy(error_text(function() creating:refresh() end):find("destroyed", 1, true))
    assert.are.equal(2, calls)
  end)

  it("retries load-failed through the initial readiness lifecycle", function()
    local callbacks = {}
    fre._set_fs_adapter({
      load = function(_, done) callbacks[#callbacks + 1] = done end,
    })
    local instance = keep(fre.new({ root = fixture.root }))
    assert.are.same({ "" }, lines(instance))
    callbacks[1]("initial failed")
    wait_for(function() return instance:status() == "load-failed" end)
    local callback_count, callback_error = 0
    instance:refresh({ on_complete = function(err)
      callback_count = callback_count + 1
      callback_error = err
    end })
    assert.are.equal("creating", instance:status())
    assert.are.same({ "" }, lines(instance))
    callbacks[2](nil, { { name = "ok.txt", kind = "file" } }, fixture.root)
    wait_for(function() return callback_count == 1 and instance:status() == "ready" end)
    assert.is_nil(callback_error)
    assert.are.same({ "ok.txt" }, projected_paths(instance))
    assert.is_false(instance.sync:is_dirty())
  end)

  it("preserves a forced draft during construction and failure, discarding only at commit", function()
    local adapter, _, requests, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    fixture:write("a.txt", "a")
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root, 1)
    wait_ready(instance)

    local draft = { "unsaved exact draft", "second line" }
    set_lines(instance, draft)
    assert.is_true(vim.bo[instance.bufnr].modified)
    local rejected_count = 0
    local rejected = error_text(function()
      instance:refresh({ on_complete = function() rejected_count = rejected_count + 1 end })
    end)
    assert.is_truthy(rejected:find("buffer is modified", 1, true))
    assert.are.equal(0, rejected_count)
    assert.is_nil(requests[instance.root][2])
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
    local errors = {}
    instance:refresh({ force = true, on_complete = function(err) errors[#errors + 1] = err end })
    wait_for(function() return requests[instance.root] and requests[instance.root][2] end)
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
    release(instance.root, 2, "forced scan failed")
    wait_for(function() return #errors == 1 end)
    assert.are.equal("forced scan failed", errors[1])
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
    assert.is_true(instance.sync:is_dirty())

    fixture:write("b.txt", "b")
    instance:refresh({ force = true, on_complete = function(err) errors[#errors + 1] = err or false end })
    wait_for(function() return requests[instance.root] and requests[instance.root][3] end)
    assert.are.same(draft, lines(instance))
    release(instance.root, 3)
    wait_for(function() return #errors == 2 end)
    assert.is_false(errors[2])
    assert.are.same({ "a.txt", "b.txt" }, projected_paths(instance))
    assert.is_false(vim.bo[instance.bufnr].modified)
    assert.is_false(instance.sync:is_dirty())
    local committed = lines(instance)
    vim.api.nvim_buf_call(instance.bufnr, function() vim.cmd("silent! undo") end)
    assert.are.same(committed, lines(instance))
    assert.is_false(vim.bo[instance.bufnr].modified)
  end)

  it("scans root and only the active expanded ancestor chains", function()
    local counts = {}
    fre._set_fs_adapter({
      load = function(scan_path, done)
        counts[scan_path] = (counts[scan_path] or 0) + 1
        real_fs.load(scan_path, done)
      end,
    })
    local instance = ready({
      ["active/deep/a.txt"] = "a",
      ["inactive/deep/b.txt"] = "b",
      ["plain/c.txt"] = "c",
    })
    instance:expand("active/deep")
    instance:expand("inactive/deep")
    wait_for(function()
      return instance:get_pos("active/deep/a.txt") and instance:get_pos("inactive/deep/b.txt")
    end)
    instance:collapse("inactive")
    counts = {}

    assert.is_nil(complete_refresh(instance))
    assert.are.equal(1, counts[instance.root])
    assert.are.equal(1, counts[fixture:path("active")])
    assert.are.equal(1, counts[fixture:path("active", "deep")])
    assert.is_nil(counts[fixture:path("inactive")])
    assert.is_nil(counts[fixture:path("inactive", "deep")])
    assert.is_nil(counts[fixture:path("plain")])
    assert.is_true(instance.tree.nodes_by_path[fixture:path("inactive", "deep")].expanded)
    assert.is_true(instance.tree.nodes_by_path[fixture:path("inactive", "deep")].children_cached)
  end)

  it("leaves complete authoritative snapshots unchanged on scan sort column parser and commit failures", function()
    local explode_render = false
    local explode_parse = false
    local descriptor = value_column(function(entry)
      if explode_render then error("column exploded") end
      return entry.name
    end, function(suffix)
      if explode_parse then error("parser exploded") end
      local value, rest = suffix:match("^(%S+) +(.*)$")
      return value, rest
    end)
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" }, {
      columns = { descriptor },
    })

    local function failed_refresh(expected, setup, cleanup)
      if setup then setup() end
      local before = snapshot(instance)
      local err = complete_refresh(instance)
      if cleanup then cleanup() end
      assert.is_truthy(tostring(err):find(expected, 1, true), tostring(err))
      assert_snapshot(instance, before)
      assert.is_true(instance.sync:is_dirty())
    end

    local original_adapter = instance.manager:get_fs_adapter()
    failed_refresh("scan exploded", function()
      fre._set_fs_adapter({ load = function(_, done) done("scan exploded") end })
    end, function() fre._set_fs_adapter(original_adapter) end)

    local original_sort = instance.tree:get_comparator()
    failed_refresh("sort exploded", function()
      instance.tree:set_comparator(function() error("sort exploded") end)
    end, function() instance.tree:set_comparator(original_sort) end)

    failed_refresh("column exploded", function() explode_render = true end,
      function() explode_render = false end)
    failed_refresh("parser exploded", function() explode_parse = true end,
      function() explode_parse = false end)

    local original_prepare = buffer.prepare
    failed_refresh("project exploded", function()
      buffer.prepare = function() error("project exploded") end
    end, function() buffer.prepare = original_prepare end)

    local original_set_extmark = vim.api.nvim_buf_set_extmark
    local injected = false
    failed_refresh("commit exploded", function()
      vim.api.nvim_buf_set_extmark = function(bufnr, namespace, row, col, opts)
        if not injected and namespace == buffer.namespace then
          injected = true
          error("commit exploded")
        end
        return original_set_extmark(bufnr, namespace, row, col, opts)
      end
    end, function() vim.api.nvim_buf_set_extmark = original_set_extmark end)
    assert.is_true(injected)
  end)

  it("never reuses IDs allocated by a discarded refresh candidate", function()
    local instance = ready({ ["kept.txt"] = "kept" })
    local tree = instance.tree
    local before = tree:latest_node_id()
    local added_path = fixture:write("added.txt", "added")
    local original_prepare = buffer.prepare
    buffer.prepare = function() error("candidate projection exploded") end
    local err = complete_refresh(instance)
    buffer.prepare = original_prepare

    assert.is_truthy(tostring(err):find("candidate projection exploded", 1, true))
    assert.are.equal(tree, instance.tree)
    assert.is_nil(tree.nodes_by_path[added_path])
    local discarded = tree:latest_node_id()
    assert.is_true(discarded > before)

    assert.is_nil(complete_refresh(instance))
    assert.are.equal(tree, instance.tree)
    assert.is_true(instance.tree.nodes_by_path[added_path].id > discarded)
  end)

  it("atomically replaces nodes while preserving stable IDs expansion and inactive cache", function()
    local instance = ready({
      ["dir/keep.txt"] = "keep",
      ["dir/remove.txt"] = "remove",
      ["cached/deep/held.txt"] = "held",
    })
    instance:expand("dir")
    instance:expand("cached/deep")
    wait_for(function() return instance:get_pos("cached/deep/held.txt") ~= nil end)
    instance:collapse("cached")
    local dir_id = instance.tree.nodes_by_path[fixture:path("dir")].id
    local keep_id = instance.tree.nodes_by_path[fixture:path("dir", "keep.txt")].id
    local cached_deep_id = instance.tree.nodes_by_path[fixture:path("cached", "deep")].id
    fs.remove_tree(fixture:path("dir", "remove.txt"))
    fixture:write("dir/new.txt", "new")

    assert.is_nil(complete_refresh(instance))
    assert.are.equal(dir_id, instance.tree.nodes_by_path[fixture:path("dir")].id)
    assert.are.equal(keep_id, instance.tree.nodes_by_path[fixture:path("dir", "keep.txt")].id)
    assert.is_nil(instance.tree.nodes_by_path[fixture:path("dir", "remove.txt")])
    assert.is_not_nil(instance.tree.nodes_by_path[fixture:path("dir", "new.txt")])
    assert.is_true(instance.tree.nodes_by_path[fixture:path("dir")].expanded)
    assert.are.equal(cached_deep_id, instance.tree.nodes_by_path[fixture:path("cached", "deep")].id)
    assert.is_true(instance.tree.nodes_by_path[fixture:path("cached", "deep")].expanded)
    assert.is_true(instance.tree.nodes_by_path[fixture:path("cached", "deep")].children_cached)
    assert.are.same({ "cached/", "dir/", "dir/keep.txt", "dir/new.txt" }, projected_paths(instance))
  end)

  it("preserves stable cursor targets in managed active Views across tabs", function()
    local entries = {}
    for index = 1, 30 do entries[string.format("item-%02d.txt", index)] = tostring(index) end
    local instance = ready(entries)
    instance:open()
    local first = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(first, instance:get_pos("item-10.txt"))
    vim.api.nvim_win_call(first, function() vim.cmd("normal! zt") end)

    vim.cmd("tabnew")
    instance:open()
    local second = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(second, instance:get_pos("item-30.txt"))
    vim.api.nvim_win_call(second, function() vim.cmd("normal! zb") end)
    local focused_tab = vim.api.nvim_get_current_tabpage()
    local focused_win = vim.api.nvim_get_current_win()

    fixture:write("item-00.txt", "zero")
    assert.is_nil(complete_refresh(instance))
    local expected = { [first] = "item-10.txt", [second] = "item-30.txt" }
    for winid, name in pairs(expected) do
      assert.is_true(vim.api.nvim_win_is_valid(winid))
      local cursor = vim.api.nvim_win_get_cursor(winid)
      assert.are.equal(name, assert(instance.buffer:decode(cursor[1])).entry.name)
      local saved = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
      assert.is_true(saved.topline >= 1
        and saved.topline <= vim.api.nvim_buf_line_count(instance.bufnr))
    end
    assert.are.equal(focused_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(focused_win, vim.api.nvim_get_current_win())
  end)

  it("calls callbacks once on the main loop and suppresses duplicate adapter completion", function()
    local adapter, _, requests, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    fixture:write("a.txt", "a")
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root, 1)
    wait_ready(instance)

    local callback_count = 0
    local on_main_loop = false
    instance:refresh({ on_complete = function(err)
      assert.is_nil(err)
      callback_count = callback_count + 1
      on_main_loop = not vim.in_fast_event()
    end })
    wait_for(function() return requests[instance.root] and requests[instance.root][2] end)
    local request = requests[instance.root][2]
    release(instance.root, 2)
    request.done(unpack(request.values, 1, request.values.n))
    wait_for(function() return callback_count == 1 end)
    vim.wait(50, function() return false end, 10)
    assert.are.equal(1, callback_count)
    assert.is_true(on_main_loop)
  end)

  it("protects callback errors and completes a stale destroyed refresh only once", function()
    local adapter, _, requests, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    fixture:write("a.txt", "a")
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root, 1)
    wait_ready(instance)

    local original_notify = vim.notify
    local notices = {}
    vim.notify = function(message) notices[#notices + 1] = message end
    instance:refresh({ on_complete = function() error("callback exploded") end })
    release(instance.root, 2)
    wait_for(function()
      return instance._last_async_error
        and instance._last_async_error:find("callback exploded", 1, true)
    end)
    assert.are.equal(1, #notices)

    local stale_count, stale_error = 0
    instance:refresh({ on_complete = function(err)
      stale_count = stale_count + 1
      stale_error = err
    end })
    wait_for(function() return requests[instance.root] and requests[instance.root][3] end)
    local stale = requests[instance.root][3]
    instance:destroy()
    stale.done(unpack(stale.values, 1, stale.values.n))
    wait_for(function() return stale_count == 1 end)
    vim.wait(50, function() return false end, 10)
    vim.notify = original_notify
    assert.are.equal(1, stale_count)
    assert.is_truthy(tostring(stale_error):find("destroyed", 1, true))
  end)


  it("uses protected no-callback reporting exactly once for asynchronous failures", function()
    local instance = ready({ ["a.txt"] = "a" })
    local original_notify = vim.notify
    local notices = {}
    vim.notify = function(message) notices[#notices + 1] = message end
    fre._set_fs_adapter({
      load = function(_, done)
        done("reported failure")
        done("duplicate failure")
      end,
    })
    instance._last_async_error = nil
    instance:refresh()
    wait_for(function() return instance._last_async_error ~= nil end)
    vim.notify = original_notify
    assert.are.equal(1, #notices)
    assert.is_truthy(notices[1]:find("reported failure", 1, true))
    assert.is_truthy(instance._last_async_error:find("reported failure", 1, true))
    assert.is_true(instance.sync:is_dirty())
  end)
end)
