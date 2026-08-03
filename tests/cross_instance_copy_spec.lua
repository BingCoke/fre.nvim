local actions = require("fre.actions")
local buffer = require("fre.instance.buffer")
local columns = require("fre.columns")
local fre = require("fre")
local fs = require("tests.helpers.fs")
local write_ui = require("fre.write_ui")

local fixture
local instances = {}
local original_notify
local active_ui
local ui_adapter

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(4000, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function()
    return instance:status() == "ready"
      or instance:status() == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance:status(), tostring(instance:failure()))
  return instance
end

local function make_root(name, entries)
  local root = fixture:mkdir(name)
  for relative, value in pairs(entries or {}) do
    local prefixed = name .. "/" .. relative
    if value == true then fixture:mkdir(prefixed) else fixture:write(prefixed, value) end
  end
  return root
end

local function ready(root, opts)
  opts = vim.tbl_extend("force", { root = root, columns = {} }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function lines(instance)
  return vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
end

local function set_lines(instance, replacement)
  local navigation = lines(instance)[1]
  assert.are.equal("navigation", assert(instance.buffer:decode(1)).row_kind)
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
    local decoded = instance.buffer:decode(row)
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
  local decoded = instance.buffer:decode(row)
  return physical:sub(1, decoded.path_range.start_byte) .. target
    .. physical:sub(decoded.path_range.end_byte + 1)
end

local function assert_error(row, fragment, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  local text = tostring(err)
  assert.is_truthy(text:find("row " .. tostring(row), 1, true), text)
  assert.is_truthy(text:find(fragment, 1, true), text)
  return text
end

local function token_column(id, prefix, highlight)
  return columns.custom({
    id = id,
    render = function(entry)
      return prefix .. entry.instance_id .. "-" .. entry.kind, highlight
    end,
    parse = function(suffix)
      local value, rest = suffix:match("^ *(%S+) +(.*)$")
      return value, rest
    end,
    equals = function(entry, value)
      return value == prefix .. entry.instance_id .. "-" .. entry.kind
    end,
  })
end

local function expand(instance, relative)
  instance:expand(relative)
  wait_for(function()
    local node = instance.tree.nodes_by_path[vim.fs.joinpath(instance.root, relative)]
    return node and node.loaded
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
  active_ui = ui
  return ui
end

local function write_command(instance)
  return pcall(vim.api.nvim_buf_call, instance.bufnr, function() vim.cmd("write") end)
end

local function wait_unlocked(instance)
  wait_for(function()
    return not instance.work:is_write_active()
      and not instance.work:is_execution_active() and not instance.sync:is_busy()
  end)
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
    local decoded = assert(instance.buffer:decode(row))
    if decoded.row_kind == "entry" then result[#result + 1] = decoded.path end
  end
  return result
end

describe("fre ticket 13 cross-instance copy", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    original_notify = vim.notify
    vim.notify = function() end
    active_ui = write_ui
    ui_adapter = {
      confirm = function(...) return active_ui.confirm(...) end,
      progress = function(...) return active_ui.progress(...) end,
      report = function(...)
        if type(active_ui.report) == "function" then return active_ui.report(...) end
      end,
    }
    actions._set_ui_adapter(ui_adapter)
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
  end)

  after_each(function()
    actions._reset_ui_adapter()
    fre._reset_mutation_adapter()
    fre._reset_fs_adapter()
    vim.notify = original_notify
    for _, instance in ipairs(instances) do
      if instance:status() ~= "destroyed" then pcall(instance.destroy, instance) end
    end
    fixture:cleanup()
  end)

  it("separates equal numeric node IDs and keeps foreign rows out of target ownership", function()
    local source = ready(make_root("source", { ["source.txt"] = "source" }))
    local target = ready(make_root("target", { ["target.txt"] = "target" }))
    local source_entry = source:get_entry(row_for(source, "source.txt"))
    local target_entry = target:get_entry(row_for(target, "target.txt"))
    assert.are.equal(source_entry.node_id, target_entry.node_id)

    set_lines(target, { edited_line(source, "source.txt", "copied.txt") })
    local decoded = target.buffer:decode(2)
    assert.are.equal(source.id, decoded.source_instance.id)
    assert.are.equal(source_entry.absolute_path, decoded.entry.absolute_path)
    assert.are.same({
      {
        type = "copy", from = fixture:path("source", "source.txt"),
        to = fixture:path("target", "copied.txt"), kind = "file",
      },
      { type = "delete", path = fixture:path("target", "target.txt"), kind = "file" },
    }, target:prepare().operations)
  end)

  it("uses source descriptors, widths, Entry context, and semantic validation", function()
    local source_columns = {
      token_column("source_kind", "SRC-", "FreSourceKind"),
      token_column("source_again", "LONG-SOURCE-"),
    }
    local target_columns = { token_column("target_kind", "TARGET-") }
    local source = ready(make_root("source", {
      ["a.txt"] = "a", ["a-much-longer-name.txt"] = "long",
    }), { columns = source_columns })
    local target = ready(make_root("target", { ["keep.txt"] = "keep" }), {
      columns = target_columns,
    })
    assert.are.equal(2, #source.buffer.view.column_widths)
    assert.are.equal(1, #target.buffer.view.column_widths)

    local foreign = edited_line(source, "a.txt", "imported.txt")
    set_lines(target, { physical_line(target, "keep.txt"), foreign })
    local decoded = target.buffer:decode(3)
    assert.are.same({ "source_kind", "source_again" }, {
      decoded.fields[1].id, decoded.fields[2].id,
    })
    assert.are.equal(source.id, decoded.entry.instance_id)
    local highlighted
    wait_for(function()
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        target.bufnr, -1, 0, -1, { details = true }
      )) do
        if mark[2] == 2 and mark[4].hl_group == "FreSourceKind" then
          highlighted = mark
          return true
        end
      end
      return false
    end)
    assert.are.equal(decoded.column_ranges[1].start_byte, highlighted[3])
    assert.are.equal(
      highlighted[3] + #decoded.column_values.source_kind, highlighted[4].end_col
    )
    assert.are.same({
      {
        type = "copy", from = fixture:path("source", "a.txt"),
        to = fixture:path("target", "imported.txt"), kind = "file",
      },
    }, target:prepare().operations)

    local edited = foreign:gsub("SRC%-" .. source.id .. "%-file", "BAD-" .. source.id .. "-file", 1)
    set_lines(target, { physical_line(target, "keep.txt"), edited })
    assert_error(3, "column source_kind metadata changed", function() target:prepare() end)

    local malformed = foreign:sub(1, decoded.fields[1].separator_range.start_byte)
    set_lines(target, { physical_line(target, "keep.txt"), malformed })
    assert_error(3, "column source_again parser returned no value", function()
      target:prepare()
    end)
  end)

  it("rejects destroyed, removed marker sources, and missing foreign nodes with target rows", function()
    local target = ready(make_root("target", {}))

    local destroyed = ready(make_root("destroyed", { ["a.txt"] = "a" }))
    local destroyed_line = edited_line(destroyed, "a.txt", "destroyed-copy.txt")
    destroyed:destroy()
    set_lines(target, { "", destroyed_line })
    assert_error(3, "unknown instance", function() target:prepare() end)

    local unregistered = ready(make_root("unregistered", { ["b.txt"] = "b" }))
    local unregistered_line = edited_line(unregistered, "b.txt", "unregistered-copy.txt")
    buffer.teardown(unregistered.buffer)
    set_lines(target, { unregistered_line })
    assert_error(2, "unknown instance", function() target:prepare() end)

    local removed = ready(make_root("removed", { ["c.txt"] = "c" }))
    local removed_row = row_for(removed, "c.txt")
    local removed_entry = removed:get_entry(removed_row)
    local removed_line = edited_line(removed, "c.txt", "removed-copy.txt")
    removed.tree.nodes_by_id[removed_entry.node_id] = nil
    set_lines(target, { "", "", removed_line })
    assert_error(4, "unknown node", function() target:prepare() end)
  end)

  it("returns a caller-owned absolute Plan that survives source destruction", function()
    local source = ready(make_root("source", { ["a.txt"] = "a" }))
    local target = ready(make_root("target", {}))
    set_lines(target, { edited_line(source, "a.txt", "copied.txt") })
    local plan = target:prepare()
    local expected = vim.deepcopy(plan)
    assert.are.equal(fixture:path("source", "a.txt"), plan.operations[1].from)

    source:destroy()
    assert.are.same(expected, plan)
    local execution = target:execute(plan)
    wait_for(function() return execution:get_status().state ~= "running" end)
    assert.are.equal("succeeded", execution:get_status().state)
    assert.are.equal("a", read_file(fixture:path("target", "copied.txt")))
    assert.are.same(expected, plan)
  end)

  it("rejects duplicate destinations and copy source equal to target", function()
    local source = ready(make_root("source", { ["a.txt"] = "a" }))
    local target = ready(make_root("target", {}))
    set_lines(target, {
      edited_line(source, "a.txt", "dir/../same.txt"),
      edited_line(source, "a.txt", "same.txt"),
    })
    assert_error(3, "duplicate target same.txt", function() target:prepare() end)

    local shared_root = make_root("shared", { ["same.txt"] = "same" })
    local shared_source = ready(shared_root)
    local shared_target = ready(shared_root)
    set_lines(shared_target, { physical_line(shared_source, "same.txt") })
    assert_error(2, "copy source must differ from target", function()
      shared_target:prepare()
    end)
  end)

  it("integrates foreign targets with target directory dependencies and collisions", function()
    local source = ready(make_root("source", { ["foreign.txt"] = "foreign" }))
    local target = ready(make_root("target", { ["dir/child.txt"] = "child" }))
    expand(target, "dir")
    target:collapse("dir")

    set_lines(target, {
      edited_line(source, "foreign.txt", "copied/new.txt"),
      physical_line(target, "dir"),
      edited_line(target, "dir", "copied/"),
    })
    assert.are.same({
      {
        type = "copy", from = fixture:path("target", "dir"),
        to = fixture:path("target", "copied"), kind = "directory",
      },
      {
        type = "copy", from = fixture:path("source", "foreign.txt"),
        to = fixture:path("target", "copied", "new.txt"), kind = "file",
      },
    }, target:prepare().operations)

    set_lines(target, {
      physical_line(target, "dir"),
      edited_line(target, "dir", "copied/"),
      edited_line(source, "foreign.txt", "copied/child.txt"),
    })
    assert_error(4, "target collision at copied/child.txt", function() target:prepare() end)

    set_lines(target, {
      edited_line(target, "dir", "moved/"),
      edited_line(source, "foreign.txt", "dir/new.txt"),
    })
    assert.are.same({
      {
        type = "copy", from = fixture:path("source", "foreign.txt"),
        to = fixture:path("target", "dir", "new.txt"), kind = "file",
      },
      {
        type = "move", from = fixture:path("target", "dir"),
        to = fixture:path("target", "moved"), kind = "directory",
      },
    }, target:prepare().operations)
  end)

  it("writes file directory and symlink copies then reconciles with target ownership", function()
    local source_root = make_root("source", {
      ["file.txt"] = "file contents", ["folder/child.txt"] = "child contents",
      ["link-target.txt"] = "link contents",
    })
    local link, link_error = fixture:symlink(
      fixture:path("source", "link-target.txt"), "source/source-link"
    )
    local source = ready(source_root, { columns = { token_column("source", "SOURCE-") } })
    expand(source, "folder")
    local target = ready(make_root("target", { ["keep.txt"] = "keep" }), {
      columns = { token_column("target", "TARGET-") },
    })
    local source_before = lines(source)
    local source_nodes = source.tree.nodes_by_id
    local replacement = {
      edited_line(source, "file.txt", "copied-file.txt"),
      edited_line(source, "folder", "copied-folder/"),
      physical_line(target, "keep.txt"),
    }
    if link then
      replacement[#replacement + 1] = edited_line(source, "source-link", "copied-link")
    else
      assert.is_truthy(link_error)
    end

    local malformed_directory = edited_line(source, "folder", "copied-folder/"):sub(1, -2)
    set_lines(target, { malformed_directory })
    assert_error(2, "directory path must end in /", function() target:prepare() end)
    set_lines(target, replacement)

    local plan = target:prepare()
    local expected_count = link and 3 or 2
    assert.are.equal(expected_count, #plan.operations)
    assert.are.same({ "copy", "copy" }, {
      plan.operations[1].type, plan.operations[2].type,
    })
    assert.are.equal("file", plan.operations[1].kind)
    assert.are.equal("directory", plan.operations[2].kind)
    if link then
      assert.are.equal("copy", plan.operations[3].type)
      assert.are.equal("symlink", plan.operations[3].kind)
    end

    local ui = accepting_ui()
    local ok, err = write_command(target)
    assert.is_true(ok, tostring(err))
    ui.decide(true)
    wait_unlocked(target)

    assert.are.equal("file contents", read_file(fixture:path("target", "copied-file.txt")))
    assert.are.equal("child contents", read_file(fixture:path("target", "copied-folder", "child.txt")))
    if link then
      assert.are.equal("link", assert(vim.uv.fs_lstat(fixture:path("target", "copied-link"))).type)
      assert.are.equal(assert(vim.uv.fs_readlink(link)),
        assert(vim.uv.fs_readlink(fixture:path("target", "copied-link"))))
    end
    assert.are.equal("succeeded", target.work:last_write_result().execution.state)
    assert.are.same(source_before, lines(source))
    assert.are.equal(source_nodes, source.tree.nodes_by_id)
    assert.is_false(vim.bo[source.bufnr].modified)

    local target_paths = projected_paths(target)
    assert.is_truthy(vim.tbl_contains(target_paths, "copied-file.txt"))
    assert.is_truthy(vim.tbl_contains(target_paths, "copied-folder/"))
    for row = 1, vim.api.nvim_buf_line_count(target.bufnr) do
      local decoded = target.buffer:decode(row)
      if decoded.row_kind == "entry" then
        assert.are.equal(target.id, decoded.instance_id)
        assert.are.equal(target.id, decoded.entry.instance_id)
        assert.are.equal("target", decoded.fields[1].id)
      end
    end
    for row = 1, #lines(source) do
      assert.are.equal(source.id, source.buffer:decode(row).instance_id)
    end
  end)
end)
