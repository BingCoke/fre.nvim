local fre = require("fre")
local columns = require("fre.columns")
local buffer = require("fre.instance.buffer")
local path = require("fre.path")
local row = require("fre.instance.row")
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

local function ready(entries, root, opts)
  if entries then
    fixture:tree(entries)
  end
  opts = vim.tbl_extend("force", { root = root or fixture.root }, opts or {})
  local instance = keep(fre.new(opts))
  wait_for(function()
    return instance:status() == "ready"
  end)
  return instance
end

local function lines(instance)
  return vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
end

local function row_for(instance, relative)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(instance.buffer:decode(row))
    if decoded.row_kind == "entry" and decoded.entry.relative_path == relative then
      return row
    end
  end
  error("missing row for " .. relative)
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
      if instance:status() ~= "destroyed" then
        instance:destroy()
      end
    end
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("uses canonical length-prefixed opaque markers and returns fresh exact Entries", function()
    assert.are.equal(unit_separator .. "fre:12:peer:one:two:71" .. unit_separator,
      row.marker(nil, "peer:one:two", 71, 2))

    local instance = ready({ ["a.txt"] = "x" })
    local entry_row = row_for(instance, "a.txt")
    local decoded = instance.buffer:decode(entry_row)
    local first = instance:get_entry(entry_row)
    local marker = decoded.marker
    local physical = lines(instance)[entry_row]
    assert.are.equal(marker, physical:sub(1, #marker))
    assert.are.equal("a.txt", decoded.path)
    assert.are.equal(unit_separator, marker:sub(1, 1))
    assert.are.equal(unit_separator, marker:sub(-1))
    assert.are.equal(row.marker(
      nil, instance.id, decoded.node_id, #tostring(instance.tree:latest_node_id())
    ), marker)

    assert_exact_entry(first, {
      instance_id = instance.id,
      node_id = first.node_id,
      absolute_path = path.resolve(instance.root, "a.txt"),
      relative_path = "a.txt",
      name = "a.txt",
      kind = "file",
    })
    first.name = "caller mutation"
    local second = instance:get_entry(entry_row)
    assert.are_not.equal(first, second)
    assert.are.equal("a.txt", second.name)
  end)

  it("uses an equal-width non-node marker for drafts", function()
    local entries = {}
    for index = 1, 10 do entries[string.format("file-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    local existing = assert(instance.buffer:decode(row_for(instance, "file-01.txt")))
    local draft_marker = row.draft_marker(
      nil, instance.id, #tostring(instance.tree:latest_node_id()), "file"
    )
    local decoded = row.decode_marker(nil, 1, draft_marker .. "src/a.ts")

    assert.are.equal(#existing.marker, #draft_marker)
    assert.are.equal(instance.id, decoded.instance_id)
    assert.is_true(decoded.draft)
    assert.are.equal("file", decoded.projection_kind)
    assert.is_nil(decoded.node_id)
    assert.are.equal(draft_marker, decoded.marker)
  end)


  it("inserts an aligned draft after the requested row and moves the cursor to its path", function()
    local entries = {}
    for index = 1, 10 do entries[string.format("file-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    instance:open({ position = "current" })
    local winid = vim.api.nvim_get_current_win()
    local anchor_row = row_for(instance, "file-01.txt")
    local existing = assert(instance.buffer:decode(anchor_row))

    local inserted = instance:insert_draft({
      after_row = anchor_row, proposed_path = "src/a.ts", winid = winid,
    })
    local decoded = assert(instance.buffer:decode(anchor_row + 1))

    assert.are.equal(anchor_row + 1, inserted.row)
    assert.is_true(decoded.marked)
    assert.is_true(decoded.draft)
    assert.are.equal("new", decoded.row_kind)
    assert.is_nil(decoded.node_id)
    assert.are.equal("src/a.ts", decoded.proposed_path)
    assert.are.equal(existing.path_range.start_byte, decoded.path_range.start_byte)
    assert.is_true(vim.bo[instance.bufnr].modified)
    assert.are.same(
      { anchor_row + 1, decoded.path_range.end_byte - 1 }, vim.api.nvim_win_get_cursor(winid)
    )
    vim.api.nvim__redraw({ flush = true })
    for column = 1, #decoded.marker do
      assert.are.equal(
        1, vim.fn.synconcealed(inserted.row, column)[1], "draft marker byte " .. column
      )
    end
  end)


  it("renders draft columns from target metadata and restores their highlights", function()
    local seen
    local custom = columns.custom({
      id = "draft_state",
      render = function(entry, ctx)
        if ctx.draft then
          seen = {
            synthetic = ctx.synthetic,
            draft = ctx.draft,
            navigation_kind = ctx.navigation_kind,
            entry_name = entry.name,
            entry_kind = entry.kind,
            metadata = vim.deepcopy(ctx.metadata),
          }
        end
        return ctx.draft and "draft" or "entry"
      end,
      parse = function(suffix)
        local value, rest = suffix:match("^(%S+) +(.*)$")
        return value, rest
      end,
      equals = function(_, value, ctx)
        return value == (ctx.draft and "draft" or "entry")
      end,
    })
    local icon = columns.icon({
      provider = function(entry)
        if entry.kind == "directory" then return "DIR", "FreDirectoryIcon" end
        return entry.name, "FreFileIcon"
      end,
    })
    local instance = ready({ ["source-name.txt"] = "x" }, nil, {
      columns = { icon, columns.permissions(), columns.size(), columns.mtime(), custom },
    })
    instance:open({ position = "current" })
    local winid = vim.api.nvim_get_current_win()
    local anchor_row = row_for(instance, "source-name.txt")
    local file = instance:insert_draft({
      after_row = anchor_row, proposed_path = "a.ts", winid = winid,
    })
    local decoded = assert(instance.buffer:decode(file.row))

    assert.are.equal("a.ts", decoded.column_values.icon)
    assert.are.equal("-", decoded.column_values.permissions)
    assert.are.equal("-", decoded.column_values.size)
    assert.are.equal("-", decoded.column_values.mtime)
    assert.are.equal("draft", decoded.column_values.draft_state)
    assert.are.same({
      synthetic = true,
      draft = true,
      entry_name = "a.ts",
      entry_kind = "file",
      metadata = { kind = "file", mode = nil, size = nil, mtime = nil },
    }, seen)
    local file_decorations = row.decorations(
      instance.buffer, file.row, lines(instance)[file.row]
    )
    assert.is_true(vim.tbl_contains(vim.tbl_map(function(item)
      return item.hl_group
    end, file_decorations), "FreFileIcon"))

    local directory = instance:insert_draft({
      after_row = file.row, proposed_path = "folder/", winid = winid,
    })
    local directory_decoded = assert(instance.buffer:decode(directory.row))
    assert.are.equal("DIR", directory_decoded.column_values.icon)
    local groups = vim.tbl_map(function(item) return item.hl_group end, row.decorations(
      instance.buffer, directory.row, lines(instance)[directory.row]
    ))
    assert.is_true(vim.tbl_contains(groups, "FreDirectoryIcon"))
    assert.is_true(vim.tbl_contains(groups, "FreDirectoryPath"))
  end)


  it("keeps node markers and rendered columns aligned within one instance", function()
    local entries = {}
    for index = 1, 10 do entries[string.format("file-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    local path_start

    for row_number, line in ipairs(lines(instance)) do
      local decoded = assert(instance.buffer:decode(row_number))
      local node_text = assert(decoded.marker:match(
        ":([0-9]+)" .. unit_separator .. "$"
      ))
      assert.are.equal(2, #node_text, "node marker width on row " .. row_number)
      path_start = path_start or decoded.path_range.start_byte
      assert.are.equal(path_start, decoded.path_range.start_byte,
        "rendered column alignment on row " .. row_number)
    end
  end)

  it("parses byte-framed IDs and aligned node IDs", function()
    local opaque = "\195\169:peer"
    local marker = row.marker(nil, opaque, 17, 2)
    local decoded = row.decode_marker(nil, 1, marker .. "path")
    assert.are.equal(7, #opaque)
    assert.are.equal(opaque, decoded.instance_id)
    assert.are.equal(17, decoded.node_id)
    assert.are.equal(marker, decoded.marker)

    local aligned = row.marker(nil, opaque, 1, 2)
    assert.are.equal(1, row.decode_marker(nil, 1, aligned .. "path").node_id)

    for _, invalid in ipairs({
      unit_separator .. "fre:01:a:1" .. unit_separator,
      unit_separator .. "fre:001:002" .. unit_separator,
      unit_separator .. "fre:4:ab:1" .. unit_separator,
    }) do
      assert.is_false(pcall(row.decode_marker, nil, 1, invalid))
    end
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
    local malformed = unit_separator .. "fre:3:ab"
    local unknown_instance = row.marker(instance.buffer, "unknown:instance", 2, 1)
      .. "foreign.txt"
    local unknown_node = row.marker(instance.buffer, instance.id, 999, 3) .. "missing.txt"
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
    local row = row_for(instance, "a.txt")
    local original = lines(instance)[row]
    local decoded = assert(instance.buffer:decode(row))
    local path_start = decoded.path_range.start_byte
    set_lines(instance, row - 1, row, { original:sub(1, path_start) .. "renamed.txt" })

    local edited_pos = instance:get_pos("a.txt")
    assert.are.same({ row, path_start }, edited_pos)
    assert.is_nil(instance:get_pos("renamed.txt"))

    local moved = lines(instance)[row]
    set_lines(instance, row - 1, row, {})
    set_lines(instance, -1, -1, { moved })
    assert.are.same({ vim.api.nvim_buf_line_count(instance.bufnr), path_start },
      instance:get_pos("a.txt"))
  end)

  it("keeps the moved original occurrence authoritative when a duplicate is inserted before it", function()
    local instance = ready({ ["a.txt"] = "a" })
    local row = row_for(instance, "a.txt")
    local original = lines(instance)[row]
    set_lines(instance, row - 1, row - 1, { original })

    local expected_col = assert(instance.buffer:decode(row)).path_range.start_byte
    assert.are.same({ row + 1, expected_col }, instance:get_pos("a.txt"))
  end)

  it("rejects directory and nondirectory trailing-slash mismatches", function()
    local instance = ready({ ["dir"] = true, ["file.txt"] = "x" })
    local directory_row = row_for(instance, "dir")
    local file_row = row_for(instance, "file.txt")
    local physical = lines(instance)
    local directory_entry = instance:get_entry(directory_row)
    local file_entry = instance:get_entry(file_row)
    assert.are.equal("directory", directory_entry.kind)
    assert.are.equal("file", file_entry.kind)

    set_lines(instance, directory_row - 1, directory_row, { physical[directory_row]:sub(1, -2) })
    assert_row_error(directory_row, "directory path must end in /", function()
      instance:get_entry(directory_row)
    end)

    set_lines(instance, file_row - 1, file_row, { physical[file_row] .. "/" })
    assert_row_error(file_row, "file path must not end in /", function()
      instance:get_entry(file_row)
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
    wait_for(function() return instance:status() == "load-failed" end)
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
    local source_line = lines(source)[row_for(source, "from.txt")]
    local destination_row = row_for(destination, "to.txt")
    set_lines(destination, destination_row - 1, destination_row, { source_line })

    local entry = destination:get_entry(destination_row)
    assert.are.equal(source.id, entry.instance_id)
    assert.are.equal("from.txt", entry.relative_path)
    assert.are.equal(path.resolve(source.root, "from.txt"), entry.absolute_path)
  end)

  it("clamps normal and insert cursors to the decoded navigable boundary", function()
    local instance = ready({ ["a.txt"] = "x" })
    instance:open()
    local entry_row = row_for(instance, "a.txt")
    local decoded = assert(instance.buffer:decode(entry_row))
    local boundary = decoded.navigable_range.start_byte

    vim.api.nvim_win_set_cursor(0, { entry_row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = instance.bufnr })
    assert.are.same({ entry_row, boundary }, vim.api.nvim_win_get_cursor(0))

    vim.api.nvim_win_set_cursor(0, { entry_row, 0 })
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = instance.bufnr })
    assert.are.same({ entry_row, boundary }, vim.api.nvim_win_get_cursor(0))

    set_lines(instance, -1, -1, { "new.txt" })
    local new_row = vim.api.nvim_buf_line_count(instance.bufnr)
    vim.api.nvim_win_set_cursor(0, { new_row, 0 })
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = instance.bufnr })
    assert.are.same({ new_row, 0 }, vim.api.nvim_win_get_cursor(0))
  end)
end)
