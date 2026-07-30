local buffer = require("fre.buffer")
local columns = require("fre.columns")
local fre = require("fre")
local mutation_prepare = require("fre.mutation.prepare")
local path = require("fre.path")
local row = require("fre.row")
local real_fs = require("fre.fs").default
local fs = require("tests.helpers.fs")

local unit_separator = string.char(31)
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

local function ready_from_adapter(entries, opts)
  fre._set_fs_adapter({
    load = function(scan_path, done) done(nil, entries, scan_path) end,
  })
  opts = vim.tbl_extend("force", { root = fixture.root }, opts or {})
  return wait_ready(keep(fre.new(opts)))
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

local function error_text(callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  return tostring(err)
end

local function assert_error(fragment, callback)
  local err = error_text(callback)
  assert.is_truthy(err:find(fragment, 1, true), err)
  return err
end

local function option_snapshot(bufnr)
  return {
    buftype = vim.bo[bufnr].buftype,
    bufhidden = vim.bo[bufnr].bufhidden,
    swapfile = vim.bo[bufnr].swapfile,
    buflisted = vim.bo[bufnr].buflisted,
    filetype = vim.bo[bufnr].filetype,
    modifiable = vim.bo[bufnr].modifiable,
    readonly = vim.bo[bufnr].readonly,
  }
end

local function state_snapshot(instance)
  local nodes = {}
  for id, node in pairs(instance.nodes_by_id) do
    nodes[id] = {
      ref = node,
      path = node.path,
      parent = node.parent,
      expanded = node.expanded,
      load_state = node.load_state,
      visible_size = node.visible_size,
      visible_start = node.visible_start,
      visible_end = node.visible_end,
      visible_range = node.visible_range and vim.deepcopy(node.visible_range) or nil,
      row_extmark = node.row_extmark,
    }
  end
  return {
    text = lines(instance),
    options = option_snapshot(instance.bufnr),
    modified = vim.bo[instance.bufnr].modified,
    tree = instance.tree,
    root_node = instance.root_node,
    nodes_by_id = instance.nodes_by_id,
    nodes_by_path = instance.nodes_by_path,
    view = instance.view,
    baseline = vim.deepcopy(instance.view.baseline),
    visible_nodes = vim.deepcopy(vim.tbl_map(function(node) return node.id end,
      instance.view.visible_nodes or {})),
    extmarks = vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}),
    needs_refresh = instance.needs_refresh,
    sort = instance.current_sort,
    hidden = instance.current_hidden_file,
    execution = instance._execution,
    actions = instance.actions,
    state = instance.state,
    nodes = nodes,
  }
end

local function assert_state(instance, expected)
  assert.are.same(expected.text, lines(instance))
  assert.are.same(expected.options, option_snapshot(instance.bufnr))
  assert.are.equal(expected.modified, vim.bo[instance.bufnr].modified)
  assert.are.equal(expected.tree, instance.tree)
  assert.are.equal(expected.root_node, instance.root_node)
  assert.are.equal(expected.nodes_by_id, instance.nodes_by_id)
  assert.are.equal(expected.nodes_by_path, instance.nodes_by_path)
  assert.are.equal(expected.view, instance.view)
  assert.are.same(expected.baseline, instance.view.baseline)
  assert.are.same(expected.visible_nodes, vim.tbl_map(function(node) return node.id end,
    instance.view.visible_nodes or {}))
  assert.are.same(expected.extmarks,
    vim.api.nvim_buf_get_extmarks(instance.bufnr, buffer.namespace, 0, -1, {}))
  assert.are.equal(expected.needs_refresh, instance.needs_refresh)
  assert.are.equal(expected.sort, instance.current_sort)
  assert.are.equal(expected.hidden, instance.current_hidden_file)
  assert.are.equal(expected.execution, instance._execution)
  assert.are.equal(expected.actions, instance.actions)
  assert.are.equal(expected.state, instance.state)
  for id, value in pairs(expected.nodes) do
    local node = instance.nodes_by_id[id]
    assert.are.equal(value.ref, node)
    assert.are.equal(value.path, node.path)
    assert.are.equal(value.parent, node.parent)
    assert.are.equal(value.expanded, node.expanded)
    assert.are.equal(value.load_state, node.load_state)
    assert.are.equal(value.visible_size, node.visible_size)
    assert.are.equal(value.visible_start, node.visible_start)
    assert.are.equal(value.visible_end, node.visible_end)
    assert.are.same(value.visible_range, node.visible_range)
    assert.are.equal(value.row_extmark, node.row_extmark)
  end
