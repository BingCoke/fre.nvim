local fre = require("fre")
local buffer = require("fre.buffer")
local path = require("fre.path")
local fs = require("tests.helpers.fs")

local unit_separator = string.char(31)
local instances = {}
local fixture

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(1500, predicate, 10))
end

local function ready(entries, root)
  if entries then
    fixture:tree(entries)
  end
  local instance = keep(fre.new({ root = root or fixture.root }))
  wait_for(function()
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
  end)
  return instance
end

local function lines(instance)
  return vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
end

local function set_lines(instance, start_row, end_row, replacement)
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, start_row, end_row, false, replacement)
  vim.bo[instance.bufnr].modifiable = modifiable
end

local function error_text(fn)
  local ok, err = pcall(fn)
  assert.is_false(ok)
  return tostring(err)
end

local function assert_row_error(row, fragment, fn)
  local err = error_text(fn)
  assert.is_truthy(err:find("fre: row " .. row .. ":", 1, true))
  assert.is_truthy(err:find(fragment, 1, true))
end

local function assert_exact_entry(entry, expected)
  local count = 0
  for key in pairs(entry) do
    assert.is_true(
      key == "instance_id" or key == "node_id" or key == "absolute_path"
        or key == "relative_path" or key == "name" or key == "kind"
    )
    count = count + 1
  end
  assert.are.equal(6, count)
  assert.are.same(expected, entry)
end

