local buffer = require("fre.buffer")
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
  assert.is_true(vim.wait(2000, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function()
    return instance.state == "ready"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
end

local function ready(entries, opts)
  fixture:tree(entries or {})
  opts = vim.tbl_extend("force", { root = fixture.root }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function projected_paths(instance)
  local result = {}
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(buffer.decode(instance, row))
    if decoded.row_kind == "entry" then result[#result + 1] = decoded.path end
  end
  return result
end

local function lines(instance)
  return vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
end

local function set_line(instance, row, text)
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, row - 1, row, false, { text })
  vim.bo[instance.bufnr].modifiable = modifiable
end

local function error_text(callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  return tostring(err)
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
        pending[scan_path][#pending[scan_path] + 1] = function(override_error)
          if override_error then done(override_error)
          else done(unpack(values, 1, values.n)) end
        end
      end)
    end,
  }
  local function release(scan_path, index, override_error)
    index = index or 1
    wait_for(function()
      return pending[scan_path] ~= nil and pending[scan_path][index] ~= nil
    end)
    pending[scan_path][index](override_error)
  end
  return adapter, counts, pending, release
end

local function value_column(render)
  return columns.custom({
    id = "value",
    render = render,
    parse = function(suffix)
      local value, remaining = suffix:match("^(%S+) +(.*)$")
      return value, remaining
    end,
    equals = function(entry, value, ctx)
      return value == ctx.descriptor.render(entry, ctx)
    end,
  })
end

local function projection_snapshot(instance)
  local orders = {}
  local visibility = {}
  for _, node in pairs(instance.nodes_by_id) do
    if node.kind == "directory" then
      local ids = {}
      for _, child in ipairs(node.children_order or {}) do ids[#ids + 1] = child.id end
      orders[node.id] = ids
    end
    visibility[node.id] = {
      node.visible_size, node.visible_start, node.visible_end,
      node.visible_range and vim.deepcopy(node.visible_range) or nil,
    }
  end
  return {
    lines = lines(instance),
    baseline = vim.deepcopy(instance.view.baseline),
    widths = vim.deepcopy(instance.view.column_widths),
    extmarks = vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}),
    generation = instance.view.projection_generation,
    orders = orders,
    visibility = visibility,
  }
end

local function assert_projection_snapshot(instance, expected)
  assert.are.same(expected.lines, lines(instance))
  assert.are.same(expected.baseline, instance.view.baseline)
  assert.are.same(expected.widths, instance.view.column_widths)
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}))
  assert.are.equal(expected.generation, instance.view.projection_generation)
  local actual = projection_snapshot(instance)
  assert.are.same(expected.orders, actual.orders)
  assert.are.same(expected.visibility, actual.visibility)
end

local function assert_public_entry(entry)
  local allowed = {
    instance_id = true, node_id = true, absolute_path = true,
    relative_path = true, name = true, kind = true,
  }
  local count = 0
  for key in pairs(entry) do
    assert.is_true(allowed[key] == true)
    count = count + 1
  end
  assert.are.equal(6, count)
end

