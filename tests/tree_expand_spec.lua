local buffer = require("fre.buffer")
local columns = require("fre.columns")
local fre = require("fre")
local real_fs = require("fre.fs").default
local path = require("fre.path")
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
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
end

local function projected_paths(instance)
  local result = {}
  for row = 1, #instance.view.visible_nodes do
    result[#result + 1] = assert(buffer.decode(instance, row)).path
  end
  return result
end

local function deferred_loader()
  local pending = {}
  local counts = {}
  local adapter = {
    load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      real_fs.load(scan_path, function(...)
        local args = { n = select("#", ...), ... }
        pending[scan_path] = pending[scan_path] or {}
        pending[scan_path][#pending[scan_path] + 1] = function(override_error)
          if override_error then done(override_error)
          else done(unpack(args, 1, args.n)) end
        end
      end)
    end,
  }
  local function release(scan_path, index, override_error)
    index = index or 1
    wait_for(function()
      return pending[scan_path] ~= nil and pending[scan_path][index] ~= nil
    end)
    local callback = pending[scan_path][index]
    callback(override_error)
  end
  return adapter, counts, pending, release
end

local function custom_value_column(render)
  return columns.custom({
    id = "value",
    render = render,
    parse = function(suffix)
      local value, rest = suffix:match("^(%S+) +(.*)$")
      return value, rest
    end,
    equals = function(entry, value, ctx)
      return value == ctx.descriptor.render(entry, ctx)
    end,
  })
end

local function snapshot(instance, node)
  local extmarks = vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {})
  return {
    lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false),
    baseline = vim.deepcopy(instance.view.baseline),
    extmarks = extmarks,
    expanded = node.expanded,
    load_generation = node.load_generation,
    projection_generation = instance.view.projection_generation,
  }
end

local function assert_snapshot(instance, node, expected)
  assert.are.same(expected.lines, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
  assert.are.same(expected.baseline, instance.view.baseline)
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}))
  assert.are.equal(expected.expanded, node.expanded)
  assert.are.equal(expected.load_generation, node.load_generation)
  assert.are.equal(expected.projection_generation, instance.view.projection_generation)
end