describe("fre stable row identity", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then
        instance:destroy()
      end
    end
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("uses canonical unit-separator base36 markers and returns fresh exact Entries", function()
    assert.are.equal(unit_separator .. "fre:10:1z" .. unit_separator, buffer.marker(36, 71))

    local instance = ready({ ["a.txt"] = "x" })
    local first = instance:get_entry(1)
    local marker = buffer.marker(instance.id, first.node_id)
    local physical = lines(instance)[1]
    assert.are.equal(marker, physical:sub(1, #marker))
    assert.are.equal("a.txt", buffer.decode(instance, 1).path)
    assert.are.equal(unit_separator, marker:sub(1, 1))
    assert.are.equal(unit_separator, marker:sub(-1))
    assert.is_truthy(marker:match("^" .. unit_separator
      .. "fre:[0-9a-z]+:[0-9a-z]+" .. unit_separator .. "$"))

    assert_exact_entry(first, {
      instance_id = instance.id,
      node_id = first.node_id,
      absolute_path = path.resolve(instance.root, "a.txt"),
      relative_path = "a.txt",
      name = "a.txt",
      kind = "file",
    })
    first.name = "caller mutation"
    local second = instance:get_entry(1)
    assert.are_not.equal(first, second)
    assert.are.equal("a.txt", second.name)
  end)

  it("returns nil for blank, new, out-of-range, and fully unmarked rows", function()
    local instance = ready({ ["a.txt"] = "x" })
    set_lines(instance, 1, 1, { "", "new.txt" })
    assert.is_nil(instance:get_entry(2))
    assert.is_nil(instance:get_entry(3))
    assert.is_nil(instance:get_entry(99))

    set_lines(instance, 0, 1, { "replacement.txt" })
    assert.is_nil(instance:get_entry(1))
  end)

  it("reports malformed and unknown markers with their row numbers", function()
    local instance = ready({ ["a.txt"] = "x" })
    local malformed = unit_separator .. "fre:" .. instance.id .. ":"
    local unknown_instance = buffer.marker(999999, 2) .. "foreign.txt"
    local unknown_node = buffer.marker(instance.id, 999999) .. "missing.txt"
    set_lines(instance, 0, -1, { malformed, unknown_instance, unknown_node })

    assert_row_error(1, "malformed reserved row marker", function()
      instance:get_entry(1)
    end)
    assert_row_error(2, "unknown instance", function()
      instance:get_entry(2)
    end)
    assert_row_error(3, "unknown local node", function()
      instance:get_entry(3)
    end)
  end)

  it("looks up snapshot keys after path edits and row moves", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" })
    local original = lines(instance)[1]
    local decoded = assert(buffer.decode(instance, 1))
    local path_start = decoded.path_range.start_byte
    set_lines(instance, 0, 1, { original:sub(1, path_start) .. "renamed.txt" })

    local edited_pos = instance:get_pos("a.txt")
    assert.are.same({ 1, path_start }, edited_pos)
    assert.is_nil(instance:get_pos("renamed.txt"))

    local moved = lines(instance)[1]
    set_lines(instance, 0, 1, {})
    set_lines(instance, -1, -1, { moved })
    assert.are.same({ 2, path_start }, instance:get_pos("a.txt"))
  end)

  it("keeps the moved original occurrence authoritative when a duplicate is inserted before it", function()
    local instance = ready({ ["a.txt"] = "a" })
    local original = lines(instance)[1]
    set_lines(instance, 0, 0, { original })

    local expected_col = assert(buffer.decode(instance, 1)).path_range.start_byte
    assert.are.same({ 2, expected_col }, instance:get_pos("a.txt"))
  end)

  it("rejects directory and nondirectory trailing-slash mismatches", function()
    local instance = ready({ ["dir"] = true, ["file.txt"] = "x" })
    local physical = lines(instance)
    local directory_entry = instance:get_entry(1)
    local file_entry = instance:get_entry(2)
    assert.are.equal("directory", directory_entry.kind)
    assert.are.equal("file", file_entry.kind)

    set_lines(instance, 0, 1, { physical[1]:sub(1, -2) })
    assert_row_error(1, "directory path must end in /", function()
      instance:get_entry(1)
    end)

    set_lines(instance, 1, 2, { physical[2] .. "/" })
    assert_row_error(2, "file path must not end in /", function()
      instance:get_entry(2)
    end)
  end)

  it("reports readiness errors while creating and after load failure", function()
    local pending
    fre._set_fs_adapter({
      load = function(_, done) pending = done end,
    })
    local instance = keep(fre.new({ root = fixture.root }))

    local creating_entry = error_text(function() instance:get_entry(1) end)
    local creating_pos = error_text(function() instance:get_pos("a.txt") end)
    assert.is_truthy(creating_entry:find("fre: instance is not ready", 1, true))
    assert.is_truthy(creating_pos:find("fre: instance is not ready", 1, true))

    pending("load exploded")
    wait_for(function() return instance.state == "load-failed" end)
    local failed_entry = error_text(function() instance:get_entry(1) end)
    local failed_pos = error_text(function() instance:get_pos("a.txt") end)
    assert.is_truthy(failed_entry:find("fre: instance is not ready", 1, true))
    assert.is_truthy(failed_pos:find("fre: instance is not ready", 1, true))
  end)

  it("resolves live foreign markers through their source instance", function()
    local source_root = fixture:mkdir("source")
    local destination_root = fixture:mkdir("destination")
    fixture:write("source/from.txt", "x")
    fixture:write("destination/to.txt", "y")
    local source = ready(nil, source_root)
    local destination = ready(nil, destination_root)
    local source_line = lines(source)[1]
    set_lines(destination, 0, 1, { source_line })

    local entry = destination:get_entry(1)
    assert.are.equal(source.id, entry.instance_id)
    assert.are.equal("from.txt", entry.relative_path)
    assert.are.equal(path.resolve(source.root, "from.txt"), entry.absolute_path)
  end)

  it("clamps normal and insert cursors to decoded row boundaries", function()
    local instance = ready({ ["a.txt"] = "x" })
    instance:open()
    local decoded = assert(buffer.decode(instance, 1))
    local normal_boundary = decoded.visible_range.start_byte
    local insert_boundary = decoded.path_range.start_byte

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = instance.bufnr })
    assert.are.same({ 1, normal_boundary }, vim.api.nvim_win_get_cursor(0))

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = instance.bufnr })
    assert.are.same({ 1, insert_boundary }, vim.api.nvim_win_get_cursor(0))

    set_lines(instance, -1, -1, { "new.txt" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = instance.bufnr })
    assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
  end)
end)