describe("fre ticket 07 sort hidden and reveal", function()
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
      if instance.state ~= "destroyed" then instance:destroy() end
    end
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("applies the default ASCII ordering independently to every parent", function()
    local root = path.absolute(fixture.root)
    local scans = {
      [root] = {
        { name = "Zoo", kind = "directory" },
        { name = "alpha", kind = "directory" },
        { name = "b.txt", kind = "file" },
        { name = "A.txt", kind = "file" },
        { name = "a.txt", kind = "file" },
        { name = "target", kind = "file" },
        { name = "z-link", kind = "symlink" },
      },
      [path.resolve(root, "alpha")] = {
        { name = "B.txt", kind = "file" },
        { name = "a.txt", kind = "file" },
        { name = "A.txt", kind = "file" },
        { name = "Dir", kind = "directory" },
      },
      [path.resolve(root, "Zoo")] = {
        { name = "z.txt", kind = "file" },
      },
    }
    fre._set_fs_adapter({
      load = function(scan_path, done) done(nil, assert(scans[scan_path]), scan_path) end,
    })
    local instance = wait_ready(keep(fre.new({ root = root })))
    instance:expand("alpha")
    instance:expand("Zoo")
    wait_for(function()
      return instance:get_pos("alpha/B.txt") ~= nil and instance:get_pos("Zoo/z.txt") ~= nil
    end)

    assert.are.same({
      "alpha/", "alpha/Dir/", "alpha/A.txt", "alpha/a.txt", "alpha/B.txt",
      "Zoo/", "Zoo/z.txt", "A.txt", "a.txt", "b.txt", "target", "z-link",
    }, projected_paths(instance))
  end)

  it("passes fresh exact sibling Entries to custom comparators without exposing nodes", function()
    local calls = {}
    local seen = {}
    local instance = ready({
      ["dir/c.txt"] = "c",
      ["dir/a.txt"] = "a",
      ["dir/b.txt"] = "b",
      ["z.txt"] = "z",
      ["a.txt"] = "a",
      ["m.txt"] = "m",
    }, {
      sort = function(parent, a, b)
        assert.is_nil(seen[parent])
        assert.is_nil(seen[a])
        assert.is_nil(seen[b])
        seen[parent], seen[a], seen[b] = true, true, true
        assert_public_entry(parent)
        assert_public_entry(a)
        assert_public_entry(b)
        calls[#calls + 1] = {
          parent = vim.deepcopy(parent), a = vim.deepcopy(a), b = vim.deepcopy(b),
        }
        local left, right = a.name, b.name
        parent.name, a.name, b.name = "mutated", "mutated", "mutated"
        return left < right
      end,
    })
    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/c.txt") ~= nil end)

    assert.are.same({ "a.txt", "dir/", "dir/a.txt", "dir/b.txt", "dir/c.txt", "m.txt", "z.txt" },
      projected_paths(instance))
    assert.is_true(#calls > 0)
    for _, call in ipairs(calls) do
      if call.parent.relative_path == "" then
        assert.is_nil(call.a.relative_path:find("/", 1, true))
        assert.is_nil(call.b.relative_path:find("/", 1, true))
      else
        assert.are.equal("dir", call.parent.relative_path)
        assert.is_truthy(call.a.relative_path:find("^dir/"))
        assert.is_truthy(call.b.relative_path:find("^dir/"))
      end
    end
    assert.are.equal("dir", instance.nodes_by_path[fixture:path("dir")].name)
    assert.are.equal("a.txt", instance.nodes_by_path[fixture:path("dir", "a.txt")].name)
  end)

  it("retains dynamic sort state and atomically reorders every loaded parent", function()
    local explode_render = false
    local descriptor = value_column(function(entry)
      if explode_render then error("projection exploded") end
      return entry.name
    end)
    local instance = ready({
      ["a/one.txt"] = "1", ["a/two.txt"] = "2",
      ["b/one.txt"] = "1", ["b/two.txt"] = "2",
      ["tail.txt"] = "t",
    }, { columns = { descriptor } })
    instance:expand("a")
    instance:expand("b")
    wait_for(function()
      return instance:get_pos("a/two.txt") ~= nil and instance:get_pos("b/two.txt") ~= nil
    end)
    local ids = {}
    for absolute, node in pairs(instance.nodes_by_path) do ids[absolute] = node.id end

    local before_error = projection_snapshot(instance)
    local original_notify = vim.notify
    local notices = {}
    vim.notify = function(message) notices[#notices + 1] = message end
    local failing = function() error("comparator exploded") end
    instance._last_async_error = nil
    instance:set_sort(failing)
    assert.are.equal(failing, instance.current_sort)
    wait_for(function()
      return instance._last_async_error
        and instance._last_async_error:find("comparator exploded", 1, true)
    end)
    assert_projection_snapshot(instance, before_error)

    local reverse = function(_, left, right) return left.name > right.name end
    explode_render = true
    instance._last_async_error = nil
    instance:set_sort(reverse)
    assert.are.equal(reverse, instance.current_sort)
    wait_for(function()
      return instance._last_async_error
        and instance._last_async_error:find("projection exploded", 1, true)
    end)
    assert_projection_snapshot(instance, before_error)
    vim.notify = original_notify
    assert.are.equal(2, #notices)
    assert.is_truthy(notices[1]:find("comparator exploded", 1, true))
    assert.is_truthy(notices[2]:find("projection exploded", 1, true))

    explode_render = false
    instance:set_sort(reverse)
    wait_for(function()
      return vim.deep_equal({ "tail.txt", "b/", "b/two.txt", "b/one.txt", "a/", "a/two.txt", "a/one.txt" },
        projected_paths(instance))
    end)
    for absolute, id in pairs(ids) do
      assert.are.equal(id, instance.nodes_by_path[absolute].id)
    end
  end)

  it("validates setters and rejects them before changing modified drafts or state", function()
    local instance = ready({ [".hidden"] = "h", ["a.txt"] = "a" })
    local original_sort = instance.current_sort
    local original_hidden = instance.current_hidden_file
    local physical = lines(instance)
    set_line(instance, 1, physical[1] .. " draft")
    local draft = lines(instance)

    local err = error_text(function() instance:set_sort(function() return false end) end)
    assert.is_truthy(err:find("buffer is modified", 1, true))
    assert.are.equal(original_sort, instance.current_sort)
    err = error_text(function() instance:set_hidden_file(true) end)
    assert.is_truthy(err:find("buffer is modified", 1, true))
    err = error_text(function() instance:toggle_hidden_file() end)
    assert.is_truthy(err:find("buffer is modified", 1, true))
    assert.are.equal(original_hidden, instance.current_hidden_file)
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)

    err = error_text(function() instance:set_sort("bad") end)
    assert.is_truthy(err:find("sort must be a function", 1, true))
    err = error_text(function() instance:set_hidden_file(1) end)
    assert.is_truthy(err:find("hidden_file must be a boolean", 1, true))
  end)

  it("filters hidden basenames only while retaining cache IDs expansion and widths", function()
    local descriptor = value_column(function(entry) return entry.name end)
    local instance = ready({
      [".cache/very-long-hidden-child.txt"] = "x",
      [".wide-hidden-root-name.txt"] = "x",
      ["visible/x.txt"] = "x",
      ["a"] = "a",
    }, { columns = { descriptor } })
    assert.are.same({ "visible/", "a" }, projected_paths(instance))
    assert.are.equal(#"visible", instance.view.column_widths[1])

    instance:set_hidden_file(true)
    assert.are.equal(#".wide-hidden-root-name.txt", instance.view.column_widths[1])
    instance:expand(".cache")
    wait_for(function() return instance:get_pos(".cache/very-long-hidden-child.txt") ~= nil end)
    local hidden_dir = instance.nodes_by_path[fixture:path(".cache")]
    local hidden_child = instance.nodes_by_path[fixture:path(".cache", "very-long-hidden-child.txt")]
    local dir_id, child_id = hidden_dir.id, hidden_child.id
    assert.is_true(hidden_dir.expanded)
    assert.are.equal(#"very-long-hidden-child.txt", instance.view.column_widths[1])

    instance:toggle_hidden_file()
    assert.are.same({ "visible/", "a" }, projected_paths(instance))
    assert.are.equal(#"visible", instance.view.column_widths[1])
    assert.are.equal(hidden_dir, instance.nodes_by_id[dir_id])
    assert.are.equal(hidden_child, instance.nodes_by_id[child_id])
    assert.is_true(hidden_dir.expanded)
    assert.is_nil(instance.view.baseline[dir_id])
    assert.is_nil(instance.view.baseline[child_id])

    instance:set_hidden_file(true)
    assert.is_not_nil(instance:get_pos(".cache/very-long-hidden-child.txt"))
    assert.are.equal(dir_id, instance.nodes_by_path[fixture:path(".cache")].id)
    assert.are.equal(child_id,
      instance.nodes_by_path[fixture:path(".cache", "very-long-hidden-child.txt")].id)
    assert.is_true(instance.nodes_by_id[dir_id].expanded)
  end)

  it("reveals nested snapshot paths without invoking window primitives", function()
    local instance = ready({ ["a/b/target.txt"] = "x", ["tail.txt"] = "t" })
    local open_calls, toggle_calls = 0, 0
    instance.open = function() open_calls = open_calls + 1 end
    instance.toggle = function() toggle_calls = toggle_calls + 1 end

    instance:reveal(fixture:path("a", "b", "target.txt"))
    wait_for(function() return instance:get_pos("a/b/target.txt") ~= nil end)
    assert.is_true(instance.nodes_by_path[fixture:path("a")].expanded)
    assert.is_true(instance.nodes_by_path[fixture:path("a", "b")].expanded)
    assert.are.equal(0, open_calls)
    assert.are.equal(0, toggle_calls)
  end)

  it("rejects escaped missing and hidden reveal targets with explicit errors", function()
    local instance = ready({
      ["a/known.txt"] = "x",
      [".secret/file.txt"] = "x",
      ["visible/.target"] = "x",
    })
    local outside = path.resolve(vim.fs.dirname(instance.root), "outside.txt")
    local err = error_text(function() instance:reveal(outside) end)
    assert.is_truthy(err:find("outside the instance root", 1, true))
    err = error_text(function() instance:reveal("../outside.txt") end)
    assert.is_truthy(err:find("escapes the instance root", 1, true))
    err = error_text(function() instance:reveal("missing.txt") end)
    assert.is_truthy(err:find("snapshot path does not exist", 1, true))

    err = error_text(function() instance:reveal(".secret/file.txt") end)
    assert.is_truthy(err:find("enable hidden files", 1, true))
    assert.is_false(instance.nodes_by_path[fixture:path(".secret")].expanded)
    err = error_text(function() instance:reveal("visible/.target") end)
    assert.is_truthy(err:find("enable hidden files", 1, true))
    assert.is_false(instance.nodes_by_path[fixture:path("visible")].expanded)

    local original_notify = vim.notify
    vim.notify = function() end
    instance._last_async_error = nil
    instance:reveal("a/missing.txt")
    wait_for(function()
      return instance._last_async_error
        and instance._last_async_error:find("snapshot path does not exist", 1, true)
    end)
    vim.notify = original_notify
  end)

  it("does not retain hidden reveal cursor targets for a later open", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c" })
    instance:reveal("a.txt")
    instance:reveal("c.txt")
    instance:open()

    assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    assert.are_not.same(instance:get_pos("c.txt"), vim.api.nvim_win_get_cursor(0))
  end)

  it("selects one actual View for reveal without moving another duplicate", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c" })
    instance:open()
    local first = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local second = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(first, instance:get_pos("a.txt"))
    vim.api.nvim_win_set_cursor(second, instance:get_pos("a.txt"))
    vim.cmd("new")
    local scratch_window = vim.api.nvim_get_current_win()
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(scratch_window))
    local before = vim.fn.win_findbuf(instance.bufnr)

    local confirm = vim.fn.confirm
    local confirm_calls = 0
    vim.fn.confirm = function(_, choices)
      confirm_calls = confirm_calls + 1
      assert.is_truthy(choices:find("&a", 1, true))
      assert.is_truthy(choices:find("&b", 1, true))
      return 2
    end
    local ok, err = pcall(instance.reveal, instance, "c.txt")
    vim.fn.confirm = confirm
    assert.is_true(ok, tostring(err))
    assert.are.equal(1, confirm_calls)
    assert.are.same(before, vim.fn.win_findbuf(instance.bufnr))
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(first))
    assert.are.same(instance:get_pos("c.txt"), vim.api.nvim_win_get_cursor(second))
  end)

  it("does not move another tab or defer a cursor when the target tab is hidden", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c" })
    instance:open()
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(other_window, instance:get_pos("a.txt"))

    vim.cmd("tabnew")
    local current_tab = vim.api.nvim_get_current_tabpage()
    assert.are_not.equal(other_tab, current_tab)
    assert.are_not.equal(instance.bufnr, vim.api.nvim_get_current_buf())

    instance:reveal("c.txt")
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(other_window))

    instance:open()
    assert.are.equal(current_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(instance.bufnr, vim.api.nvim_get_current_buf())
    assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    assert.are_not.same(instance:get_pos("c.txt"), vim.api.nvim_win_get_cursor(0))
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(other_window))
  end)

  it("allows modified visible reveal but synchronously rejects required expansion", function()
    local instance = ready({ ["a.txt"] = "a", ["dir/child.txt"] = "x" })
    instance:open()
    local physical = lines(instance)
    set_line(instance, 1, physical[1] .. " draft")
    local draft = lines(instance)
    local directory = instance.nodes_by_path[fixture:path("dir")]

    instance:reveal("a.txt")
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(0))
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)

    local err = error_text(function() instance:reveal("dir/child.txt") end)
    assert.is_truthy(err:find("buffer is modified", 1, true))
    assert.is_false(directory.expanded)
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
  end)

  it("suppresses stale reveal cursor completion while allowing old cache loads", function()
    fixture:tree({
      ["a-new/target.txt"] = "new",
      ["z-old/target.txt"] = "old",
    })
    local adapter, _, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root)
    wait_ready(instance)
    local old_path = fixture:path("z-old")
    local new_path = fixture:path("a-new")

    instance:open()
    instance:reveal("z-old/target.txt")
    wait_for(function() return pending[old_path] and pending[old_path][1] end)
    instance:reveal("a-new/target.txt")
    wait_for(function() return pending[new_path] and pending[new_path][1] end)
    release(new_path)
    wait_for(function()
      return vim.deep_equal(instance:get_pos("a-new/target.txt"), vim.api.nvim_win_get_cursor(0))
    end)
    local selected = vim.api.nvim_win_get_cursor(0)

    release(old_path)
    wait_for(function() return instance:get_pos("z-old/target.txt") ~= nil end)
    assert.are.same(selected, vim.api.nvim_win_get_cursor(0))
    assert.are.same(instance:get_pos("a-new/target.txt"), vim.api.nvim_win_get_cursor(0))
  end)
end)
