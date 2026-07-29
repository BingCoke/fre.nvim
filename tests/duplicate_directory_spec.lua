local actions = require("fre.actions")
local buffer = require("fre.buffer")
local fre = require("fre")
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
  local navigation = lines(instance)[1]
  assert.are.equal("navigation", assert(buffer.decode(instance, 1)).row_kind)
  local next_lines = {}
  if replacement[1] ~= navigation then next_lines[1] = navigation end
  vim.list_extend(next_lines, replacement)
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, next_lines)
  vim.bo[instance.bufnr].modifiable = modifiable
end

local function row_for(instance, relative)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = buffer.decode(instance, row)
    if decoded and decoded.row_kind == "entry"
        and decoded.entry.relative_path == relative then
      return row
    end
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
  function ui.progress()
    return { update = function() end, close = function() end }
  end
  function ui.report() end
  actions._set_ui_adapter(ui)
  return ui
end

local function read_file(path)
  local fd = assert(vim.uv.fs_open(path, "r", 438))
  local stat = assert(vim.uv.fs_fstat(fd))
  local contents = assert(vim.uv.fs_read(fd, stat.size, 0))
  assert(vim.uv.fs_close(fd))
  return contents
end

local function projected_paths(instance)
  local result = {}
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(buffer.decode(instance, row))
    if decoded.row_kind == "entry" then result[#result + 1] = decoded.path end
  end
  return result
end

describe("fre ticket 12 duplicate and directory semantics", function()
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

  it("keeps the original file and emits copies for every distinct duplicate", function()
    local instance = ready({ ["a.txt"] = "a" })
    set_lines(instance, {
      edited_line(instance, "a.txt", "z.txt"),
      physical_line(instance, "a.txt"),
      edited_line(instance, "a.txt", "b.txt"),
    })
    local plan = instance:prepare()
    assert.are.same({
      { type = "copy", from = fixture:path("a.txt"), to = fixture:path("z.txt"), kind = "file" },
      { type = "copy", from = fixture:path("a.txt"), to = fixture:path("b.txt"), kind = "file" },
    }, plan.operations)
  end)

  it("chooses the lexical primary move when the original is absent and copies first", function()
    local instance = ready({ ["a.txt"] = "a" })
    set_lines(instance, {
      edited_line(instance, "a.txt", "z.txt"),
      edited_line(instance, "a.txt", "b.txt"),
    })
    local plan = instance:prepare()
    assert.are.same({
      { type = "copy", from = fixture:path("a.txt"), to = fixture:path("z.txt"), kind = "file" },
      { type = "move", from = fixture:path("a.txt"), to = fixture:path("b.txt"), kind = "file" },
    }, plan.operations)
    assert.are.same({ "COPY  a.txt -> z.txt", "MOVE  a.txt -> b.txt" }, plan.display)
  end)

  it("rejects equal canonical destinations instead of selecting by row order", function()
    local instance = ready({ ["a.txt"] = "a" })
    set_lines(instance, {
      edited_line(instance, "a.txt", "dir/../same.txt"),
      edited_line(instance, "a.txt", "same.txt"),
    })
    assert_error("duplicate target same.txt", function() instance:prepare() end)
  end)

  it("moves copies and deletes expanded directories as one whole entry", function()
    local cases = {
      {
        lines = function(instance)
          return { edited_line(instance, "dir", "moved/"), physical_line(instance, "dir/child.txt") }
        end,
        operation = function()
          return { type = "move", from = fixture:path("dir"), to = fixture:path("moved"), kind = "directory" }
        end,
      },
      {
        lines = function(instance)
          return {
            physical_line(instance, "dir"), edited_line(instance, "dir", "copied/"),
            physical_line(instance, "dir/child.txt"),
          }
        end,
        operation = function()
          return { type = "copy", from = fixture:path("dir"), to = fixture:path("copied"), kind = "directory" }
        end,
      },
      {
        lines = function(instance) return { physical_line(instance, "dir/child.txt") } end,
        operation = function()
          return { type = "delete", path = fixture:path("dir"), kind = "directory" }
        end,
      },
    }
    for _, case in ipairs(cases) do
      local instance = ready({ ["dir/child.txt"] = "child" })
      expand(instance, "dir")
      set_lines(instance, case.lines(instance))
      assert.are.same({ case.operation() }, instance:prepare().operations)
      instance:destroy()
    end
  end)

  it("moves copies and deletes cached collapsed and filtered descendants as whole entries", function()
    local cases = {
      {
        lines = function(instance) return { edited_line(instance, "dir", "moved/") } end,
        operation = function()
          return { type = "move", from = fixture:path("dir"), to = fixture:path("moved"), kind = "directory" }
        end,
      },
      {
        lines = function(instance)
          return { physical_line(instance, "dir"), edited_line(instance, "dir", "copied/") }
        end,
        operation = function()
          return { type = "copy", from = fixture:path("dir"), to = fixture:path("copied"), kind = "directory" }
        end,
      },
      {
        lines = function() return {} end,
        operation = function()
          return { type = "delete", path = fixture:path("dir"), kind = "directory" }
        end,
      },
    }
    for _, case in ipairs(cases) do
      local instance = ready({ ["dir/child.txt"] = "child", ["dir/.hidden.txt"] = "hidden" })
      expand(instance, "dir")
      assert.is_not_nil(instance.nodes_by_path[fixture:path("dir", ".hidden.txt")])
      instance:collapse("dir")
      set_lines(instance, case.lines(instance))
      assert.are.same({ case.operation() }, instance:prepare().operations)
      instance:destroy()
    end
  end)

  it("orders explicit descendant extraction before ancestor move copy and delete", function()
    local cases = {
      {
        parent_lines = function(instance)
          return { edited_line(instance, "dir", "moved/"), edited_line(instance, "dir/child.txt", "outside.txt") }
        end,
        ancestor = function()
          return { type = "move", from = fixture:path("dir"), to = fixture:path("moved"), kind = "directory" }
        end,
      },
      {
        parent_lines = function(instance)
          return {
            physical_line(instance, "dir"), edited_line(instance, "dir", "copied/"),
            edited_line(instance, "dir/child.txt", "outside.txt"),
          }
        end,
        ancestor = function()
          return { type = "copy", from = fixture:path("dir"), to = fixture:path("copied"), kind = "directory" }
        end,
      },
      {
        parent_lines = function(instance)
          return { edited_line(instance, "dir/child.txt", "outside.txt") }
        end,
        ancestor = function()
          return { type = "delete", path = fixture:path("dir"), kind = "directory" }
        end,
      },
    }
    for _, case in ipairs(cases) do
      local instance = ready({ ["dir/child.txt"] = "child" })
      expand(instance, "dir")
      set_lines(instance, case.parent_lines(instance))
      assert.are.same({
        { type = "move", from = fixture:path("dir", "child.txt"), to = fixture:path("outside.txt"), kind = "file" },
        case.ancestor(),
      }, instance:prepare().operations)
      instance:destroy()
    end
  end)

  it("shadows descendant deletes under a parent delete", function()
    local instance = ready({ ["dir/child.txt"] = "child", ["dir/nested/deep.txt"] = "deep" })
    expand(instance, "dir")
    expand(instance, "dir/nested")
    set_lines(instance, {})
    assert.are.same({
      { type = "delete", path = fixture:path("dir"), kind = "directory" },
    }, instance:prepare().operations)
  end)

  it("rejects contradictory nested outcomes and self-descendant directory targets", function()
    local instance = ready({ ["dir/child.txt"] = "child" })
    expand(instance, "dir")
    set_lines(instance, { edited_line(instance, "dir/child.txt", "dir/renamed.txt") })
    assert_error("contradictory ancestor/descendant outcome", function() instance:prepare() end)

    local second = ready({ ["source/child.txt"] = "child" })
    set_lines(second, { edited_line(second, "source", "source/nested/") })
    assert_error("must not be inside its own source subtree", function() second:prepare() end)
    if package.config:sub(1, 1) == "\\" then
      set_lines(second, { edited_line(second, "source", "SOURCE/") })
      local temporary = fixture:path(".source.fre-tmp-move-cycle-1")
      local plan = second:prepare()
      assert.are.same(
        { type = "move", from = fixture:path("source"), to = temporary, kind = "directory" },
        plan.operations[1]
      )
      assert.are.same(
        { type = "move", from = temporary, to = fixture:path("SOURCE"), kind = "directory" },
        plan.operations[2]
      )
      assert.are.equal("MOVE  source/ -> SOURCE/", plan.display[1])
    end
  end)

  it("recreates moved parent paths for new rows and rejects rows under a deleted directory", function()
    local instance = ready({ ["dir"] = true })
    set_lines(instance, { edited_line(instance, "dir", "moved/"), "dir/new.txt" })
    assert.are.same({
      { type = "move", from = fixture:path("dir"), to = fixture:path("moved"), kind = "directory" },
      { type = "create_directory", path = fixture:path("dir") },
      { type = "create_file", path = fixture:path("dir", "new.txt") },
    }, instance:prepare().operations)

    set_lines(instance, { "dir/new.txt" })
    assert_error("target remains inside deleted ancestor", function() instance:prepare() end)
  end)

  it("rejects a marked move into a directory that is deleted without losing data", function()
    local instance = ready({ ["a.txt"] = "a", ["dir/keep.txt"] = "keep" })
    set_lines(instance, { edited_line(instance, "a.txt", "dir/a.txt") })
    assert_error("target remains inside deleted ancestor", function() instance:prepare() end)

    local ok, err = write_command(instance)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("target remains inside deleted ancestor", 1, true), tostring(err))
    assert.are.equal("a", read_file(fixture:path("a.txt")))
    assert.are.equal("keep", read_file(fixture:path("dir", "keep.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("dir", "a.txt")))
  end)

  it("rejects explicit targets colliding with cached descendants of a directory copy", function()
    local instance = ready({ ["b.txt"] = "b", ["dir/child.txt"] = "child" })
    expand(instance, "dir")
    set_lines(instance, {
      physical_line(instance, "dir"), edited_line(instance, "dir", "copied/"),
      physical_line(instance, "dir/child.txt"),
      edited_line(instance, "b.txt", "copied/child.txt"),
    })
    assert_error("target collision at copied/child.txt", function() instance:prepare() end)

    local ok, err = write_command(instance)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("target collision at copied/child.txt", 1, true), tostring(err))
    assert.are.equal("b", read_file(fixture:path("b.txt")))
    assert.are.equal("child", read_file(fixture:path("dir", "child.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("copied")))

    set_lines(instance, {
      physical_line(instance, "dir"), edited_line(instance, "dir", "copied/"),
      physical_line(instance, "dir/child.txt"), edited_line(instance, "b.txt", "b.txt"),
      "copied/child.txt",
    })
    assert_error("target collision at copied/child.txt", function() instance:prepare() end)

    if package.config:sub(1, 1) == "\\" then
      set_lines(instance, {
        physical_line(instance, "dir"), edited_line(instance, "dir", "COPIED/"),
        physical_line(instance, "dir/child.txt"),
        edited_line(instance, "b.txt", "copied/CHILD.txt"),
      })
      assert_error("target collision at copied/CHILD.txt", function() instance:prepare() end)
    end
  end)

  it("orders noncolliding marked targets after their produced directory container", function()
    local instance = ready({ ["b.txt"] = "b", ["dir/child.txt"] = "child" })
    expand(instance, "dir")
    local expected = {
      { type = "copy", from = fixture:path("dir"), to = fixture:path("copied"), kind = "directory" },
      { type = "move", from = fixture:path("b.txt"), to = fixture:path("copied", "b.txt"), kind = "file" },
    }
    local variants = {
      {
        edited_line(instance, "b.txt", "copied/b.txt"),
        physical_line(instance, "dir"), edited_line(instance, "dir", "copied/"),
        physical_line(instance, "dir/child.txt"),
      },
      {
        physical_line(instance, "dir/child.txt"),
        edited_line(instance, "dir", "copied/"), physical_line(instance, "dir"),
        edited_line(instance, "b.txt", "copied/b.txt"),
      },
    }
    for _, variant in ipairs(variants) do
      set_lines(instance, variant)
      assert.are.same(expected, instance:prepare().operations)
    end

    instance:destroy()
    local descendant = ready({ ["dir/child.txt"] = "child" })
    expand(descendant, "dir")
    set_lines(descendant, {
      physical_line(descendant, "dir"), edited_line(descendant, "dir", "copied/"),
      physical_line(descendant, "dir/child.txt"),
      edited_line(descendant, "dir/child.txt", "copied/other.txt"),
      physical_line(descendant, "b.txt"),
    })
    assert.are.same({
      { type = "copy", from = fixture:path("dir"), to = fixture:path("copied"), kind = "directory" },
      {
        type = "copy", from = fixture:path("dir", "child.txt"),
        to = fixture:path("copied", "other.txt"), kind = "file",
      },
    }, descendant:prepare().operations)
  end)

  it("excludes extracted descendants from carry collisions and keeps satisfied occurrences implicit", function()
    local instance = ready({ ["b.txt"] = "b", ["dir/child.txt"] = "child" })
    expand(instance, "dir")
    set_lines(instance, {
      physical_line(instance, "dir"), edited_line(instance, "dir", "copied/"),
      physical_line(instance, "dir/child.txt"),
      edited_line(instance, "dir/child.txt", "copied/child.txt"),
      physical_line(instance, "b.txt"),
    })
    assert.are.same({
      { type = "copy", from = fixture:path("dir"), to = fixture:path("copied"), kind = "directory" },
    }, instance:prepare().operations)

    set_lines(instance, {
      physical_line(instance, "dir"), edited_line(instance, "dir", "copied/"),
      edited_line(instance, "dir/child.txt", "outside.txt"),
      edited_line(instance, "b.txt", "copied/child.txt"),
    })
    assert.are.same({
      { type = "move", from = fixture:path("dir", "child.txt"), to = fixture:path("outside.txt"), kind = "file" },
      { type = "copy", from = fixture:path("dir"), to = fixture:path("copied"), kind = "directory" },
      { type = "move", from = fixture:path("b.txt"), to = fixture:path("copied", "child.txt"), kind = "file" },
    }, instance:prepare().operations)
  end)

  it("orders nested directory destinations after the directory that creates their parent", function()
    local instance = ready({ ["nested/child.txt"] = "child", ["outer/base.txt"] = "base" })
    expand(instance, "nested")
    expand(instance, "outer")
    local nested_source = physical_line(instance, "nested")
    local nested_child = physical_line(instance, "nested/child.txt")
    local nested_made = edited_line(instance, "nested", "made/nested/")
    local nested_collision = edited_line(instance, "nested", "made/base.txt/")
    local outer_source = physical_line(instance, "outer")
    local outer_made = edited_line(instance, "outer", "made/")
    local outer_base = physical_line(instance, "outer/base.txt")

    set_lines(instance, {
      nested_made, nested_source, nested_child,
      outer_source, outer_made, outer_base,
    })
    assert.are.same({
      { type = "copy", from = fixture:path("outer"), to = fixture:path("made"), kind = "directory" },
      {
        type = "copy", from = fixture:path("nested"),
        to = fixture:path("made", "nested"), kind = "directory",
      },
    }, instance:prepare().operations)

    set_lines(instance, {
      nested_collision, nested_source, nested_child,
      outer_source, outer_made, outer_base,
    })
    assert_error("target collision at made/base.txt/", function() instance:prepare() end)
  end)

  it("orders nested explicit operations from deepest source to outermost ancestor", function()
    local instance = ready({ ["outer/inner/deep.txt"] = "deep" })
    expand(instance, "outer")
    expand(instance, "outer/inner")
    set_lines(instance, {
      edited_line(instance, "outer", "outer-moved/"),
      edited_line(instance, "outer/inner", "inner-moved/"),
      edited_line(instance, "outer/inner/deep.txt", "deep-moved.txt"),
    })
    assert.are.same({
      {
        type = "move", from = fixture:path("outer", "inner", "deep.txt"),
        to = fixture:path("deep-moved.txt"), kind = "file",
      },
      {
        type = "move", from = fixture:path("outer", "inner"),
        to = fixture:path("inner-moved"), kind = "directory",
      },
      {
        type = "move", from = fixture:path("outer"),
        to = fixture:path("outer-moved"), kind = "directory",
      },
    }, instance:prepare().operations)
  end)

  it("carries an immediate file target through a real directory move", function()
    local instance = ready({ ["a.txt"] = "carried contents", ["dir/child.txt"] = "child" })
    local ui = accepting_ui()
    set_lines(instance, {
      edited_line(instance, "a.txt", "dir/a.txt"),
      edited_line(instance, "dir", "moved/"),
    })

    local plan = instance:prepare()
    assert.are.same({
      { type = "move", from = fixture:path("a.txt"), to = fixture:path("dir", "a.txt"), kind = "file" },
      { type = "move", from = fixture:path("dir"), to = fixture:path("moved"), kind = "directory" },
    }, plan.operations)
    assert.are.same({ "MOVE  a.txt -> dir/a.txt", "MOVE  dir/ -> moved/" }, plan.display)

    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    ui.decide(true)
    wait_unlocked(instance)

    assert.are.equal("carried contents", read_file(fixture:path("moved", "a.txt")))
    assert.are.equal("child", read_file(fixture:path("moved", "child.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("a.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("dir")))
    assert.are.same({ "moved/" }, projected_paths(instance))
    assert.are.equal("succeeded", instance._last_write_result.execution.state)
  end)

  it("duplicates files and whole directories through write then reconciles to truth", function()
    local instance = ready({ ["a.txt"] = "a", ["dir/child.txt"] = "child" })
    expand(instance, "dir")
    local ui = accepting_ui()
    set_lines(instance, {
      physical_line(instance, "a.txt"), edited_line(instance, "a.txt", "a-copy.txt"),
      edited_line(instance, "dir", "moved-dir/"), edited_line(instance, "dir", "copied-dir/"),
      physical_line(instance, "dir/child.txt"),
    })
    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    ui.decide(true)
    wait_unlocked(instance)

    assert.are.equal("a", read_file(fixture:path("a.txt")))
    assert.are.equal("a", read_file(fixture:path("a-copy.txt")))
    assert.are.equal("child", read_file(fixture:path("moved-dir", "child.txt")))
    assert.are.equal("child", read_file(fixture:path("copied-dir", "child.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("dir")))
    assert.are.same({ "copied-dir/", "moved-dir/", "a-copy.txt", "a.txt" }, projected_paths(instance))
    assert.are.equal("succeeded", instance._last_write_result.execution.state)
  end)

  it("extracts a descendant before a real directory move and reconciles both results", function()
    local instance = ready({ ["dir/child.txt"] = "child" })
    expand(instance, "dir")
    local ui = accepting_ui()
    set_lines(instance, {
      edited_line(instance, "dir", "moved/"),
      edited_line(instance, "dir/child.txt", "outside.txt"),
    })
    assert.is_true(write_command(instance))
    ui.decide(true)
    wait_unlocked(instance)

    assert.are.equal("child", read_file(fixture:path("outside.txt")))
    assert.are.equal("directory", assert(vim.uv.fs_lstat(fixture:path("moved"))).type)
    assert.is_nil(vim.uv.fs_lstat(fixture:path("moved", "child.txt")))
    assert.are.same({ "moved/", "outside.txt" }, projected_paths(instance))
  end)

  it("duplicates symlinks as links when supported", function()
    local target = fixture:write("target.txt", "target")
    local link, link_error = fixture:symlink(target, "source-link")
    if link == nil then assert.is_truthy(link_error); return end
    local instance = ready({})
    local source_line = physical_line(instance, "source-link")
    set_lines(instance, {
      source_line, edited_line(instance, "source-link", "copied-link"),
      physical_line(instance, "target.txt"),
    })
    assert.are.same({
      { type = "copy", from = link, to = fixture:path("copied-link"), kind = "symlink" },
    }, instance:prepare().operations)
  end)
end)
