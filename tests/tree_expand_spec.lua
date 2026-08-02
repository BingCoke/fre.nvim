local buffer = require("fre.instance.buffer")
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
    return instance:status() == "ready"
      or instance:status() == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance:status(), tostring(instance:failure()))
  return instance
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
    baseline = vim.deepcopy(instance.buffer.view.baseline),
    projection_ranges = vim.deepcopy(instance.buffer.projection_ranges),
    row_extmarks = vim.deepcopy(instance.buffer.row_extmarks),
    extmarks = extmarks,
    expanded = node.expanded,
    load_generation = node.load_generation,
    projection_generation = instance.buffer.view.projection_generation,
  }
end

local function assert_snapshot(instance, node, expected)
  assert.are.same(expected.lines, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
  assert.are.same(expected.baseline, instance.buffer.view.baseline)
  assert.are.same(expected.projection_ranges, instance.buffer.projection_ranges)
  assert.are.same(expected.row_extmarks, instance.buffer.row_extmarks)
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}))
  assert.are.equal(expected.expanded, node.expanded)
  assert.are.equal(expected.load_generation, node.load_generation)
  assert.are.equal(expected.projection_generation, instance.buffer.view.projection_generation)
end

describe("fre directory tree expansion", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if instance:status() ~= "destroyed" then instance:destroy() end
    end
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("applies configured expansions before delivering readiness", function()
    fixture:tree({ ["src/x/deep.txt"] = "x", ["other.txt"] = "o" })
    local adapter, _, _, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local requested = { "src", "src/x" }
    local callback_count = 0
    local callback_error
    local instance = keep(fre.new({
      root = fixture.root,
      expanded = requested,
    }))
    instance:when_ready(function(err)
      callback_count = callback_count + 1
      callback_error = err
    end)
    requested[1] = "other"

    release(instance.root)
    release(path.resolve(instance.root, "src"))
    assert.are.equal("creating", instance:status())
    assert.are.equal(0, callback_count)
    release(path.resolve(instance.root, "src/x"))

    wait_ready(instance)
    wait_for(function() return callback_count == 1 end)
    assert.is_nil(callback_error)
    assert.are.same({ "src", "src/x" }, instance.config.expanded)
    assert.is_not_nil(instance:get_pos("src/x/deep.txt"))
    assert.is_true(instance.tree.nodes_by_path[fixture:path("src")].expanded)
    assert.is_true(instance.tree.nodes_by_path[fixture:path("src", "x")].expanded)
  end)

  it("reports configured expansion load failures through readiness", function()
    fixture:tree({ ["src/deep.txt"] = "x" })
    local adapter, _, _, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local callback_count = 0
    local callback_error
    local event
    vim.api.nvim_create_autocmd("User", {
      pattern = "FreReady",
      once = true,
      callback = function(args) event = args.data end,
    })
    local instance = keep(fre.new({
      root = fixture.root,
      expanded = { "src" },
    }))
    instance:when_ready(function(err)
      callback_count = callback_count + 1
      callback_error = err
    end)

    release(instance.root)
    release(path.resolve(instance.root, "src"), nil, "configured expansion exploded")
    wait_for(function() return instance:status() == "load-failed" and callback_count == 1 and event end)

    assert.is_truthy(tostring(instance:failure()):find("initial expansion failed for src", 1, true))
    assert.is_truthy(tostring(callback_error):find("configured expansion exploded", 1, true))
    assert.are.equal(instance.id, event.instance_id)
    assert.are.equal(instance:failure(), event.error)
  end)

  it("waits for configured single-directory suffixes before readiness", function()
    fixture:tree({ ["src/one/two/end.txt"] = "x" })
    local adapter, counts, _, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local callback_count = 0
    local instance = keep(fre.new({
      root = fixture.root,
      expanded = { "src" },
      auto_expand_single_directory = true,
    }))
    instance:when_ready(function() callback_count = callback_count + 1 end)

    local src = fixture:path("src")
    local one = fixture:path("src", "one")
    local two = fixture:path("src", "one", "two")
    release(instance.root)
    release(src)
    release(one)
    assert.are.equal("creating", instance:status())
    assert.are.equal(0, callback_count)
    release(two)
    wait_ready(instance)
    wait_for(function() return callback_count == 1 end)
    assert.are.equal(1, counts[src])
    assert.are.equal(1, counts[one])
    assert.are.equal(1, counts[two])
    assert.is_true(instance.tree.nodes_by_path[src].expanded)
    assert.is_true(instance.tree.nodes_by_path[one].expanded)
    assert.is_true(instance.tree.nodes_by_path[two].expanded)
  end)

  it("retries configured automatic suffixes before becoming ready", function()
    fixture:tree({ ["src/one/two/end.txt"] = "x" })
    local adapter, counts, _, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({
      root = fixture.root,
      expanded = { "src" },
      auto_expand_single_directory = true,
    }))
    local src = fixture:path("src")
    local one = fixture:path("src", "one")
    local two = fixture:path("src", "one", "two")

    release(instance.root)
    release(src)
    release(one, 1, "automatic suffix failed")
    wait_for(function() return instance:status() == "load-failed" end)

    local refresh_done, refresh_error = false, nil
    instance:refresh({ on_complete = function(err)
      refresh_done = true
      refresh_error = err
    end })
    release(instance.root, 2)
    wait_for(function() return counts[src] == 2 end)
    assert.are.equal("creating", instance:status())
    assert.is_false(refresh_done)
    release(src, 2)
    wait_for(function() return counts[one] == 2 end)
    assert.are.equal("creating", instance:status())
    assert.is_false(refresh_done)
    release(one, 2)
    wait_for(function() return counts[two] == 1 end)
    assert.are.equal("creating", instance:status())
    assert.is_false(refresh_done)
    release(two)

    wait_ready(instance)
    wait_for(function() return refresh_done end)
    assert.is_nil(refresh_error)
    assert.are.equal(2, counts[src])
    assert.are.equal(2, counts[one])
    assert.are.equal(1, counts[two])
    assert.is_true(instance.tree.nodes_by_path[src].expanded)
    assert.is_true(instance.tree.nodes_by_path[one].expanded)
    assert.is_true(instance.tree.nodes_by_path[two].expanded)
    assert.is_not_nil(instance:get_pos("src/one/two/end.txt"))
  end)

  it("requires exactly one total direct child before automatic expansion", function()
    local target = fixture:write("target.txt", "x")
    fixture:tree({
      ["pure/com/xxx/xx/src/end.txt"] = "x",
      ["directory-file/only/end.txt"] = "x",
      ["directory-file/file.txt"] = "x",
      ["directory-symlink/only/end.txt"] = "x",
      ["directory-hidden-file/only/end.txt"] = "x",
      ["directory-hidden-file/.marker"] = "x",
      ["directory-hidden-directory/only/end.txt"] = "x",
      ["directory-hidden-directory/.secret/end.txt"] = "x",
      ["multiple/a/end.txt"] = "a",
      ["multiple/b/end.txt"] = "b",
      ["sole-file/file.txt"] = "x",
      ["hidden-only/.secret/end.txt"] = "x",
      ["off/only/end.txt"] = "x",
    })
    local directory_link = fixture:symlink(target, "directory-symlink/link")
    local sole_link = fixture:symlink(target, "sole-symlink/link")
    local enabled = wait_ready(keep(fre.new({
      root = fixture.root, auto_expand_single_directory = true,
    })))
    local function expand_and_wait(relative)
      enabled:expand(relative)
      local absolute = fixture:path(relative)
      wait_for(function() return enabled.tree.nodes_by_path[absolute].loaded end)
      return enabled.tree.nodes_by_path[absolute]
    end
    local function assert_directory_stopped(parent, child)
      expand_and_wait(parent)
      assert.is_false(enabled.tree.nodes_by_path[fixture:path(parent, child)].expanded)
      assert.is_nil(enabled:get_pos(parent .. "/" .. child .. "/end.txt"))
    end

    enabled:expand("pure")
    wait_for(function() return enabled:get_pos("pure/com/xxx/xx/src/end.txt") ~= nil end)
    for _, relative in ipairs({
      "pure/com", "pure/com/xxx", "pure/com/xxx/xx", "pure/com/xxx/xx/src",
    }) do
      assert.is_true(enabled.tree.nodes_by_path[fixture:path(relative)].expanded)
    end

    assert_directory_stopped("directory-file", "only")
    assert_directory_stopped("directory-hidden-file", "only")
    assert_directory_stopped("directory-hidden-directory", "only")
    assert_directory_stopped("multiple", "a")
    assert.is_false(enabled.tree.nodes_by_path[fixture:path("multiple", "b")].expanded)

    if directory_link then
      assert_directory_stopped("directory-symlink", "only")
      assert.are.equal("symlink", enabled.tree.nodes_by_path[directory_link].kind)
    end

    local sole_file = expand_and_wait("sole-file")
    assert.are.equal(1, #sole_file.children_order)
    assert.are.equal("file", sole_file.children_order[1].kind)

    local hidden_only = expand_and_wait("hidden-only")
    assert.are.equal(1, #hidden_only.children_order)
    assert.is_false(enabled.tree.nodes_by_path[fixture:path("hidden-only", ".secret")].expanded)

    if sole_link then
      local sole_symlink = expand_and_wait("sole-symlink")
      assert.are.equal(1, #sole_symlink.children_order)
      assert.are.equal("symlink", sole_symlink.children_order[1].kind)
    end

    local show_hidden = wait_ready(keep(fre.new({
      root = fixture.root, hidden_file = true, auto_expand_single_directory = true,
    })))
    show_hidden:expand("hidden-only")
    wait_for(function() return show_hidden:get_pos("hidden-only/.secret/end.txt") ~= nil end)
    assert.is_true(show_hidden.tree.nodes_by_path[fixture:path("hidden-only", ".secret")].expanded)

    local disabled = wait_ready(keep(fre.new({ root = fixture.root })))
    disabled:expand("off")
    wait_for(function() return disabled.tree.nodes_by_path[fixture:path("off")].loaded end)
    assert.is_false(disabled.tree.nodes_by_path[fixture:path("off", "only")].expanded)
  end)

  it("chooses from a completed fresh rescan instead of cached children", function()
    fixture:tree({ ["target/a/end.txt"] = "a", ["target/b/end.txt"] = "b" })
    local adapter, counts, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({
      root = fixture.root, auto_expand_single_directory = true,
    }))
    release(instance.root)
    wait_ready(instance)
    local target = fixture:path("target")
    local a = fixture:path("target", "a")

    instance:expand("target")
    release(target, 1)
    wait_for(function() return instance.tree.nodes_by_path[target].loaded end)
    assert.is_false(instance.tree.nodes_by_path[a].expanded)
    instance:collapse("target")
    fs.remove_tree(fixture:path("target", "b"))
    instance:expand("target")
    wait_for(function() return pending[target] and pending[target][2] end)
    assert.is_false(instance.tree.nodes_by_path[a].expanded)
    assert.are.equal(2, counts[target])
    release(target, 2)
    wait_for(function() return instance.tree.nodes_by_path[a].expanded end)
    release(a)
    wait_for(function() return instance:get_pos("target/a/end.txt") ~= nil end)
  end)

  it("preserves an expanded prefix and reports one recursive load error", function()
    fixture:tree({ ["target/only/end.txt"] = "x" })
    local adapter, _, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({
      root = fixture.root, auto_expand_single_directory = true,
    }))
    release(instance.root)
    wait_ready(instance)
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(message) notices[#notices + 1] = message end
    local target = fixture:path("target")
    local only = fixture:path("target", "only")

    instance:expand("target")
    release(target)
    wait_for(function() return pending[only] and pending[only][1] end)
    release(only, 1, "recursive load exploded")
    wait_for(function() return #notices == 1 end)
    pending[only][1]()
    vim.wait(30, function() return false end, 10)
    vim.notify = original_notify
    assert.are.equal(1, #notices)
    assert.is_true(instance.tree.nodes_by_path[target].expanded)
    assert.is_true(instance.tree.nodes_by_path[only].expanded)
    assert.is_truthy(instance._last_async_error:find("recursive load exploded", 1, true))
  end)

  it("lets collapse and collapse_all cancel recursive work without late errors", function()
    fixture:tree({ ["target/only/end.txt"] = "x" })
    local adapter, _, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({
      root = fixture.root, auto_expand_single_directory = true,
    }))
    release(instance.root)
    wait_ready(instance)
    local notices = {}
    local original_notify = vim.notify
    vim.notify = function(message) notices[#notices + 1] = message end
    local target = fixture:path("target")
    local only = fixture:path("target", "only")

    instance:expand("target")
    wait_for(function() return pending[target] and pending[target][1] end)
    instance:collapse_all()
    release(target, 1)
    vim.wait(30, function() return false end, 10)
    assert.is_false(instance.tree.nodes_by_path[target].expanded)
    assert.is_nil(instance.tree.nodes_by_path[only])

    instance:expand("target")
    release(target, 2)
    wait_for(function() return pending[only] and pending[only][1] end)
    instance:collapse("target")
    release(only, 1, "cancelled load must be ignored")
    vim.wait(30, function() return false end, 10)
    vim.notify = original_notify
    assert.is_false(instance.tree.nodes_by_path[target].expanded)
    assert.is_nil(instance:get_pos("target/only"))
    assert.are.same({}, notices)
  end)

  it("does not apply single-directory expansion to reveal", function()
    fixture:tree({ ["a/target.txt"] = "x", ["a/only/end.txt"] = "y" })
    local instance = wait_ready(keep(fre.new({
      root = fixture.root, auto_expand_single_directory = true,
    })))
    instance:reveal("a/target.txt")
    wait_for(function() return instance:get_pos("a/target.txt") ~= nil end)
    assert.is_false(instance.tree.nodes_by_path[fixture:path("a", "only")].expanded)
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
    local deep = instance.tree.nodes_by_path[path.resolve(instance.root, "src/x/y/deep.txt")]
    assert.is_true(deep.id > 0)
    assert.are.equal(instance.tree.nodes_by_id[deep.id], deep)
    assert.are.equal(instance.tree.nodes_by_path[deep.path], deep)
    assert.are.equal(instance.tree.nodes_by_id[deep.parent_id], deep.parent)
    assert.are.equal("loaded", instance.tree.nodes_by_path[path.resolve(instance.root, "src/x/y")].load_state)
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

  it("does not rescan or recurse when expanding an already-expanded directory", function()
    fixture:tree({ ["target/only/end.txt"] = "x" })
    local counts = {}
    fre._set_fs_adapter({ load = function(scan_path, done)
      counts[scan_path] = (counts[scan_path] or 0) + 1
      real_fs.load(scan_path, done)
    end })
    local instance = wait_ready(keep(fre.new({
      root = fixture.root, auto_expand_single_directory = true,
    })))
    local target_path = fixture:path("target")
    local only_path = fixture:path("target", "only")
    instance:expand("target")
    wait_for(function() return instance:get_pos("target/only/end.txt") ~= nil end)
    instance:collapse("target/only")
    local target_scans = counts[target_path]
    local only_scans = counts[only_path]

    instance:expand("target")
    vim.wait(40, function() return false end, 10)

    assert.are.equal(target_scans, counts[target_path])
    assert.are.equal(only_scans, counts[only_path])
    assert.is_true(instance.tree.nodes_by_path[target_path].expanded)
    assert.is_false(instance.tree.nodes_by_path[only_path].expanded)
  end)

  it("collapses inactive cached descendants after their ancestor is collapsed", function()
    fixture:tree({ ["a/n/deep.txt"] = "x" })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("a/n")
    wait_for(function() return instance:get_pos("a/n/deep.txt") ~= nil end)
    local a = instance.tree.nodes_by_path[fixture:path("a")]
    local n = instance.tree.nodes_by_path[fixture:path("a", "n")]

    instance:collapse("a")
    assert.is_false(instance.tree.nodes_by_id[a.id].expanded)
    assert.is_true(instance.tree.nodes_by_id[n.id].expanded)
    instance:collapse_all()

    assert.is_false(instance.tree.nodes_by_id[a.id].expanded)
    assert.is_false(instance.tree.nodes_by_id[n.id].expanded)
    assert.is_nil(instance:get_pos("a/n"))
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
    local a = instance.tree.nodes_by_path[fixture:path("a")]
    local nested = instance.tree.nodes_by_path[fixture:path("a", "n")]
    local nested_id = nested.id
    local z_id = instance.tree.nodes_by_path[fixture:path("a", "n", "z.txt")].id
    assert.are.equal(4, instance.buffer.projection_ranges[a.id].size)

    instance:collapse("a")
    assert.are.same({ "a/", "b/", "b/y.txt" }, projected_paths(instance))
    assert.are.equal("interval", instance.buffer.view.last_patch.kind)
    assert.is_false(instance.tree.nodes_by_id[a.id].expanded)
    assert.is_true(instance.tree.nodes_by_id[nested_id].expanded)
    assert.are.equal(1, instance.buffer.projection_ranges[a.id].size)
    assert.is_nil(instance:get_pos("a/n"))
    assert.are.equal(nested_id, instance.tree.nodes_by_id[nested_id].id)
    assert.are.equal(z_id, instance.tree.nodes_by_path[fixture:path("a", "n", "z.txt")].id)

    local before = counts[fixture:path("a")] or 0
    instance:expand("a")
    assert.are.same({
      "a/", "a/n/", "a/n/z.txt", "a/a.txt", "b/", "b/y.txt",
    }, projected_paths(instance))
    assert.are.equal("interval", instance.buffer.view.last_patch.kind)
    assert.is_not_nil(instance:get_pos("a/n/z.txt"))
    assert.is_true(instance.tree.nodes_by_id[nested_id].expanded)
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
    local nested_id = instance.tree.nodes_by_path[n_path].id
    local z_path = path.resolve(instance.root, "a/n/z.txt")
    local z_id = instance.tree.nodes_by_path[z_path].id

    instance:collapse("a")
    fixture:write("a/new.txt", "new")
    instance:expand("a")
    assert.are.same({ "a/", "a/n/", "a/n/z.txt" }, projected_paths(instance))
    assert.is_not_nil(instance:get_pos("a/n/z.txt"))
    assert.are.equal("refreshing", instance.tree.nodes_by_path[a_path].load_state)
    wait_for(function() return pending[a_path] and pending[a_path][2] end)
    release(a_path, 2)
    wait_for(function() return instance:get_pos("a/new.txt") ~= nil end)
    assert.are.equal(nested_id, instance.tree.nodes_by_path[n_path].id)
    assert.are.equal(z_id, instance.tree.nodes_by_path[z_path].id)
    assert.are.equal(2, counts[a_path])

    instance:collapse("a")
    instance:expand("a")
    assert.are.same({ "a/", "a/n/", "a/n/z.txt", "a/new.txt" }, projected_paths(instance))
    wait_for(function() return pending[a_path] and pending[a_path][3] end)
    local original_notify = vim.notify
    local notice
    vim.notify = function(message) notice = message end
    release(a_path, 3, "rescan failed")
    wait_for(function() return instance.tree.nodes_by_path[a_path].load_state == "loaded" end)
    vim.notify = original_notify
    assert.is_truthy(instance._last_async_error:find("rescan failed", 1, true))
    assert.is_truthy(notice:find("rescan failed", 1, true))
    assert.are.same({ "a/", "a/n/", "a/n/z.txt", "a/new.txt" }, projected_paths(instance))
    assert.are.equal(z_id, instance.tree.nodes_by_path[z_path].id)
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
    wait_for(function() return instance.tree.nodes_by_path[dir_path].load_state == "unloaded" end)
    assert.are.equal(0, #(instance.tree.nodes_by_path[dir_path]._load_waiters or {}))
    assert.is_nil(instance.tree.nodes_by_path[path.resolve(instance.root, "dir/child.txt")])
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
    local request = instance.work:_acquire_write()
    release(dir_path, 3)
    wait_for(function() return instance.tree.nodes_by_path[dir_path].load_state == "loaded" end)
    assert.is_not_nil(instance:get_pos("dir/child.txt"))
    assert.are.equal(0, #(instance.tree.nodes_by_path[dir_path]._load_waiters or {}))
    instance.work:_release_write(request)

    instance:expand("idle")
    wait_for(function() return pending[idle_path] and pending[idle_path][1] end)
    instance:collapse("idle")
    assert.are.equal("unloaded", instance.tree.nodes_by_path[idle_path].load_state)
    assert.are.equal(0, #(instance.tree.nodes_by_path[idle_path]._load_waiters or {}))
    release(idle_path, 1)
    vim.wait(30, function() return false end, 10)
    assert.are.equal("unloaded", instance.tree.nodes_by_path[idle_path].load_state)
    assert.is_nil(instance.tree.nodes_by_path[path.resolve(instance.root, "idle/x.txt")])
  end)

  it("rolls back an ordinary directory load when projection fails and retries cleanly", function()
    fixture:tree({ ["dir/child.txt"] = "x" })
    local child_path = fixture:path("dir", "child.txt")
    local fail_render = true
    local descriptor = custom_value_column(function(entry)
      if fail_render and path.equal(entry.absolute_path, child_path) then
        error("directory render exploded")
      end
      return entry.name
    end)
    local adapter, counts, pending, release = deferred_loader()
    fre._set_fs_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root, columns = { descriptor } }))
    release(instance.root)
    wait_ready(instance)

    local dir_path = fixture:path("dir")
    local dir = instance.tree.nodes_by_path[dir_path]
    instance:expand("dir")
    wait_for(function() return pending[dir_path] and pending[dir_path][1] end)
    local expected = snapshot(instance, dir)
    local next_node_id = instance.tree:latest_node_id()
    release(dir_path, 1)
    wait_for(function()
      return dir.load_state == "unloaded" and instance._last_async_error
        and instance._last_async_error:find("directory render exploded", 1, true)
    end)
    assert_snapshot(instance, dir, expected)
    assert.is_true(instance.tree:latest_node_id() > next_node_id)
    assert.is_false(dir.loaded)
    assert.is_false(dir.children_cached)
    assert.is_nil(instance.tree.nodes_by_path[child_path])
    assert.are.equal(1, counts[dir_path])

    fail_render = false
    instance:expand("dir")
    wait_for(function() return pending[dir_path] and pending[dir_path][2] end)
    release(dir_path, 2)
    wait_for(function() return instance:get_pos("dir/child.txt") ~= nil end)
    assert.are.equal(2, counts[dir_path])
    assert.are.equal("loaded", instance.tree.nodes_by_id[dir.id].load_state)
  end)

  it("keeps the live Tree unchanged when an expansion projection commit fails", function()
    fixture:tree({ ["dir/file.txt"] = "x" })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/file.txt") ~= nil end)
    local dir = instance.tree:node_by_path(fixture:path("dir"))
    local before_view = instance.buffer.view
    local original_commit = instance.buffer.commit
    instance.buffer.commit = function() return false end

    local ok, err = pcall(instance.collapse, instance, "dir")
    instance.buffer.commit = original_commit

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("buffer projection commit failed", 1, true))
    assert.is_true(instance.tree:node_by_id(dir.id).expanded)
    assert.is_not_nil(instance:get_pos("dir/file.txt"))
    assert.are.equal(before_view, instance.buffer.view)
  end)


  it("starts a fresh undo history after expand and collapse projections", function()
    fixture:tree({ ["dir/file.txt"] = "x" })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))

    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/file.txt") ~= nil end)
    local expanded = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    vim.api.nvim_buf_call(instance.bufnr, function() vim.cmd("silent! undo") end)
    assert.are.same(expanded, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
    assert.is_false(vim.bo[instance.bufnr].modified)

    instance:collapse("dir")
    local collapsed = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    vim.api.nvim_buf_call(instance.bufnr, function() vim.cmd("silent! undo") end)
    assert.are.same(collapsed, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
    assert.is_false(vim.bo[instance.bufnr].modified)
  end)

  it("rejects expand collapse and toggle synchronously while modified without state changes", function()
    fixture:tree({ ["dir/file.txt"] = "x" })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/file.txt") ~= nil end)
    local dir = instance.tree.nodes_by_path[fixture:path("dir")]

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
    local dir = instance.tree.nodes_by_path[dir_path]
    local first_generation = dir.load_generation
    instance:collapse("dir")
    instance:expand("dir")
    assert.is_true(instance.tree.nodes_by_id[dir.id].load_generation > first_generation)
    wait_for(function() return pending[dir_path][2] ~= nil end)

    release(dir_path, 1)
    vim.wait(50, function() return false end, 10)
    assert.is_nil(instance.tree.nodes_by_path[path.resolve(instance.root, "dir/child.txt")])
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
    assert.are.equal("interval", instance.buffer.view.last_patch.kind)
    assert.are.equal(instance:get_pos("d/file.txt")[1], instance.buffer.view.last_patch.start_row)
    assert.are.same({ "d/", "d/file.txt", "tail.txt" }, projected_paths(instance))
    assert.is_false(vim.bo[instance.bufnr].modified)

    instance:collapse("d")
    assert.are.equal("interval", instance.buffer.view.last_patch.kind)
    assert.are.equal(instance:get_pos("d")[1] + 1, instance.buffer.view.last_patch.start_row)
    assert.are.same({ "d/", "tail.txt" }, projected_paths(instance))
  end)

  it("recomputes full projection column widths on expansion and collapse", function()
    fixture:tree({ ["d/very-long-name.txt"] = "x", ["x"] = "x" })
    local descriptor = custom_value_column(function(entry) return entry.name end)
    local instance = wait_ready(keep(fre.new({ root = fixture.root, columns = { descriptor } })))
    assert.are.equal(2, instance.buffer.view.column_widths[1])
    instance:expand("d")
    wait_for(function() return instance:get_pos("d/very-long-name.txt") ~= nil end)
    assert.are.equal(#"very-long-name.txt", instance.buffer.view.column_widths[1])
    assert.are.equal("full", instance.buffer.view.last_patch.kind)
    local first = instance.buffer:decode(instance:get_pos("d")[1])
    assert.are.equal("d", first.column_values.value)

    instance:collapse("d")
    assert.are.equal(2, instance.buffer.view.column_widths[1])
    assert.are.equal("full", instance.buffer.view.last_patch.kind)
    assert.are.same({ "d/", "x" }, projected_paths(instance))
  end)

  it("keeps baseline positions extmarks and visible ranges consistent", function()
    fixture:tree({ ["a/n/z.txt"] = "z", ["b.txt"] = "b" })
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    instance:expand("a/n")
    wait_for(function() return instance:get_pos("a/n/z.txt") ~= nil end)

    for row, node in ipairs(instance.buffer.view.visible_nodes) do
      local buffer_row = row + instance.buffer.view.row_offset
      local decoded = instance.buffer:decode(buffer_row)
      local relative = assert(path.relative(instance.root, node.path))
      local range = assert(instance.buffer.projection_ranges[node.id])
      assert.are.equal(node.id, decoded.entry.node_id)
      assert.are.equal(node.path, instance.buffer.view.baseline[node.id])
      assert.are.equal(buffer_row, buffer.hint_row(instance.buffer, node))
      assert.are.same({ buffer_row, decoded.path_range.start_byte }, instance:get_pos(relative))
      assert.are.equal(row, range.start_row)
      assert.is_true(range.end_row >= range.start_row)
      assert.are.equal(range.end_row - range.start_row + 1, range.size)
    end
    assert.is_false(vim.bo[instance.bufnr].modified)

    local nested = instance.tree.nodes_by_path[fixture:path("a", "n")]
    instance:collapse("a")
    assert.is_nil(instance.buffer.row_extmarks[nested.id])
    assert.is_nil(instance.buffer.projection_ranges[nested.id])
    assert.is_nil(instance.buffer.view.baseline[nested.id])
    assert.is_nil(instance:get_pos("a/n"))
    assert.is_false(vim.bo[instance.bufnr].modified)
  end)
end)