end

local function empty_mutation_adapter(calls)
  local function unexpected()
    calls.count = calls.count + 1
    error("prepare dispatched mutation I/O")
  end
  return {
    create_file = unexpected,
    create_directory = unexpected,
    copy = unexpected,
    move = unexpected,
    delete = unexpected,
  }
end

local function value_column()
  return columns.custom({
    id = "value",
    render = function() return "ok" end,
    parse = function(suffix)
      local value, rest = suffix:match("^(%S+) +(.*)$")
      return value, rest
    end,
    equals = function(_, value) return value == "ok" end,
  })
end

describe("fre ticket 10 prepare basic mutations", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then instance:destroy() end
    end
    fre._reset_mutation_adapter()
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("requires successful initial readiness", function()
    local initial_done
    fre._set_fs_adapter({ load = function(_, done) initial_done = done end })
    local instance = keep(fre.new({ root = fixture.root }))
    assert_error("instance is not ready", function() instance:prepare() end)
    initial_done("load failed")
    wait_for(function() return instance.state == "load-failed" end)
    assert_error("instance is not ready", function() instance:prepare() end)
  end)

  it("performs no filesystem I/O and changes no buffer tree view or execution state", function()
    fixture:write("a.txt", "a")
    local load_calls = 0
    fre._set_fs_adapter({
      load = function(scan_path, done)
        load_calls = load_calls + 1
        real_fs.load(scan_path, done)
      end,
    })
    local mutation_calls = { count = 0 }
    fre._set_mutation_adapter(empty_mutation_adapter(mutation_calls))
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    set_lines(instance, { edited_line(instance, "a.txt", "renamed.txt"), "new.txt" })
    local before = state_snapshot(instance)
    local initial_load_calls = load_calls

    local plan = instance:prepare()

    assert.are.equal(initial_load_calls, load_calls)
    assert.are.equal(0, mutation_calls.count)
    assert.are.equal(2, #plan.operations)
    assert_state(instance, before)
  end)

  it("creates path-only files and directories while trimming only boundary whitespace", function()
    local instance = ready({ ["keep.txt"] = "k" })
    set_lines(instance, {
      physical_line(instance, "keep.txt"),
      "  new inner  name.txt  ",
      "  folder  name/  ",
    })
    local plan = instance:prepare()
    assert.are.same({
      { type = "create_file", path = fixture:path("new inner  name.txt") },
      { type = "create_directory", path = fixture:path("folder  name") },
    }, plan.operations)
    assert.are.same({
      "CREATE FILE  new inner  name.txt",
      "CREATE DIRECTORY  folder  name/",
    }, plan.display)
  end)

  it("ignores structural blank rows and returns no operation for retained canonical rows", function()
    local instance = ready({ ["keep.txt"] = "k" })
    set_lines(instance, { "", physical_line(instance, "keep.txt"), "" })
    assert.are.same({ operations = {}, display = {} }, instance:prepare())
  end)

  it("keeps unsupported snapshot kinds while planning unrelated mutations", function()
    local instance = ready_from_adapter({
      { name = "device", kind = "char" },
      { name = "keep.txt", kind = "file" },
    })
    local device = physical_line(instance, "device")
    local moved_keep = edited_line(instance, "keep.txt", "moved.txt")
    local decoded = buffer.decode(instance, row_for(instance, "device"))

    assert.are.equal("char", decoded.entry.kind)
    assert.are.same({ operations = {}, display = {} }, instance:prepare())

    set_lines(instance, { device, moved_keep, "new.txt" })
    assert.are.same({
      {
        type = "move", from = fixture:path("keep.txt"),
        to = fixture:path("moved.txt"), kind = "file",
      },
      { type = "create_file", path = fixture:path("new.txt") },
    }, instance:prepare().operations)
  end)

  it("rejects direct mutation of unsupported snapshot kinds", function()
    local instance = ready_from_adapter({ { name = "device", kind = "char" } })
    local original = physical_line(instance, "device")
    local renamed = edited_line(instance, "device", "renamed-device")
    local copied = edited_line(instance, "device", "copied-device")

    set_lines(instance, { renamed })
    assert_error("row 2: unsupported snapshot kind char for device", function()
      instance:prepare()
    end)

    set_lines(instance, { original, copied })
    assert_error("row 3: unsupported snapshot kind char for device", function()
      instance:prepare()
    end)

    set_lines(instance, {})
    assert_error("unsupported snapshot kind char for device", function() instance:prepare() end)
  end)

  it("keeps hidden unsupported snapshot kinds as target occupants", function()
    local instance = ready_from_adapter({
      { name = ".device", kind = "char" },
      { name = "keep.txt", kind = "file" },
    })
    assert.is_nil(instance:get_pos(".device"))

    set_lines(instance, { edited_line(instance, "keep.txt", ".device") })
    assert_error("target .device is occupied by snapshot path .device", function()
      instance:prepare()
    end)
  end)

  it("rejects foreign unsupported snapshot kinds", function()
    local source_root = fixture:mkdir("source")
    local destination_root = fixture:mkdir("destination")
    fre._set_fs_adapter({
      load = function(scan_path, done)
        local entries = path.equal(scan_path, source_root)
            and { { name = "device", kind = "char" } } or {}
        done(nil, entries, scan_path)
      end,
    })
    local source = wait_ready(keep(fre.new({ root = source_root })))
    local destination = wait_ready(keep(fre.new({ root = destination_root })))

    set_lines(destination, { edited_line(source, "device", "copied-device") })
    assert_error("row 2: unsupported snapshot kind char for device", function()
      destination:prepare()
    end)
  end)

  it("rejects foreign directory copies with cached unsupported descendants", function()
    local source_directory = fixture:mkdir("source-directory/folder")
    local source_root = fixture:path("source-directory")
    local destination_root = fixture:mkdir("directory-destination")
    fre._set_fs_adapter({
      load = function(scan_path, done)
        local entries = {}
        if path.equal(scan_path, source_root) then
          entries = { { name = "folder", kind = "directory" } }
        elseif path.equal(scan_path, source_directory) then
          entries = { { name = "device", kind = "char" } }
        end
        done(nil, entries, scan_path)
      end,
    })
    local source = wait_ready(keep(fre.new({ root = source_root })))
    local destination = wait_ready(keep(fre.new({ root = destination_root })))
    source:expand("folder")
    local device_path = path.resolve(source_directory, "device")
    wait_for(function() return source.nodes_by_path[device_path] ~= nil end)

    set_lines(destination, { edited_line(source, "folder", "copied-folder/") })
    local err = assert_error("row 2: unsupported snapshot kind char", function()
      destination:prepare()
    end)
    assert.is_truthy(err:find(device_path, 1, true), err)
  end)

  it("plans retained moves and missing projected IDs as one move and one delete", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b", ["keep.txt"] = "k" })
    local current = lines(instance)
    local replacement = {}
    for row, physical in ipairs(current) do
      local decoded = buffer.decode(instance, row)
      if decoded.row_kind == "entry" and decoded.entry.relative_path == "a.txt" then
        replacement[#replacement + 1] = edited_line(instance, "a.txt", "renamed.txt")
      elseif decoded.row_kind == "entry" and decoded.entry.relative_path == "keep.txt" then
        replacement[#replacement + 1] = physical
      end
    end
    set_lines(instance, replacement)
    local plan = instance:prepare()
    assert.are.same({
      {
        type = "move", from = fixture:path("a.txt"), to = fixture:path("renamed.txt"),
        kind = "file",
      },
      { type = "delete", path = fixture:path("b.txt"), kind = "file" },
    }, plan.operations)
    assert.are.same({ "MOVE  a.txt -> renamed.txt", "DELETE  b.txt" }, plan.display)
  end)

  it("treats a completely removed marker as delete plus create at the same path", function()
    local instance = ready({ ["a.txt"] = "a" })
    set_lines(instance, { "a.txt" })
    local plan = instance:prepare()
    assert.are.same({
      { type = "delete", path = fixture:path("a.txt"), kind = "file" },
      { type = "create_file", path = fixture:path("a.txt") },
    }, plan.operations)
    assert.are.same({ "DELETE  a.txt", "CREATE FILE  a.txt" }, plan.display)
  end)

  it("never infers collapsed or hidden cached nodes deleted", function()
    local instance = ready({ ["dir/child.txt"] = "x", [".hidden.txt"] = "h" })
    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/child.txt") ~= nil end)
    assert.is_not_nil(instance.nodes_by_path[fixture:path("dir", "child.txt")])
    instance:collapse("dir")
    assert.is_nil(instance.view.baseline[instance.nodes_by_path[fixture:path("dir", "child.txt")].id])
    assert.is_not_nil(instance.nodes_by_path[fixture:path(".hidden.txt")])
    assert.is_nil(instance.view.baseline[instance.nodes_by_path[fixture:path(".hidden.txt")].id])
    assert.are.same({ operations = {}, display = {} }, instance:prepare())
  end)


  it("reports row-specific empty escape absolute drive UNC URI root and CR path errors", function()
    local instance = ready({})
    local cases = {
      { "   ", "path is empty" },
      { "../escape", "escapes the root" },
      { "/absolute", "root-relative" },
      { "C:/absolute", "root-relative" },
      { "//server/share", "root-relative" },
      { "ssh://host/path", "root-relative" },
      { ".", "must not name the root" },
      { "file\rname", "must not contain CR or LF" },
    }
    for _, case in ipairs(cases) do
      set_lines(instance, { case[1] })
      local err = assert_error(case[2], function() instance:prepare() end)
      assert.is_truthy(err:find("row 2", 1, true), err)
    end
  end)

  it("retains shared malformed marker metadata parser and kind errors with row numbers", function()
    local instance = ready({ ["a.txt"] = "a" }, { columns = { value_column() } })
    local original = physical_line(instance, "a.txt")
    set_lines(instance, { unit_separator .. "fre:" .. instance.id .. ":" })
    assert_error("row 2: malformed reserved row marker", function() instance:prepare() end)

    set_lines(instance, { (original:gsub("ok", "changed", 1)) })
    assert_error("row 2: column value metadata changed", function() instance:prepare() end)

    set_lines(instance, { (original:gsub("ok ", "ok", 1)) })
    assert_error("row 2: column value", function() instance:prepare() end)

    set_lines(instance, { original .. "/" })
    assert_error("row 2: file path must not end in /", function() instance:prepare() end)

    set_lines(instance, { original })
    local row = row_for(instance, "a.txt")
    instance.nodes_by_id[buffer.decode(instance, row).node_id].kind = "other"
    set_lines(instance, { edited_line(instance, "a.txt", "renamed.txt") })
    assert_error("row 2: unsupported snapshot kind other for a.txt", function() instance:prepare() end)
  end)

  it("plans a foreign marker as a copy from its source snapshot", function()
    local source_root = fixture:mkdir("source")
    local destination_root = fixture:mkdir("destination")
    fixture:write("source/from.txt", "x")
    local source = wait_ready(keep(fre.new({ root = source_root })))
    local destination = wait_ready(keep(fre.new({ root = destination_root })))
    set_lines(destination, { physical_line(source, "from.txt") })
    assert.are.same({
      {
        type = "copy", from = fixture:path("source", "from.txt"),
        to = fixture:path("destination", "from.txt"), kind = "file",
      },
    }, destination:prepare().operations)
  end)

  it("rejects duplicate canonical targets repeated stable IDs and cached occupied targets", function()
    local instance = ready({ ["a.txt"] = "a", [".held.txt"] = "h" })
    local original = edited_line(instance, "a.txt", "a.txt")
    local occupied = edited_line(instance, "a.txt", ".held.txt")
    set_lines(instance, { "dir/../same.txt", "same.txt" })
    assert_error("duplicate target same.txt", function() instance:prepare() end)

    set_lines(instance, { original, original })
    assert_error("duplicate target a.txt", function() instance:prepare() end)

    set_lines(instance, { occupied })
    assert_error("target .held.txt is occupied by snapshot path .held.txt", function()
      instance:prepare()
    end)
  end)

  it("orders an ordinary acyclic vacancy chain and lowers move cycles", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c" })
    local a_to_b = edited_line(instance, "a.txt", "b.txt")
    local b_to_c = edited_line(instance, "b.txt", "c.txt")
    local b_to_a = edited_line(instance, "b.txt", "a.txt")
    local c_line = lines(instance)[row_for(instance, "c.txt")]
    set_lines(instance, { a_to_b, b_to_c })
    local plan = instance:prepare()
    assert.are.same({
      { type = "delete", path = fixture:path("c.txt"), kind = "file" },
      {
        type = "move", from = fixture:path("b.txt"), to = fixture:path("c.txt"),
        kind = "file",
      },
      {
        type = "move", from = fixture:path("a.txt"), to = fixture:path("b.txt"),
        kind = "file",
      },
    }, plan.operations)
    assert.are.same({
      "DELETE  c.txt", "MOVE  b.txt -> c.txt", "MOVE  a.txt -> b.txt",
    }, plan.display)

    set_lines(instance, { a_to_b, b_to_a, c_line })
    local temporary = fixture:path(".a.txt.fre-tmp-move-cycle-1")
    plan = instance:prepare()
    assert.are.same({
      { type = "move", from = fixture:path("a.txt"), to = temporary, kind = "file" },
      {
        type = "move", from = fixture:path("b.txt"), to = fixture:path("a.txt"),
        kind = "file",
      },
      { type = "move", from = temporary, to = fixture:path("b.txt"), kind = "file" },
    }, plan.operations)
    assert.are.same({ "MOVE  a.txt -> b.txt", "MOVE  b.txt -> a.txt" }, plan.display)
  end)

  it("is deterministic plain caller-owned data with only Plan and operation fields", function()
    local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" })
    set_lines(instance, { edited_line(instance, "a.txt", "renamed.txt"), "new/" })
    local first = instance:prepare()
    local expected = vim.deepcopy(first)
    local serialized = vim.inspect(first)

    assert.is_nil(getmetatable(first))
    local top = {}
    for key in pairs(first) do top[#top + 1] = key end
    table.sort(top)
    assert.are.same({ "display", "operations" }, top)
    for _, operation in ipairs(first.operations) do
      assert.is_nil(getmetatable(operation))
      local allowed = operation.type == "move"
          and { from = true, kind = true, to = true, type = true }
        or operation.type == "delete"
          and { kind = true, path = true, type = true }
        or { path = true, type = true }
      for key in pairs(operation) do assert.is_true(allowed[key] == true, key) end
    end

    first.operations[1].to = "caller-mutated"
    first.operations[#first.operations + 1] = { type = "invented" }
    first.display[1] = "caller-mutated"
    local second = instance:prepare()
    assert.are.same(expected, second)
    assert.are.equal(serialized, vim.inspect(second))
    assert.are_not.equal(first, second)
    assert.are_not.equal(first.operations, second.operations)
  end)

  it("uses practical Windows equality and lowers case-only cycles", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local root = { id = 1, path = "C:/Project", kind = "directory" }
    local a = { id = 2, path = "C:/Project/A.txt", kind = "file", name = "A.txt" }
    local b = { id = 3, path = "C:/Project/B.txt", kind = "file", name = "B.txt" }
    local fake = {
      id = 777,
      bufnr = bufnr,
      root = root.path,
      root_node = root,
      state = "ready",
      config = { columns = {} },
      nodes_by_id = { [1] = root, [2] = a, [3] = b },
      view = {
        baseline = { [2] = a.path, [3] = b.path },
        visible_nodes = { a, b },
      },
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
    local marker_widths = { instance = 3, node = 3 }
    fake.manager = {
      find_by_id = function(_, id) return id == fake.id and fake or nil end,
      get_marker_widths = function() return marker_widths end,
    }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      row.marker(fake.manager, fake.id, a.id) .. "b.txt",
    })
    local plan = mutation_prepare.prepare(fake)
    assert.are.same({
      { type = "delete", path = "C:/Project/B.txt", kind = "file" },
      {
        type = "move", from = "C:/Project/A.txt", to = "C:/Project/b.txt",
        kind = "file",
      },
    }, plan.operations)

    fake.nodes_by_id[3] = nil
    fake.view.baseline[3] = nil
    fake.view.visible_nodes = { a }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      row.marker(fake.manager, fake.id, a.id) .. "a.txt",
    })
    plan = mutation_prepare.prepare(fake)
    assert.are.same({
      {
        type = "move", from = "C:/Project/A.txt",
        to = "C:/Project/.A.txt.fre-tmp-move-cycle-1", kind = "file",
      },
      {
        type = "move", from = "C:/Project/.A.txt.fre-tmp-move-cycle-1",
        to = "C:/Project/a.txt", kind = "file",
      },
    }, plan.operations)
    assert.are.same({ "MOVE  A.txt -> a.txt" }, plan.display)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