describe("fre directory tree expansion", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then instance:destroy() end
    end
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("loads a deep path segment-by-segment into one instance-local tree", function()
    fixture:tree({
      ["src"] = true,
      ["src/x"] = true,
      ["src/x/y"] = true,
      ["src/x/y/deep.txt"] = "x",
      ["root.txt"] = "r",
    })
    local counts = {}
    fre._set_fs_adapter({
      load = function(scan_path, done)
        counts[scan_path] = (counts[scan_path] or 0) + 1
        real_fs.load(scan_path, done)
      end,
    })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("src/x/y")
    wait_for(function() return instance:get_pos("src/x/y/deep.txt") ~= nil end)

    assert.are.same({ "src/", "src/x/", "src/x/y/", "src/x/y/deep.txt", "root.txt" },
      projected_paths(instance))
    assert.are.equal(1, counts[instance.root])
    assert.are.equal(1, counts[path.resolve(instance.root, "src")])
    assert.are.equal(1, counts[path.resolve(instance.root, "src/x")])
    assert.are.equal(1, counts[path.resolve(instance.root, "src/x/y")])
    local deep = instance.nodes_by_path[path.resolve(instance.root, "src/x/y/deep.txt")]
    assert.is_true(deep.id > 0)
    assert.are.equal(instance.nodes_by_id[deep.id], deep)
    assert.are.equal(instance.nodes_by_path[deep.path], deep)
    assert.are.equal(instance.nodes_by_id[deep.parent_id], deep.parent)
    assert.are.equal("loaded", instance.nodes_by_path[path.resolve(instance.root, "src/x/y")].load_state)
  end)

  it("shares pending directory prefixes so each is scanned once", function()
    fixture:tree({
      ["src/x/a"] = true,
      ["src/x/b"] = true,
      ["src/x/a/one.txt"] = "1",
      ["src/x/b/two.txt"] = "2",
    })
    local adapter, counts, _, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root)
    wait_ready(instance)
    local src = path.resolve(instance.root, "src")
    local x = path.resolve(instance.root, "src/x")
    local a = path.resolve(instance.root, "src/x/a")
    local b = path.resolve(instance.root, "src/x/b")

    instance:expand("src/x/a")
    instance:expand("src/x/b")
    assert.are.equal(1, counts[src])
    release(src)
    wait_for(function() return counts[x] == 1 end)
    release(x)
    wait_for(function() return counts[a] == 1 and counts[b] == 1 end)
    release(a)
    release(b)
    wait_for(function() return instance:get_pos("src/x/b/two.txt") ~= nil end)

    assert.are.equal(1, counts[src])
    assert.are.equal(1, counts[x])
    assert.are.same({
      "src/", "src/x/", "src/x/a/", "src/x/a/one.txt",
      "src/x/b/", "src/x/b/two.txt",
    }, projected_paths(instance))
  end)

  it("projects nested and parallel expanded branches in parent-local DFS order", function()
    fixture:tree({
      ["a/n/z.txt"] = "z",
      ["a/a.txt"] = "a",
      ["b/y.txt"] = "y",
      ["c.txt"] = "c",
    })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("a/n")
    instance:expand("b")
    wait_for(function()
      return instance:get_pos("a/n/z.txt") ~= nil and instance:get_pos("b/y.txt") ~= nil
    end)
    assert.are.same({
      "a/", "a/n/", "a/n/z.txt", "a/a.txt", "b/", "b/y.txt", "c.txt",
    }, projected_paths(instance))
  end)

  it("collapses only contiguous descendants and restores cached deep expansion immediately", function()
    fixture:tree({
      ["a/n/z.txt"] = "z",
      ["a/a.txt"] = "a",
      ["b/y.txt"] = "y",
    })
    local counts = {}
    fre._set_fs_adapter({
      load = function(scan_path, done)
        counts[scan_path] = (counts[scan_path] or 0) + 1
        real_fs.load(scan_path, done)
      end,
    })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("a/n")
    instance:expand("b")
    wait_for(function() return instance:get_pos("a/n/z.txt") ~= nil end)
    local a = instance.nodes_by_path[fixture:path("a")]
    local nested = instance.nodes_by_path[fixture:path("a", "n")]
    local nested_id = nested.id
    local z_id = instance.nodes_by_path[fixture:path("a", "n", "z.txt")].id
    assert.are.equal(4, a.visible_size)

    instance:collapse("a")
    assert.are.same({ "a/", "b/", "b/y.txt" }, projected_paths(instance))
    assert.are.equal("interval", instance.view.last_patch.kind)
    assert.is_false(a.expanded)
    assert.is_true(nested.expanded)
    assert.are.equal(1, a.visible_size)
    assert.is_nil(instance:get_pos("a/n"))
    assert.are.equal(nested, instance.nodes_by_id[nested_id])
    assert.are.equal(z_id, instance.nodes_by_path[fixture:path("a", "n", "z.txt")].id)

    local before = counts[fixture:path("a")] or 0
    instance:expand("a")
    assert.are.same({
      "a/", "a/n/", "a/n/z.txt", "a/a.txt", "b/", "b/y.txt",
    }, projected_paths(instance))
    assert.are.equal("interval", instance.view.last_patch.kind)
    assert.is_not_nil(instance:get_pos("a/n/z.txt"))
    assert.is_true(nested.expanded)
    assert.are.equal(before + 1, counts[fixture:path("a")] or 0)
  end)

  it("restores cached descendants immediately and reconciles a background rescan safely", function()
    fixture:tree({ ["a/n/z.txt"] = "z" })
    local adapter, counts, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root)
    wait_ready(instance)
    local a_path = path.resolve(instance.root, "a")
    local n_path = path.resolve(instance.root, "a/n")

    instance:expand("a/n")
    release(a_path)
    release(n_path)
    wait_for(function() return instance:get_pos("a/n/z.txt") ~= nil end)
    local nested_id = instance.nodes_by_path[n_path].id
    local z_path = path.resolve(instance.root, "a/n/z.txt")
    local z_id = instance.nodes_by_path[z_path].id

    instance:collapse("a")
    fixture:write("a/new.txt", "new")
    instance:expand("a")
    assert.are.same({ "a/", "a/n/", "a/n/z.txt" }, projected_paths(instance))
    assert.is_not_nil(instance:get_pos("a/n/z.txt"))
    assert.are.equal("refreshing", instance.nodes_by_path[a_path].load_state)
    wait_for(function() return pending[a_path] and pending[a_path][2] end)
    release(a_path, 2)
    wait_for(function() return instance:get_pos("a/new.txt") ~= nil end)
    assert.are.equal(nested_id, instance.nodes_by_path[n_path].id)
    assert.are.equal(z_id, instance.nodes_by_path[z_path].id)
    assert.are.equal(2, counts[a_path])

    instance:collapse("a")
    instance:expand("a")
    assert.are.same({ "a/", "a/n/", "a/n/z.txt", "a/new.txt" }, projected_paths(instance))
    wait_for(function() return pending[a_path] and pending[a_path][3] end)
    local original_notify = vim.notify
    local notice
    vim.notify = function(message) notice = message end
    release(a_path, 3, "rescan failed")
    wait_for(function() return instance.nodes_by_path[a_path].load_state == "loaded" end)
    vim.notify = original_notify
    assert.is_truthy(instance._last_async_error:find("rescan failed", 1, true))
    assert.is_truthy(notice:find("rescan failed", 1, true))
    assert.are.same({ "a/", "a/n/", "a/n/z.txt", "a/new.txt" }, projected_paths(instance))
    assert.are.equal(z_id, instance.nodes_by_path[z_path].id)
  end)

  it("restores retryable load state when completions become unsafe", function()
    fixture:tree({ ["dir/child.txt"] = "x", ["idle/x.txt"] = "x" })
    local adapter, _, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root)
    wait_ready(instance)
    local dir_path = path.resolve(instance.root, "dir")
    local idle_path = path.resolve(instance.root, "idle")
    local original = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)

    instance:expand("dir")
    wait_for(function() return pending[dir_path] and pending[dir_path][1] end)
    vim.api.nvim_buf_set_lines(instance.bufnr, 0, 1, false, { original[1] .. " draft" })
    release(dir_path, 1)
    wait_for(function() return instance.nodes_by_path[dir_path].load_state == "unloaded" end)
    assert.are.equal(0, #(instance.nodes_by_path[dir_path]._load_waiters or {}))
    assert.is_nil(instance.nodes_by_path[path.resolve(instance.root, "dir/child.txt")])
    assert.is_true(vim.bo[instance.bufnr].modified)

    vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, original)
    vim.bo[instance.bufnr].modified = false
    instance:expand("dir")
    wait_for(function() return pending[dir_path] and pending[dir_path][2] end)
    release(dir_path, 2)
    wait_for(function() return instance:get_pos("dir/child.txt") ~= nil end)

    instance:collapse("dir")
    instance:expand("dir")
    wait_for(function() return pending[dir_path] and pending[dir_path][3] end)
    instance.actions = { write = true }
    release(dir_path, 3)
    wait_for(function() return instance.nodes_by_path[dir_path].load_state == "loaded" end)
    assert.is_not_nil(instance:get_pos("dir/child.txt"))
    assert.are.equal(0, #(instance.nodes_by_path[dir_path]._load_waiters or {}))
    instance.actions = nil

    instance:expand("idle")
    wait_for(function() return pending[idle_path] and pending[idle_path][1] end)
    instance:collapse("idle")
    assert.are.equal("unloaded", instance.nodes_by_path[idle_path].load_state)
    assert.are.equal(0, #(instance.nodes_by_path[idle_path]._load_waiters or {}))
    release(idle_path, 1)
    vim.wait(30, function() return false end, 10)
    assert.are.equal("unloaded", instance.nodes_by_path[idle_path].load_state)
    assert.is_nil(instance.nodes_by_path[path.resolve(instance.root, "idle/x.txt")])
  end)

  it("rejects expand collapse and toggle synchronously while modified without state changes", function()
    fixture:tree({ ["dir/file.txt"] = "x" })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/file.txt") ~= nil end)
    local dir = instance.nodes_by_path[fixture:path("dir")]

    local physical = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(instance.bufnr, 0, 1, false, { physical[1] .. " draft" })
    assert.is_true(vim.bo[instance.bufnr].modified)
    local expected = snapshot(instance, dir)
    for _, operation in ipairs({
      function() instance:expand("dir") end,
      function() instance:collapse("dir") end,
      function() instance:toggle_expand("dir") end,
    }) do
      local ok, err = pcall(operation)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("buffer is modified", 1, true))
      assert_snapshot(instance, dir, expected)
      assert.is_true(vim.bo[instance.bufnr].modified)
    end
  end)

  it("rejects files and symlinks as expandable directories", function()
    local target = fixture:write("target.txt", "x")
    local link, link_err = fixture:symlink(target, "link.txt")
    fixture:write("file.txt", "x")
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))

    local ok, err = pcall(function() instance:expand("file.txt") end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("file", 1, true))
    assert.is_truthy(tostring(err):find("cannot be expanded", 1, true))
    if link then
      ok, err = pcall(function() instance:toggle_expand("link.txt") end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("symlink", 1, true))
      assert.is_truthy(tostring(err):find("cannot be expanded", 1, true))
    else
      assert.is_truthy(link_err)
    end
  end)

  it("suppresses stale and duplicate load callbacks after collapse and re-expand", function()
    fixture:tree({ ["dir/child.txt"] = "x" })
    local adapter, counts, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    release(instance.root)
    wait_ready(instance)
    local dir_path = path.resolve(instance.root, "dir")

    instance:expand("dir")
    wait_for(function() return pending[dir_path] and pending[dir_path][1] end)
    local dir = instance.nodes_by_path[dir_path]
    local first_generation = dir.load_generation
    instance:collapse("dir")
    instance:expand("dir")
    assert.is_true(dir.load_generation > first_generation)
    wait_for(function() return pending[dir_path][2] ~= nil end)

    release(dir_path, 1)
    vim.wait(50, function() return false end, 10)
    assert.is_nil(instance.nodes_by_path[path.resolve(instance.root, "dir/child.txt")])
    assert.is_nil(instance:get_pos("dir/child.txt"))
    release(dir_path, 2)
    wait_for(function() return instance:get_pos("dir/child.txt") ~= nil end)
    assert.are.equal(2, counts[dir_path])

    -- The adapter completion itself is one-shot even if an adapter violates its callback contract.
    pending[dir_path][1]()
    vim.wait(30, function() return false end, 10)
    assert.are.equal(2, counts[dir_path])
    assert.are.same({ "dir/", "dir/child.txt" }, projected_paths(instance))
  end)

  it("patches one contiguous interval when projection widths are unchanged", function()
    fixture:tree({ ["d/file.txt"] = "x", ["tail.txt"] = "t" })
    local descriptor = custom_value_column(function() return "x" end)
    local instance = wait_ready(keep(fre.new({ root = fixture.root, columns = { descriptor } })))
    instance:expand("d")
    wait_for(function() return instance:get_pos("d/file.txt") ~= nil end)
    assert.are.equal("interval", instance.view.last_patch.kind)
    assert.are.equal(2, instance.view.last_patch.start_row)
    assert.are.same({ "d/", "d/file.txt", "tail.txt" }, projected_paths(instance))
    assert.is_false(vim.bo[instance.bufnr].modified)

    instance:collapse("d")
    assert.are.equal("interval", instance.view.last_patch.kind)
    assert.are.equal(2, instance.view.last_patch.start_row)
    assert.are.same({ "d/", "tail.txt" }, projected_paths(instance))
  end)

  it("recomputes full projection column widths on expansion and collapse", function()
    fixture:tree({ ["d/very-long-name.txt"] = "x", ["x"] = "x" })
    local descriptor = custom_value_column(function(entry) return entry.name end)
    local instance = wait_ready(keep(fre.new({ root = fixture.root, columns = { descriptor } })))
    assert.are.equal(1, instance.view.column_widths[1])
    instance:expand("d")
    wait_for(function() return instance:get_pos("d/very-long-name.txt") ~= nil end)
    assert.are.equal(#"very-long-name.txt", instance.view.column_widths[1])
    assert.are.equal("full", instance.view.last_patch.kind)
    local first = buffer.decode(instance, 1)
    assert.are.equal("d", first.column_values.value)

    instance:collapse("d")
    assert.are.equal(1, instance.view.column_widths[1])
    assert.are.equal("full", instance.view.last_patch.kind)
    assert.are.same({ "d/", "x" }, projected_paths(instance))
  end)

  it("keeps baseline positions extmarks and visible ranges consistent", function()
    fixture:tree({ ["a/n/z.txt"] = "z", ["b.txt"] = "b" })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("a/n")
    wait_for(function() return instance:get_pos("a/n/z.txt") ~= nil end)

    assert.are.equal(#instance.view.visible_nodes, instance.root_node.visible_size)
    for row, node in ipairs(instance.view.visible_nodes) do
      local decoded = buffer.decode(instance, row)
      local relative = assert(path.relative(instance.root, node.path))
      assert.are.equal(node.id, decoded.entry.node_id)
      assert.are.equal(node.path, instance.view.baseline[node.id])
      assert.are.equal(row, buffer.hint_row(instance, node))
      assert.are.same({ row, decoded.path_range.start_byte }, instance:get_pos(relative))
      assert.are.equal(row, node.visible_start)
      assert.is_true(node.visible_end >= node.visible_start)
      assert.are.equal(node.visible_end - node.visible_start + 1, node.visible_size)
      assert.are.same({ start_row = node.visible_start, end_row = node.visible_end }, node.visible_range)
    end
    assert.is_false(vim.bo[instance.bufnr].modified)

    local nested = instance.nodes_by_path[fixture:path("a", "n")]
    instance:collapse("a")
    assert.is_nil(nested.row_extmark)
    assert.is_nil(nested.visible_range)
    assert.are.equal(0, nested.visible_size)
    assert.is_nil(instance.view.baseline[nested.id])
    assert.is_nil(instance:get_pos("a/n"))
    assert.is_false(vim.bo[instance.bufnr].modified)
  end)
end)
