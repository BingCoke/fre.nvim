local actions = require("fre.actions")
local buffer = require("fre.buffer")
local fre = require("fre")
local move_graph = require("fre.mutation.move_graph")
local mutation_fs = require("fre.mutation.fs")
local mutation_prepare = require("fre.mutation.prepare")
local path = require("fre.path")
local fs = require("tests.helpers.fs")

local fixture
local instances = {}
local original_notify

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(4000, predicate, 10))
end

local function ready(entries)
  fixture:tree(entries or {})
  local instance = keep(fre.new({ root = fixture.root, columns = {} }))
  wait_for(function()
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
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

local function row_for(instance, relative)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = buffer.decode(instance, row)
    if decoded and decoded.marked and decoded.entry.relative_path == relative then return row end
  end
  error("missing row " .. relative)
end

local function physical_line(instance, relative)
  return lines(instance)[row_for(instance, relative)]
end

local function edited_line(instance, relative, target)
  local row = row_for(instance, relative)
  local physical = lines(instance)[row]
  local decoded = buffer.decode(instance, row)
  return physical:sub(1, decoded.path_range.start_byte) .. target
    .. physical:sub(decoded.path_range.end_byte + 1)
end

local function expand(instance, relative)
  instance:expand(relative)
  wait_for(function()
    local node = instance.nodes_by_path[fixture:path(relative)]
    return node and node.loaded
  end)
end

local function assert_error(fragment, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find(fragment, 1, true), tostring(err))
end

local function read_file(absolute)
  local fd = assert(vim.uv.fs_open(absolute, "r", 438))
  local stat = assert(vim.uv.fs_fstat(fd))
  local contents = assert(vim.uv.fs_read(fd, stat.size, 0))
  assert(vim.uv.fs_close(fd))
  return contents
end

local function projected_paths(instance)
  local result = {}
  for row = 1, #(instance.view.visible_nodes or {}) do
    result[#result + 1] = assert(buffer.decode(instance, row)).path
  end
  return result
end

local function write_command(instance)
  return pcall(vim.api.nvim_buf_call, instance.bufnr, function() vim.cmd("write") end)
end

local function wait_unlocked(instance)
  wait_for(function()
    return (not instance.actions or not instance.actions.write)
      and instance._refresh_request == nil and instance._execution == nil
  end)
end

local function accepting_ui()
  local ui = { confirmations = {} }
  function ui.confirm(_, display, decide)
    ui.confirmations[#ui.confirmations + 1] = vim.deepcopy(display)
    ui.decide = decide
    return { close = function() end }
  end
  function ui.progress(_, _, cancel)
    ui.cancel_progress = cancel
    return { update = function() end, close = function() end }
  end
  function ui.report() end
  actions._set_ui_adapter(ui)
  return ui
end

local function fake_plan(root_path, definitions)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local root = { id = 1, path = root_path, kind = "directory" }
  local nodes_by_id = { [1] = root }
  local baseline, visible, replacement = {}, {}, {}
  for index, definition in ipairs(definitions) do
    local id = index + 1
    local absolute = path.resolve(root_path, definition.source)
    local node = {
      id = id,
      path = absolute,
      name = definition.source,
      kind = definition.kind or "file",
      parent = root,
    }
    nodes_by_id[id] = node
    baseline[id] = absolute
    visible[#visible + 1] = node
    replacement[#replacement + 1] = buffer.marker(900, id) .. definition.target
  end
  local fake = {
    id = 900,
    bufnr = bufnr,
    root = root_path,
    root_node = root,
    state = "ready-hidden",
    config = { columns = {} },
    nodes_by_id = nodes_by_id,
    view = { baseline = baseline, visible_nodes = visible },
  }
  function fake:_entry(node)
    return {
      instance_id = self.id,
      node_id = node.id,
      absolute_path = node.path,
      relative_path = assert(path.relative(self.root, node.path)),
      name = node.name,
      kind = node.kind,
    }
  end
  fake.manager = { find_by_id = function(_, id) return id == fake.id and fake or nil end }
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, replacement)
  local ok, plan_or_error = pcall(mutation_prepare.prepare, fake)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok then error(plan_or_error, 0) end
  return plan_or_error
end

describe("fre ticket 14 move cycle lowering", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    original_notify = vim.notify
    vim.notify = function() end
    actions._reset_ui_adapter()
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
  end)

  after_each(function()
    actions._reset_ui_adapter()
    fre._reset_mutation_adapter()
    fre._reset_fs_adapter()
    vim.notify = original_notify
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then pcall(instance.destroy, instance) end
    end
    fixture:cleanup()
  end)

  it("lowers a swap through a deterministic sibling temp and keeps display user-facing", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" })
    set_lines(instance, {
      edited_line(instance, "a.txt", "b.txt"),
      edited_line(instance, "b.txt", "a.txt"),
    })
    local before_lines = lines(instance)
    local before_view = instance.view
    local temporary = fixture:path(".a.txt.fre-tmp-move-cycle-1")
    local expected = {
      operations = {
        { type = "move", from = fixture:path("a.txt"), to = temporary, kind = "file" },
        {
          type = "move", from = fixture:path("b.txt"),
          to = fixture:path("a.txt"), kind = "file",
        },
        { type = "move", from = temporary, to = fixture:path("b.txt"), kind = "file" },
      },
      display = { "MOVE  a.txt -> b.txt", "MOVE  b.txt -> a.txt" },
    }

    local first = instance:prepare()
    assert.are.same(expected, first)
    assert.are.same(expected, instance:prepare())
    assert.are.same(before_lines, lines(instance))
    assert.are.equal(before_view, instance.view)
    first.operations[1].to = "caller-mutated"
    assert.are.same(expected, instance:prepare())
    assert.are.equal(vim.fs.dirname(fixture:path("a.txt")), vim.fs.dirname(temporary))
  end)

  it("rotates a long cycle and multiple independent cycles from deterministic pivots", function()
    local instance = ready({
      ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c",
      ["d.txt"] = "d", ["e.txt"] = "e",
    })
    set_lines(instance, {
      edited_line(instance, "c.txt", "a.txt"),
      edited_line(instance, "a.txt", "b.txt"),
      edited_line(instance, "b.txt", "c.txt"),
      edited_line(instance, "e.txt", "d.txt"),
      edited_line(instance, "d.txt", "e.txt"),
    })
    local c_temp = fixture:path(".c.txt.fre-tmp-move-cycle-1")
    local e_temp = fixture:path(".e.txt.fre-tmp-move-cycle-4")
    local plan = instance:prepare()
    assert.are.same({
      { type = "move", from = fixture:path("c.txt"), to = c_temp, kind = "file" },
      { type = "move", from = fixture:path("b.txt"), to = fixture:path("c.txt"), kind = "file" },
      { type = "move", from = fixture:path("a.txt"), to = fixture:path("b.txt"), kind = "file" },
      { type = "move", from = c_temp, to = fixture:path("a.txt"), kind = "file" },
      { type = "move", from = fixture:path("e.txt"), to = e_temp, kind = "file" },
      { type = "move", from = fixture:path("d.txt"), to = fixture:path("e.txt"), kind = "file" },
      { type = "move", from = e_temp, to = fixture:path("d.txt"), kind = "file" },
    }, plan.operations)
    assert.are.same({
      "MOVE  c.txt -> a.txt", "MOVE  a.txt -> b.txt", "MOVE  b.txt -> c.txt",
      "MOVE  e.txt -> d.txt", "MOVE  d.txt -> e.txt",
    }, plan.display)
  end)

  it("lowers Windows case-only renames and leaves POSIX spelling changes as one move", function()
    local windows_plan = fake_plan("C:/Project", {
      { source = "Case.txt", target = "case.txt" },
    })
    assert.are.same({
      {
        type = "move", from = "C:/Project/Case.txt",
        to = "C:/Project/.Case.txt.fre-tmp-move-cycle-1", kind = "file",
      },
      {
        type = "move", from = "C:/Project/.Case.txt.fre-tmp-move-cycle-1",
        to = "C:/Project/case.txt", kind = "file",
      },
    }, windows_plan.operations)
    assert.are.same({ "MOVE  Case.txt -> case.txt" }, windows_plan.display)

    local posix_plan = fake_plan("/project", {
      { source = "Case.txt", target = "case.txt" },
    })
    assert.are.same({
      { type = "move", from = "/project/Case.txt", to = "/project/case.txt", kind = "file" },
    }, posix_plan.operations)
  end)

  it("retries temps against snapshot cache and planned targets with platform-aware equality", function()
    local instance = ready({
      ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c", ["d.txt"] = "d",
      [".a.txt.fre-tmp-move-cycle-1"] = "occupied",
    })
    set_lines(instance, {
      edited_line(instance, "a.txt", "b.txt"),
      edited_line(instance, "b.txt", "a.txt"),
      edited_line(instance, "c.txt", "d.txt"),
      edited_line(instance, "d.txt", "c.txt"),
      ".c.txt.fre-tmp-move-cycle-3",
    })
    local plan = instance:prepare()
    assert.are.equal(fixture:path(".a.txt.fre-tmp-move-cycle-1-1"), plan.operations[1].to)
    assert.are.equal(fixture:path(".c.txt.fre-tmp-move-cycle-3-1"), plan.operations[4].to)
    assert.are.same({
      "MOVE  a.txt -> b.txt", "MOVE  b.txt -> a.txt",
      "MOVE  c.txt -> d.txt", "MOVE  d.txt -> c.txt",
      "CREATE FILE  .c.txt.fre-tmp-move-cycle-3",
    }, plan.display)
  end)

  it("reserves every previously generated temp when lowering multiple components", function()
    local function self_cycle(from, to)
      local action = {
        type = "move", from = from, to = to, kind = "file", sequence = 1,
        dependencies = {}, occupancy_dependencies = {}, non_occupancy_dependencies = {},
      }
      action.dependencies[action] = true
      action.occupancy_dependencies[action] = true
      return action
    end
    local first = self_cycle("C:/Project/A.txt", "C:/Project/a.txt")
    local second = self_cycle("C:/Project/a.txt", "C:/Project/A.txt")
    local lowered = move_graph.order_and_lower({ first, second }, { windows = true })
    assert.are.equal("C:/Project/.A.txt.fre-tmp-move-cycle-1", lowered[1].to)
    assert.are.equal("C:/Project/.a.txt.fre-tmp-move-cycle-1-1", lowered[3].to)
  end)

  it("preserves file directory and symlink kinds in every lowered rename", function()
    local target_one = fixture:write("target-one.txt", "one")
    local target_two = fixture:write("target-two.txt", "two")
    local link_one, link_error = fixture:symlink(target_one, "link-one")
    local link_two
    if link_one then link_two = assert(fixture:symlink(target_two, "link-two")) end
    local instance = ready({
      ["file-one"] = "one", ["file-two"] = "two",
      ["dir-one/child"] = "one", ["dir-two/child"] = "two",
    })
    local replacement = {
      edited_line(instance, "file-one", "file-two"),
      edited_line(instance, "file-two", "file-one"),
      edited_line(instance, "dir-one", "dir-two/"),
      edited_line(instance, "dir-two", "dir-one/"),
      physical_line(instance, "target-one.txt"),
      physical_line(instance, "target-two.txt"),
    }
    if link_one then
      replacement[#replacement + 1] = edited_line(instance, "link-one", "link-two")
      replacement[#replacement + 1] = edited_line(instance, "link-two", "link-one")
    else
      assert.is_truthy(link_error)
    end
    set_lines(instance, replacement)
    local plan = instance:prepare()
    assert.are.same({ "file", "file", "file" }, {
      plan.operations[1].kind, plan.operations[2].kind, plan.operations[3].kind,
    })
    assert.are.same({ "directory", "directory", "directory" }, {
      plan.operations[4].kind, plan.operations[5].kind, plan.operations[6].kind,
    })
    assert.is_false(path.contains(fixture:path("dir-one"), plan.operations[4].to))
    if link_two then
      assert.are.same({ "symlink", "symlink", "symlink" }, {
        plan.operations[7].kind, plan.operations[8].kind, plan.operations[9].kind,
      })
    end
  end)

  it("orders source copies and descendant extraction before a cycle and target dependents after it", function()
    local files = ready({ ["a.txt"] = "a", ["b.txt"] = "b" })
    set_lines(files, {
      edited_line(files, "a.txt", "b.txt"),
      edited_line(files, "a.txt", "z.txt"),
      edited_line(files, "b.txt", "a.txt"),
    })
    local file_plan = files:prepare()
    assert.are.equal("copy", file_plan.operations[1].type)
    assert.are.equal(fixture:path("a.txt"), file_plan.operations[1].from)
    assert.are.equal(fixture:path(".a.txt.fre-tmp-move-cycle-1"), file_plan.operations[2].to)
    files:destroy()

    local directories = ready({
      ["left/left.txt"] = "left", ["right/right.txt"] = "right",
    })
    expand(directories, "left")
    expand(directories, "right")
    set_lines(directories, {
      edited_line(directories, "left", "right/"),
      edited_line(directories, "left/left.txt", "extracted.txt"),
      edited_line(directories, "right", "left/"),
      physical_line(directories, "right/right.txt"),
      "right/new.txt",
      physical_line(directories, "a.txt"),
      physical_line(directories, "b.txt"),
    })
    local temporary = fixture:path(".left.fre-tmp-move-cycle-1")
    local plan = directories:prepare()
    assert.are.same({
      {
        type = "move", from = fixture:path("left", "left.txt"),
        to = fixture:path("extracted.txt"), kind = "file",
      },
      { type = "move", from = fixture:path("left"), to = temporary, kind = "directory" },
      {
        type = "move", from = fixture:path("right"),
        to = fixture:path("left"), kind = "directory",
      },
      { type = "move", from = temporary, to = fixture:path("right"), kind = "directory" },
      { type = "create_file", path = fixture:path("right", "new.txt") },
    }, plan.operations)
    assert.are.same({
      "MOVE  left/left.txt -> extracted.txt", "MOVE  left/ -> right/",
      "MOVE  right/ -> left/", "CREATE FILE  right/new.txt",
    }, plan.display)
  end)

  it("orders a nested directory move before evacuating its target ancestor and writes both payloads", function()
    local instance = ready({
      ["a/file.txt"] = "a payload", ["b/file.txt"] = "b payload",
    })
    expand(instance, "a")
    expand(instance, "b")
    local ui = accepting_ui()
    set_lines(instance, {
      edited_line(instance, "b", "z/"),
      physical_line(instance, "b/file.txt"),
      edited_line(instance, "a", "b/inside/"),
      physical_line(instance, "a/file.txt"),
    })

    local plan = instance:prepare()
    assert.are.same({
      {
        type = "move", from = fixture:path("a"),
        to = fixture:path("b", "inside"), kind = "directory",
      },
      {
        type = "move", from = fixture:path("b"),
        to = fixture:path("z"), kind = "directory",
      },
    }, plan.operations)
    assert.are.same({ "MOVE  a/ -> b/inside/", "MOVE  b/ -> z/" }, plan.display)

    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    assert.are.same(plan.display, ui.confirmations[1])
    ui.decide(true)
    wait_unlocked(instance)

    assert.are.equal("b payload", read_file(fixture:path("z", "file.txt")))
    assert.are.equal("a payload", read_file(fixture:path("z", "inside", "file.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("a")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("b")))
    assert.are.equal("succeeded", instance._last_write_result.execution.state)
  end)

  it("keeps a distinct directory producer as the nested target container", function()
    local instance = ready({
      ["a/file.txt"] = "a", ["b/file.txt"] = "b", ["c/file.txt"] = "c",
    })
    expand(instance, "a")
    expand(instance, "b")
    expand(instance, "c")
    set_lines(instance, {
      edited_line(instance, "b", "z/"),
      physical_line(instance, "b/file.txt"),
      edited_line(instance, "c", "b/"),
      physical_line(instance, "c/file.txt"),
      edited_line(instance, "a", "b/inside/"),
      physical_line(instance, "a/file.txt"),
    })

    local plan = instance:prepare()
    assert.are.same({
      {
        type = "move", from = fixture:path("b"),
        to = fixture:path("z"), kind = "directory",
      },
      {
        type = "move", from = fixture:path("c"),
        to = fixture:path("b"), kind = "directory",
      },
      {
        type = "move", from = fixture:path("a"),
        to = fixture:path("b", "inside"), kind = "directory",
      },
    }, plan.operations)
    assert.are.same({
      "MOVE  b/ -> z/", "MOVE  c/ -> b/", "MOVE  a/ -> b/inside/",
    }, plan.display)
  end)

  it("orders a foreign source copy before lowering a cycle that removes its source", function()
    local source = ready({ ["a.txt"] = "a", ["b.txt"] = "b" })
    local target = ready()
    set_lines(target, {
      edited_line(target, "a.txt", "b.txt"),
      edited_line(source, "a.txt", "copied.txt"),
      edited_line(target, "b.txt", "a.txt"),
    })

    local temporary = fixture:path(".a.txt.fre-tmp-move-cycle-1")
    local plan = target:prepare()
    assert.are.same({
      {
        type = "copy", from = fixture:path("a.txt"),
        to = fixture:path("copied.txt"), kind = "file",
      },
      { type = "move", from = fixture:path("a.txt"), to = temporary, kind = "file" },
      {
        type = "move", from = fixture:path("b.txt"),
        to = fixture:path("a.txt"), kind = "file",
      },
      { type = "move", from = temporary, to = fixture:path("b.txt"), kind = "file" },
    }, plan.operations)
    assert.are.same({
      "COPY  " .. fixture:path("a.txt") .. " -> copied.txt",
      "MOVE  a.txt -> b.txt",
      "MOVE  b.txt -> a.txt",
    }, plan.display)
  end)

  it("continues rejecting dependency cycles that are not coherent occupancy rotations", function()
    local instance = ready({
      ["left/child.txt"] = "left", ["right/other.txt"] = "right",
    })
    expand(instance, "left")
    expand(instance, "right")
    set_lines(instance, {
      edited_line(instance, "left", "right/"),
      edited_line(instance, "left/child.txt", "right/extracted.txt"),
      edited_line(instance, "right", "left/"),
      physical_line(instance, "right/other.txt"),
    })
    assert_error("move dependency cycle is unsupported", function() instance:prepare() end)
  end)

  it("keeps ordinary acyclic vacancy ordering unchanged", function()
    local instance = ready({ ["a"] = "a", ["b"] = "b", ["c"] = "c" })
    set_lines(instance, {
      edited_line(instance, "a", "b"),
      edited_line(instance, "b", "c"),
    })
    assert.are.same({
      { type = "delete", path = fixture:path("c"), kind = "file" },
      { type = "move", from = fixture:path("b"), to = fixture:path("c"), kind = "file" },
      { type = "move", from = fixture:path("a"), to = fixture:path("b"), kind = "file" },
    }, instance:prepare().operations)
  end)

  it("executes real swap and long-cycle writes and reconciles final intent", function()
    local instance = ready({
      ["a.txt"] = "a", ["b.txt"] = "b",
      ["x.txt"] = "x", ["y.txt"] = "y", ["z.txt"] = "z",
    })
    local ui = accepting_ui()
    set_lines(instance, {
      edited_line(instance, "a.txt", "b.txt"),
      edited_line(instance, "b.txt", "a.txt"),
      edited_line(instance, "x.txt", "y.txt"),
      edited_line(instance, "y.txt", "z.txt"),
      edited_line(instance, "z.txt", "x.txt"),
    })
    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    ui.decide(true)
    wait_unlocked(instance)

    assert.are.equal("b", read_file(fixture:path("a.txt")))
    assert.are.equal("a", read_file(fixture:path("b.txt")))
    assert.are.equal("z", read_file(fixture:path("x.txt")))
    assert.are.equal("x", read_file(fixture:path("y.txt")))
    assert.are.equal("y", read_file(fixture:path("z.txt")))
    assert.are.equal("succeeded", instance._last_write_result.execution.state)
    assert.is_false(instance.needs_refresh)
    for _, relative in ipairs(projected_paths(instance)) do
      assert.is_falsy(relative:find("fre%-tmp"))
    end
  end)

  it("executes through a colliding temp fallback without changing the occupied path", function()
    local occupied = ".a.txt.fre-tmp-move-cycle-1"
    local instance = ready({
      ["a.txt"] = "a", ["b.txt"] = "b", [occupied] = "occupied",
    })
    local ui = accepting_ui()
    set_lines(instance, {
      edited_line(instance, "a.txt", "b.txt"),
      edited_line(instance, "b.txt", "a.txt"),
    })
    local fallback = fixture:path(occupied .. "-1")
    assert.are.equal(fallback, instance:prepare().operations[1].to)

    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    ui.decide(true)
    wait_unlocked(instance)

    assert.are.equal("b", read_file(fixture:path("a.txt")))
    assert.are.equal("a", read_file(fixture:path("b.txt")))
    assert.are.equal("occupied", read_file(fixture:path(occupied)))
    assert.is_nil(vim.uv.fs_lstat(fallback))
    assert.are.equal("succeeded", instance._last_write_result.execution.state)
  end)


  it("executes a real case-only write according to host path semantics", function()
    local instance = ready({ ["Case.txt"] = "case contents" })
    local ui = accepting_ui()
    set_lines(instance, { edited_line(instance, "Case.txt", "case.txt") })
    local plan = instance:prepare()
    local expected_operations = package.config:sub(1, 1) == "\\" and 2 or 1
    assert.are.equal(expected_operations, #plan.operations)
    assert.are.same({ "MOVE  Case.txt -> case.txt" }, plan.display)

    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    ui.decide(true)
    wait_unlocked(instance)
    assert.are.equal("case contents", read_file(fixture:path("case.txt")))
    assert.are.equal("succeeded", instance._last_write_result.execution.state)
    assert.is_truthy(vim.tbl_contains(projected_paths(instance), "case.txt"))
  end)

  it("stops on a rotation failure without rollback and reconciles the temp truth", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" })
    local ui = accepting_ui()
    set_lines(instance, {
      edited_line(instance, "a.txt", "b.txt"),
      edited_line(instance, "b.txt", "a.txt"),
    })
    local plan = instance:prepare()
    local temporary = plan.operations[1].to
    local move_count = 0
    local adapter = mutation_fs.default
    fre._set_mutation_adapter({
      create_file = adapter.create_file,
      create_directory = adapter.create_directory,
      copy = adapter.copy,
      delete = adapter.delete,
      move = function(from, to, done, report)
        move_count = move_count + 1
        if move_count == 2 then
          done("forced rotation failure", nil, false)
          return nil
        end
        return adapter.move(from, to, done, report)
      end,
    })

    assert.is_true(write_command(instance))
    ui.decide(true)
    wait_unlocked(instance)
    assert.are.equal(2, move_count)
    assert.is_nil(vim.uv.fs_lstat(fixture:path("a.txt")))
    assert.are.equal("b", read_file(fixture:path("b.txt")))
    assert.are.equal("a", read_file(temporary))
    assert.are.equal("failed", instance._last_write_result.execution.state)
    assert.are.equal(1, instance._last_write_result.execution.completed)
    assert.is_false(instance.needs_refresh)
    assert.is_falsy(vim.tbl_contains(projected_paths(instance), "a.txt"))
  end)

  it("stops on cancellation after the temp rename and performs no rollback", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" })
    local ui = accepting_ui()
    set_lines(instance, {
      edited_line(instance, "a.txt", "b.txt"),
      edited_line(instance, "b.txt", "a.txt"),
    })
    local temporary = instance:prepare().operations[1].to
    local move_count = 0
    local active_request
    local adapter = mutation_fs.default
    fre._set_mutation_adapter({
      create_file = adapter.create_file,
      create_directory = adapter.create_directory,
      copy = adapter.copy,
      delete = adapter.delete,
      move = function(from, to, done, report)
        move_count = move_count + 1
        if move_count == 2 then
          active_request = {
            cancel = function()
              done(nil, { phase = "canceled rotation" }, false, true)
              return true
            end,
          }
          return active_request
        end
        return adapter.move(from, to, done, report)
      end,
    })

    assert.is_true(write_command(instance))
    ui.decide(true)
    wait_for(function() return active_request ~= nil end)
    ui.cancel_progress()
    wait_unlocked(instance)
    assert.are.equal(2, move_count)
    assert.is_nil(vim.uv.fs_lstat(fixture:path("a.txt")))
    assert.are.equal("b", read_file(fixture:path("b.txt")))
    assert.are.equal("a", read_file(temporary))
    assert.are.equal("canceled", instance._last_write_result.execution.state)
    assert.are.equal(1, instance._last_write_result.execution.completed)
    assert.is_false(instance.needs_refresh)
  end)
end)
