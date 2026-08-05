local actions = require("fre.actions")
local buffer = require("fre.instance.buffer")
local columns = require("fre.columns")
local fre = require("fre")
local manager_module = require("fre.manager")
local path = require("fre.path")
local real_fs = require("fre.fs").default
local fs = require("tests.helpers.fs")

local fixture
local original_geometry

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
  opts = vim.tbl_extend("force", { root = fixture.root, columns = {} }, opts or {})
  return wait_ready(fre.new(opts))
end

local function open_current(instance)
  instance:open({ position = "current" })
  return vim.api.nvim_get_current_win()
end

local function row_for(instance, name)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local entry = instance:get_entry(row)
    if entry and entry.name == name then return row, entry end
  end
  error("missing entry " .. name)
end

local function context_for(instance, name)
  local row = row_for(instance, name)
  local winid = open_current(instance)
  vim.api.nvim_win_set_cursor(winid, { row, 0 })
  return actions.context()
end

local function error_text(callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  return tostring(err)
end

local function keymaps(bufnr, mode)
  local result = {}
  for _, item in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    result[item.lhs] = item
  end
  return result
end

local function invoke(bufnr, mode, lhs)
  local item = assert(keymaps(bufnr, mode)[lhs], "missing mapping " .. lhs)
  assert.are.equal("function", type(item.callback))
  return item.callback()
end

local function manager_instances()
  local result = {}
  for _, instance in pairs(manager_module.default.instances_by_id) do
    result[#result + 1] = instance
  end
  return result
end

local function instance_count()
  local count = 0
  for _ in pairs(manager_module.default.instances_by_id) do count = count + 1 end
  return count
end

local function window_buffers()
  local result = {}
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      result[winid] = vim.api.nvim_win_get_buf(winid)
    end
  end
  return result
end

local function set_line(instance, row, line)
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, row - 1, row, false, { line })
  vim.bo[instance.bufnr].modifiable = modifiable
end

local function screenpos(winid)
  local value = vim.fn.win_screenpos(winid)
  return value[1], value[2]
end

local function confirmation_adapter()
  local adapter = { decisions = {} }
  function adapter.confirm(_, _, decide)
    adapter.decisions[#adapter.decisions + 1] = decide
    return {}
  end
  function adapter.progress() return {} end
  function adapter.report() end
  return adapter
end

describe("fre ticket 17 actions and mappings", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    vim.cmd("enew")
    fixture = fs.new()
    actions._reset_ui_adapter()
    fre._reset_fs_adapter()
    fre.setup({ default_file_explorer = false })
    original_geometry = {
      columns = vim.o.columns,
      lines = vim.o.lines,
      cmdheight = vim.o.cmdheight,
      laststatus = vim.o.laststatus,
      showtabline = vim.o.showtabline,
    }
    vim.o.columns = 120
    vim.o.lines = 40
    vim.o.cmdheight = 1
    vim.o.laststatus = 0
    vim.o.showtabline = 0
  end)

  after_each(function()
    actions._reset_ui_adapter()
    for _, instance in ipairs(manager_instances()) do
      if instance:status() ~= "destroyed" then pcall(instance.destroy, instance) end
    end
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    vim.o.columns = original_geometry.columns
    vim.o.lines = original_geometry.lines
    vim.o.cmdheight = original_geometry.cmdheight
    vim.o.laststatus = original_geometry.laststatus
    vim.o.showtabline = original_geometry.showtabline
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("exports only the ordinary action interface", function()
    local names = {
      "context", "expand", "collapse", "collapse_all", "toggle_expand", "reveal", "jump_to_path",
      "open", "hidden", "toggle", "set_hidden_file", "toggle_hidden_file", "refresh",
      "select", "tab_select", "split_select", "confirm", "write", "destroy",
    }
    for _, name in ipairs(names) do assert.are.equal("function", type(actions[name]), name) end
    assert.is_nil(actions.dispatch)
    assert.is_nil(actions.descriptors)
  end)

  it("builds fresh exact normal and visual contexts and propagates malformed-row errors", function()
    local instance = ready({ ["alpha.txt"] = "a", ["beta.txt"] = "b" })
    local row = row_for(instance, "alpha.txt")
    local winid = open_current(instance)
    local decoded = instance.buffer:decode(row)
    vim.api.nvim_win_set_cursor(winid, { row, decoded.visible_range.start_byte })

    local first = actions.context()
    local second = actions.context()
    assert.are.equal(instance, first.instance)
    assert.are.equal(instance.bufnr, first.bufnr)
    assert.are.equal(winid, first.winid)
    assert.are.equal(vim.api.nvim_get_current_tabpage(), first.tabpage)
    assert.are.equal("n", first.mode)
    assert.are.equal(row, first.row)
    assert.are.equal(decoded.visible_range.start_byte, first.col)
    assert.are.same(instance:get_entry(row), first.entry)
    assert.are_not.equal(first.entry, second.entry)
    assert.is_nil(first.range)
    assert.are.same({
      winid = winid, origin_winid = winid, layout = { position = "current" },
    }, first.view)
    for _, field in ipairs({
      "layout", "origin", "origin_winid", "visibility",
      "generation", "token", "reconciliation",
    }) do
      assert.is_nil(first[field], field)
    end

    vim.cmd("normal! vll")
    local visual = actions.context()
    assert.are.equal("v", visual.mode)
    assert.are.equal(row, visual.range.start.row)
    assert.are.equal(decoded.visible_range.start_byte, visual.range.start.col)
    assert.are.equal(row, visual.range.finish.row)
    assert.are.equal(decoded.visible_range.start_byte + 2, visual.range.finish.col)
    vim.cmd("normal! \27")

    local original = vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1]
    set_line(instance, row, string.char(31) .. "fre:bad" .. string.char(31) .. "alpha.txt")
    local direct = error_text(function() instance:get_entry(row) end)
    local contextual = error_text(actions.context)
    assert.is_truthy(direct:find("row " .. row, 1, true))
    assert.is_truthy(contextual:find("row " .. row, 1, true))
    set_line(instance, row, original)

    vim.cmd("enew")
    assert.is_truthy(error_text(actions.context):find("not a live Fre instance", 1, true))
  end)

  it("jumps entry and navigation rows to path while ignoring new and malformed rows", function()
    fixture:tree({ ["child/a.txt"] = "a" })
    local instance = wait_ready(fre.new({
      root = fixture:path("child"),
      columns = { columns.size() },
      mapping = { n = { gp = actions.jump_to_path } },
    }))
    local winid = open_current(instance)

    local navigation = assert(instance.buffer:decode(1))
    vim.api.nvim_win_set_cursor(winid, { 1, navigation.column_ranges[1].start_byte })
    invoke(instance.bufnr, "n", "gp")
    assert.are.same({ 1, navigation.path_range.start_byte }, vim.api.nvim_win_get_cursor(winid))

    local entry_row = row_for(instance, "a.txt")
    local entry = assert(instance.buffer:decode(entry_row))
    vim.api.nvim_win_set_cursor(winid, { entry_row, entry.column_ranges[1].start_byte })
    invoke(instance.bufnr, "n", "gp")
    assert.are.same(
      { entry_row, entry.path_range.start_byte }, vim.api.nvim_win_get_cursor(winid))

    set_line(instance, entry_row, "draft.txt")
    vim.api.nvim_win_set_cursor(winid, { entry_row, 2 })
    local before = vim.api.nvim_win_get_cursor(winid)
    local ok, err = pcall(invoke, instance.bufnr, "n", "gp")
    assert.is_true(ok, tostring(err))
    assert.are.same(before, vim.api.nvim_win_get_cursor(winid))

    set_line(instance, entry_row, string.char(31) .. "fre:bad" .. string.char(31) .. "a.txt")
    vim.api.nvim_win_set_cursor(winid, { entry_row, 0 })
    before = vim.api.nvim_win_get_cursor(winid)
    ok, err = pcall(invoke, instance.bufnr, "n", "gp")
    assert.is_true(ok, tostring(err))
    assert.are.same(before, vim.api.nvim_win_get_cursor(winid))
    assert.is_truthy(error_text(actions.context):find("row " .. entry_row, 1, true))
  end)

  it("runs built-in collapse_all from an undecodable current row", function()
    local instance = ready({ ["dir/file.txt"] = "x" })
    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/file.txt") ~= nil end)
    local winid = open_current(instance)
    local row = row_for(instance, "dir")
    vim.api.nvim_win_set_cursor(winid, { row, 0 })
    set_line(instance, row, string.char(31) .. "fre:bad" .. string.char(31) .. "dir/")
    vim.bo[instance.bufnr].modified = false
    assert.is_truthy(error_text(actions.context):find("row " .. row, 1, true))

    local ok, err = pcall(invoke, instance.bufnr, "n", "zM")

    assert.is_true(ok, tostring(err))
    assert.is_false(instance.tree.nodes_by_path[fixture:path("dir")].expanded)
    assert.is_nil(instance:get_pos("dir/file.txt"))
  end)

  it("installs the exact default normal map base with no h, l, insert, or visual defaults", function()
    local instance = ready({ ["a.txt"] = "a" })
    local normal = keymaps(instance.bufnr, "n")
    local actual = {}
    for lhs in pairs(normal) do actual[#actual + 1] = lhs end
    table.sort(actual)
    assert.are.same({ "<CR>", "R", "g.", "q", "zM", "za", "zc", "zv" }, actual)
    assert.is_nil(normal.h)
    assert.is_nil(normal.l)
    assert.are.same({}, keymaps(instance.bufnr, "i"))
    assert.are.same({}, keymaps(instance.bufnr, "v"))
    assert.is_nil(rawget(instance.buffer, "mapping"))
  end)

  it("overlays setup and new maps once, supports defaults-off, and isolates caller tables", function()
    local calls = {}
    local setup_x = function(ctx) calls[#calls + 1] = { "setup", ctx } end
    local new_x = function(ctx) calls[#calls + 1] = { "new", ctx } end
    local new_visual = function(ctx) calls[#calls + 1] = { "visual", ctx } end
    local setup_opts = { mapping = { n = { x = setup_x, y = setup_x } } }
    fre.setup(setup_opts)
    setup_opts.mapping.n.x = function() error("mutated setup") end
    setup_opts.mapping.n.z = setup_x

    local new_opts = {
      root = fixture:tree({ ["a.txt"] = "a", ["b.txt"] = "b" }),
      columns = {},
      mapping = { n = { x = new_x }, v = { X = new_visual } },
    }
    local instance = wait_ready(fre.new(new_opts))
    new_opts.mapping.n.x = function() error("mutated new") end
    new_opts.mapping.n.extra = new_x
    assert.is_nil(rawget(instance.buffer, "mapping"))

    local winid = open_current(instance)
    local row_a = row_for(instance, "a.txt")
    vim.api.nvim_win_set_cursor(winid, { row_a, 0 })
    invoke(instance.bufnr, "n", "x")
    local first_entry = calls[1][2].entry
    local row_b = row_for(instance, "b.txt")
    vim.api.nvim_win_set_cursor(winid, { row_b, 0 })
    invoke(instance.bufnr, "n", "x")
    assert.are.same(instance:get_entry(row_a), first_entry)
    assert.are.same(instance:get_entry(row_b), calls[2][2].entry)
    assert.are_not.equal(first_entry, calls[2][2].entry)
    assert.is_nil(keymaps(instance.bufnr, "n").extra)
    assert.is_nil(keymaps(instance.bufnr, "n").z)

    local only = ready({ ["only.txt"] = "x" }, {
      use_mapping_default = false,
      mapping = { n = { k = setup_x } },
    })
    local only_maps = keymaps(only.bufnr, "n")
    assert.is_not_nil(only_maps.k)
    assert.is_not_nil(only_maps.x)
    assert.is_not_nil(only_maps.y)
    assert.are.equal(3, vim.tbl_count(only_maps))
    assert.is_nil(keymaps(only.bufnr, "n")["<CR>"])
  end)

  it("keeps thin actions on ctx.instance and snapshot entry paths", function()
    local calls = {}
    local fake = { bufnr = 91 }
    for _, name in ipairs({ "expand", "collapse", "toggle_expand", "reveal" }) do
      fake[name] = function(_, value) calls[#calls + 1] = { name, value } end
    end
    fake.open = function(_, value) calls[#calls + 1] = { "open", value } end
    fake.hidden = function() calls[#calls + 1] = { "hidden" } end
    fake.toggle = function(_, value) calls[#calls + 1] = { "toggle", value } end
    fake.set_hidden_file = function(_, value) calls[#calls + 1] = { "set_hidden_file", value } end
    fake.toggle_hidden_file = function() calls[#calls + 1] = { "toggle_hidden_file" } end
    fake.destroy = function() calls[#calls + 1] = { "destroy" } end
    fake.collapse_all = function() calls[#calls + 1] = { "collapse_all" } end
    local ctx = {
      instance = fake, bufnr = fake.bufnr,
      entry = { absolute_path = "snapshot/path", kind = "directory" },
    }
    actions.expand(ctx)
    actions.collapse(ctx)
    actions.toggle_expand(ctx)
    actions.collapse_all(ctx)
    actions.reveal(ctx)
    actions.open(ctx, { layout = { position = "current" } })
    actions.hidden(ctx)
    actions.toggle(ctx, { layout = { position = "left", size = 10 } })
    actions.set_hidden_file(ctx, { hidden_file = true })
    actions.toggle_hidden_file(ctx)
    actions.destroy(ctx)
    assert.are.same({
      { "expand", "snapshot/path" }, { "collapse", "snapshot/path" },
      { "toggle_expand", "snapshot/path" }, { "collapse_all" }, { "reveal", "snapshot/path" },
      { "open", { position = "current" } }, { "hidden" },
      { "toggle", { position = "left", size = 10 } },
      { "set_hidden_file", true }, { "toggle_hidden_file" }, { "destroy" },
    }, calls)
  end)

  it("collapses every cached directory once through zM and preserves valid window cursors", function()
    local instance = ready({ ["a/n/deep.txt"] = "x", ["b/file.txt"] = "y" })
    instance:expand("a/n")
    instance:expand("b")
    wait_for(function()
      return instance:get_pos("a/n/deep.txt") ~= nil and instance:get_pos("b/file.txt") ~= nil
    end)
    wait_for(function()
      for _, node in pairs(instance.tree.nodes_by_id) do
        if node.kind == "directory"
            and (node.load_state == "loading" or node.load_state == "refreshing") then
          return false
        end
      end
      return true
    end)
    local a = instance.tree.nodes_by_path[fixture:path("a")]
    local n = instance.tree.nodes_by_path[fixture:path("a", "n")]
    local b = instance.tree.nodes_by_path[fixture:path("b")]
    local deep = instance.tree.nodes_by_path[fixture:path("a", "n", "deep.txt")]
    local deep_id = deep.id
    local first = open_current(instance)
    vim.cmd("vsplit")
    local second = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(first, instance:get_pos("a/n/deep.txt"))
    vim.api.nvim_win_set_cursor(second, { 1, 0 })

    local commits, syncs = 0, 0
    local commit = instance.buffer.commit
    local sync = instance.sync.sync_watchers
    instance.buffer.commit = function(self, ...)
      commits = commits + 1
      return commit(self, ...)
    end
    instance.sync.sync_watchers = function(self, ...)
      syncs = syncs + 1
      return sync(self, ...)
    end
    invoke(instance.bufnr, "n", "zM")

    assert.are.equal(1, commits)
    assert.are.equal(1, syncs)
    assert.is_true(instance.tree:root_node().expanded)
    assert.is_false(instance.tree:node_by_id(a.id).expanded)
    assert.is_false(instance.tree:node_by_id(n.id).expanded)
    assert.is_false(instance.tree:node_by_id(b.id).expanded)
    assert.is_true(instance.tree:node_by_id(a.id).children_cached)
    assert.is_true(instance.tree:node_by_id(n.id).children_cached)
    assert.are.equal(deep_id, instance.tree:node_by_id(deep_id).id)
    assert.are.equal(deep_id, instance.tree:node_by_path(deep.path).id)
    local line_count = vim.api.nvim_buf_line_count(instance.bufnr)
    for _, winid in ipairs({ first, second }) do
      local cursor = vim.api.nvim_win_get_cursor(winid)
      assert.is_true(cursor[1] >= 1 and cursor[1] <= line_count)
    end

    invoke(instance.bufnr, "n", "zM")
    assert.are.equal(1, commits)
    assert.are.equal(1, syncs)
  end)

  it("uses snapshot paths and the captured default target despite ambient focus changes", function()
    local target_path = fixture:write("target.txt", "target")
    local link = fixture:symlink(target_path, "target-link")
    local instance = ready({ ["other.txt"] = "other" })
    local ctx = context_for(instance, "target.txt")
    local source_tab = ctx.tabpage
    local row = ctx.row
    local line = vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1]
    set_line(instance, row, line:gsub("target%.txt$", "edited-destination.txt"))
    vim.cmd("vsplit")
    local ambient_win = vim.api.nvim_get_current_win()
    local ambient_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(ambient_win, ambient_buf)

    local bufnr = actions.select(ctx)

    assert.are.equal(path.absolute(target_path), vim.api.nvim_buf_get_name(bufnr))
    assert.are.equal(bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    assert.are.equal(ambient_buf, vim.api.nvim_win_get_buf(ambient_win))
    assert.is_nil(fre.view.inspect(instance, source_tab))
    assert.are.equal("ready", instance:status())

    if link then
      local linked = ready({})
      local link_ctx = context_for(linked, "target-link")
      assert.are.equal("symlink", link_ctx.entry.kind)
      local link_buf = actions.select(link_ctx)
      assert.are.equal(path.absolute(target_path), vim.api.nvim_buf_get_name(link_buf))
      assert.are.equal(link_buf, vim.api.nvim_win_get_buf(link_ctx.winid))
      assert.is_nil(fre.view.inspect(linked, link_ctx.tabpage))
    end
  end)

  it("keeps a split-created Instance mapping selection in its own View", function()
    local first = ready({ ["dir/second.txt"] = "second" })
    local first_win = open_current(first)
    vim.api.nvim_win_set_cursor(first_win, { row_for(first, "dir"), 0 })
    local first_ctx = actions.context()
    local second = wait_ready(actions.split_select(first_ctx, {
      layout = { position = "right", size = 24 },
    }))
    local second_win = vim.api.nvim_get_current_win()
    assert.are.equal(first.bufnr, vim.api.nvim_win_get_buf(first_win))
    assert.are.equal(second.bufnr, vim.api.nvim_win_get_buf(second_win))
    vim.api.nvim_win_set_cursor(second_win, { row_for(second, "second.txt"), 0 })
    local second_file = invoke(second.bufnr, "n", "<CR>")
    assert.are.equal(second_file, vim.api.nvim_win_get_buf(second_win))
    assert.are.equal(path.absolute(fixture:path("dir/second.txt")), vim.api.nvim_buf_get_name(second_file))
    assert.are.equal(first.bufnr, vim.api.nvim_win_get_buf(first_win))
  end)

  it("detaches exact managed file targets and leaves ordinary targets ordinary", function()
    local instance = ready({ ["file.txt"] = "x", ["other.txt"] = "y" })
    local source_win = open_current(instance)
    local source_tab = vim.api.nvim_get_current_tabpage()
    local ctx = context_for(instance, "file.txt")
    local target_owner = wait_ready(fre.new({ root = fixture.root, columns = {} }))
    local _, managed_win = target_owner:open({ position = "right", size = 24 })
    local managed_before = assert(fre.view.inspect(target_owner, source_tab))

    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    target_owner:open({ position = "current" })
    vim.api.nvim_set_current_tabpage(source_tab)
    vim.api.nvim_set_current_win(source_win)

    local managed_file = actions.select(ctx, { target_winid = managed_win })

    assert.are.equal(managed_file, vim.api.nvim_win_get_buf(managed_win))
    assert.is_nil(fre.view.inspect(target_owner, source_tab))
    assert.is_not_nil(fre.view.inspect(target_owner, other_tab))
    assert.are.same({
      winid = source_win, origin_winid = source_win, layout = { position = "current" },
    }, fre.view.inspect(instance, source_tab))
    assert.are.equal("right", managed_before.layout.position)

    vim.api.nvim_set_current_win(source_win)
    vim.cmd("vsplit")
    local ordinary_win = vim.api.nvim_get_current_win()
    local ordinary_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(ordinary_win, ordinary_buf)
    vim.api.nvim_set_current_win(source_win)
    ctx = actions.context()
    ctx.entry = vim.deepcopy(select(2, row_for(instance, "other.txt")))
    local ordinary_file = actions.select(ctx, { target_winid = ordinary_win })

    assert.are.equal(ordinary_file, vim.api.nvim_win_get_buf(ordinary_win))
    assert.is_not_nil(fre.view.inspect(instance, source_tab))
    assert.is_nil(manager_module.default:find_by_buf(ordinary_file))
  end)

  it("defaults hide_source to false and hides only the captured source tab when true", function()
    local instance = ready({ ["file.txt"] = "x" })
    local source_win = open_current(instance)
    local source_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(target_win, vim.api.nvim_create_buf(false, true))

    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    instance:open({ position = "current" })
    vim.api.nvim_set_current_tabpage(source_tab)
    vim.api.nvim_set_current_win(source_win)
    local ctx = context_for(instance, "file.txt")
    assert.is_truthy(error_text(function()
      actions.select(ctx, { target_winid = target_win, hide_source = "yes" })
    end):find("hide_source", 1, true))
    assert.is_not_nil(fre.view.inspect(instance, source_tab))

    actions.select(ctx, { target_winid = target_win, hide_source = true })

    assert.is_nil(fre.view.inspect(instance, source_tab))
    assert.is_not_nil(fre.view.inspect(instance, other_tab))
    assert.are.equal(path.absolute(fixture:path("file.txt")),
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target_win)))
  end)

  it("rejects file instance options before buffer, target, manager, or source mutation", function()
    local instance = ready({ ["file.txt"] = "x" })
    local ctx = context_for(instance, "file.txt")
    local source_view = assert(fre.view.inspect(instance, ctx.tabpage))
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(target_win, target_buf)
    vim.api.nvim_set_current_win(ctx.winid)

    local selected_path = path.absolute(fixture:path("file.txt"))
    local before_count = instance_count()
    local before_windows = window_buffers()
    assert.are.equal(-1, vim.fn.bufnr(selected_path))

    for _, override in ipairs({ { hidden_file = false }, "bad", { root = "other" } }) do
      local err = error_text(function()
        actions.select(ctx, { target_winid = target_win, instance = override })
      end)
      assert.is_truthy(err:find("only valid for directory selections", 1, true))
      assert.are.equal(-1, vim.fn.bufnr(selected_path))
      assert.are.same(before_windows, window_buffers())
      assert.are.equal(before_count, instance_count())
      assert.are.equal(instance, manager_module.default:find_by_id(instance.id))
      assert.are.equal(instance, manager_module.default:find_by_buf(instance.bufnr))
      assert.are.equal(target_buf, vim.api.nvim_win_get_buf(target_win))
      assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(ctx.winid))
      assert.are.same(source_view, fre.view.inspect(instance, ctx.tabpage))
    end
  end)

  it("keeps a same-target file committed when hide_source becomes a no-op", function()
    local instance = ready({ ["file.txt"] = "x" })
    local ctx = context_for(instance, "file.txt")

    local bufnr = actions.select(ctx, { hide_source = true })

    assert.is_true(vim.api.nvim_win_is_valid(ctx.winid))
    assert.are.equal(bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    assert.are.equal(path.absolute(fixture:path("file.txt")), vim.api.nvim_buf_get_name(bufnr))
    assert.is_nil(fre.view.inspect(instance, ctx.tabpage))
    assert.are.equal(instance, manager_module.default:find_by_id(instance.id))
  end)

  it("resolves every exact file return and native duplicate from editor state", function()
    local instance = ready({ ["file.txt"] = "x" })
    local previous_bufnr = vim.api.nvim_get_current_buf()
    local ctx = context_for(instance, "file.txt")
    local selected = actions.select(ctx)

    assert.is_nil(fre.view.inspect(instance, ctx.tabpage))
    vim.cmd("vsplit")
    local duplicate = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(duplicate, instance.bufnr)
    assert.are.same({
      winid = duplicate, origin_winid = duplicate, layout = { position = "current" },
    }, fre.view.inspect(instance, ctx.tabpage))
    local duplicate_ctx = actions.context()
    assert.are.equal(duplicate, duplicate_ctx.winid)
    assert.are.same(fre.view.inspect(instance, { winid = duplicate }), duplicate_ctx.view)
    vim.api.nvim_win_close(duplicate, true)

    vim.api.nvim_set_current_win(ctx.winid)
    vim.api.nvim_win_set_buf(ctx.winid, instance.bufnr)
    assert.are.same({
      winid = ctx.winid,
      origin_winid = ctx.winid,
      layout = { position = "current" },
    }, fre.view.inspect(instance, ctx.tabpage))

    assert.is_true(instance:hidden(ctx.tabpage))
    assert.are.equal(previous_bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    vim.api.nvim_win_set_buf(ctx.winid, selected)
    vim.api.nvim_win_set_buf(ctx.winid, instance.bufnr)
    assert.is_not_nil(fre.view.inspect(instance, ctx.tabpage))
  end)

  it("runs exact buffer-local mappings in both horizontal duplicate Views", function()
    local seen = {}
    local instance = ready({ ["file.txt"] = "x" }, {
      mapping = { n = { x = function(ctx)
        seen[#seen + 1] = { winid = ctx.winid, view = ctx.view }
      end } },
    })
    local first = open_current(instance)
    vim.cmd("split")
    local second = vim.api.nvim_get_current_win()
    assert.are_not.equal(first, second)

    invoke(instance.bufnr, "n", "x")
    vim.api.nvim_set_current_win(first)
    invoke(instance.bufnr, "n", "x")

    assert.are.equal(second, seen[1].winid)
    assert.are.equal(first, seen[2].winid)
    assert.are.same(fre.view.inspect(instance, { winid = second }), seen[1].view)
    assert.are.same(fre.view.inspect(instance, { winid = first }), seen[2].view)
  end)

  it("keeps a same-target directory child committed when hide_source becomes a no-op", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")

    local child = actions.select(ctx, { hide_source = true })

    assert.is_true(vim.api.nvim_win_is_valid(ctx.winid))
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    assert.is_nil(fre.view.inspect(instance, ctx.tabpage))
    assert.are.same({
      winid = ctx.winid,
      origin_winid = ctx.winid,
      layout = { position = "current" },
    }, fre.view.inspect(child, ctx.tabpage))
    assert.are.equal(child, manager_module.default:find_by_buf(child.bufnr))
  end)

  it("rejects invalid entries, sources, and targets before child or destination mutation", function()
    local instance = ready({ ["file.txt"] = "x", ["dir/child.txt"] = "y" })
    local source_win = open_current(instance)
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(target_win, target_buf)
    vim.api.nvim_set_current_win(source_win)
    local ctx = context_for(instance, "dir")
    local before_count = instance_count()

    local stale = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor", width = 5, height = 2, row = 0, col = 0,
    })
    vim.api.nvim_win_close(stale, true)
    assert.is_truthy(error_text(function()
      actions.select(ctx, { target_winid = stale })
    end):find("target window", 1, true))
    assert.are.equal(before_count, instance_count())
    assert.are.equal(target_buf, vim.api.nvim_win_get_buf(target_win))

    local missing = vim.tbl_extend("force", {}, ctx)
    missing.entry = nil
    assert.is_truthy(error_text(function() actions.select(missing) end):find("requires an entry", 1, true))
    assert.are.equal(before_count, instance_count())

    vim.api.nvim_win_set_buf(source_win, vim.api.nvim_create_buf(false, true))
    assert.is_truthy(error_text(function()
      actions.select(ctx, { target_winid = target_win })
    end):find("source is no longer valid", 1, true))
    assert.are.equal(before_count, instance_count())
    assert.are.equal(target_buf, vim.api.nvim_win_get_buf(target_win))
  end)

  it("preserves current-position policy for a directory child and restores its prior buffer", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local previous_buf = vim.api.nvim_get_current_buf()
    local ctx = context_for(instance, "dir")
    local source_win = ctx.winid
    local source_tab = ctx.tabpage

    local child = actions.select(ctx)
    local child_view = assert(fre.view.inspect(child, source_tab))

    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(source_win))
    assert.is_nil(fre.view.inspect(instance, source_tab))
    assert.are.same({
      winid = source_win,
      origin_winid = source_win,
      layout = { position = "current" },
    }, child_view)

    child:hidden(source_tab)

    assert.are.equal(previous_buf, vim.api.nvim_win_get_buf(source_win))
    assert.is_nil(fre.view.inspect(child, source_tab))
  end)

  it("transfers split layout and close-on-hide behavior to a directory child", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local _, source_win = instance:open({ position = "right", size = 23 })
    local source_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_win_set_cursor(source_win, { row_for(instance, "dir"), 0 })
    local ctx = actions.context()
    local source_view = assert(fre.view.inspect(instance, source_tab))

    local child = actions.select(ctx)

    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(source_win))
    assert.is_nil(fre.view.inspect(instance, source_tab))
    assert.are.same(source_view, fre.view.inspect(child, source_tab))

    child:hidden(source_tab)

    assert.is_false(vim.api.nvim_win_is_valid(source_win))
    assert.is_nil(fre.view.inspect(child, source_tab))
  end)

  it("transfers a float directory View with its exact origin and layout", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local origin_win = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_get_current_buf()
    local requested = {
      position = "float", width = 31, height = 9, row = 3, col = 7, border = "single",
    }
    local _, source_win = instance:open(requested)
    local source_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_win_set_cursor(source_win, { row_for(instance, "dir"), 0 })
    local ctx = actions.context()
    local source_view = assert(fre.view.inspect(instance, source_tab))
    assert.are.equal(origin_win, source_view.origin_winid)
    assert.are_not.equal(source_win, source_view.origin_winid)
    assert.are.same(requested, source_view.layout)

    local child = actions.select(ctx)

    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(source_win))
    assert.is_nil(fre.view.inspect(instance, source_tab))
    assert.are.same(source_view, fre.view.inspect(child, source_tab))

    child:hidden(source_tab)

    assert.is_false(vim.api.nvim_win_is_valid(source_win))
    assert.is_true(vim.api.nvim_win_is_valid(origin_win))
    assert.are.equal(origin_buf, vim.api.nvim_win_get_buf(origin_win))
    assert.is_nil(fre.view.inspect(child, source_tab))
  end)

  it("transfers noautocmd external split and float Views while source lookup is absent", function()
    for _, kind in ipairs({ "split", "float" }) do
      pcall(vim.cmd, "silent! only")
      local instance = ready({ ["dir/child.txt"] = "x" })
      local previous_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(previous_buf, 0, -1, false, { kind .. " previous" })
      local source_win
      if kind == "split" then
        vim.cmd("vsplit")
        source_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(source_win, previous_buf)
      else
        source_win = vim.api.nvim_open_win(previous_buf, true, {
          relative = "editor", width = 29, height = 7, row = 2, col = 5,
          border = "single", noautocmd = true,
        })
      end
      vim.cmd("noautocmd buffer " .. tostring(instance.bufnr))
      vim.api.nvim_win_set_cursor(source_win, { row_for(instance, "dir"), 0 })
      local ctx = actions.context()
      local expected_view = { winid = source_win }
      if kind == "split" then
        expected_view.origin_winid = source_win
        expected_view.layout = { position = "current" }
      else
        local config = vim.api.nvim_win_get_config(source_win)
        expected_view.layout = {
          position = "float", width = config.width, height = config.height,
          row = config.row, col = config.col, border = vim.deepcopy(config.border),
        }
      end
      local manager = manager_module.default
      manager.instances_by_id[instance.id] = nil
      manager.instances_by_buf[instance.bufnr] = nil

      local ok, child = pcall(actions.select, ctx)
      manager.instances_by_id[instance.id] = instance
      manager.instances_by_buf[instance.bufnr] = instance
      assert.is_true(ok, tostring(child))

      assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(source_win))
      assert.is_nil(fre.view.inspect(instance, { winid = source_win }))
      assert.are.same(expected_view, fre.view.inspect(child, { winid = source_win }))
      child:hidden(ctx.tabpage)
      assert.is_true(vim.api.nvim_win_is_valid(source_win))
      assert.are.equal(previous_buf, vim.api.nvim_win_get_buf(source_win))
      child:destroy()
      instance:destroy()
      if vim.api.nvim_win_is_valid(source_win) and kind == "float" then
        vim.api.nvim_win_close(source_win, true)
      end
    end
  end)

  it("captures a distinct noautocmd target owner through default managed lookup", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")
    local target_owner = ready({ ["other.txt"] = "other" })
    local previous_buf = vim.api.nvim_create_buf(false, true)
    local target_win = vim.api.nvim_open_win(previous_buf, false, {
      relative = "editor", width = 27, height = 6, row = 4, col = 8,
      border = "double", noautocmd = true,
    })
    vim.api.nvim_win_call(target_win, function()
      vim.cmd("noautocmd buffer " .. tostring(target_owner.bufnr))
    end)
    local config = vim.api.nvim_win_get_config(target_win)
    local expected_view = {
      winid = target_win,
      layout = {
        position = "float", width = config.width, height = config.height,
        row = config.row, col = config.col, border = vim.deepcopy(config.border),
      },
    }

    local child = actions.select(ctx, { target_winid = target_win })

    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(target_win))
    assert.is_nil(fre.view.inspect(target_owner, { winid = target_win }))
    assert.are.same(expected_view, fre.view.inspect(child, { winid = target_win }))
    child:hidden(ctx.tabpage)
    assert.is_true(vim.api.nvim_win_is_valid(target_win))
    assert.are.equal(previous_buf, vim.api.nvim_win_get_buf(target_win))
    child:destroy()
    target_owner:destroy()
    instance:destroy()
    if vim.api.nvim_win_is_valid(target_win) then vim.api.nvim_win_close(target_win, true) end
  end)

  it("establishes an ordinary target View immediately and restores its buffer after loading", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    local previous_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(previous_buf, 0, -1, false, { "ordinary target" })
    vim.api.nvim_win_set_buf(target_win, previous_buf)
    vim.api.nvim_set_current_win(ctx.winid)

    local release
    fre._set_fs_adapter({
      load = function(scan_path, done)
        real_fs.load(scan_path, function(...)
          local values = { n = select("#", ...), ... }
          release = function() done(unpack(values, 1, values.n)) end
        end)
      end,
    })

    local child = actions.select(ctx, { target_winid = target_win })

    assert.are.equal("creating", child:status())
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(target_win))
    assert.are.same({
      winid = target_win,
      origin_winid = target_win,
      layout = { position = "current" },
    }, fre.view.inspect(child, ctx.tabpage))
    wait_for(function() return release ~= nil end)
    release()
    wait_ready(child)

    child:hidden(ctx.tabpage)

    assert.are.equal(previous_buf, vim.api.nvim_win_get_buf(target_win))
    assert.is_nil(fre.view.inspect(child, ctx.tabpage))
  end)

  it("keeps an ordinary-target load-failed directory child installed and visible", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(target_win, vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_current_win(ctx.winid)
    local pending
    fre._set_fs_adapter({ load = function(_, done) pending = done end })

    local child = actions.select(ctx, { target_winid = target_win })

    assert.are.equal("creating", child:status())
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(target_win))
    assert.is_not_nil(fre.view.inspect(child, ctx.tabpage))
    assert.is_function(pending)
    pending("injected child load failure")
    wait_for(function() return child:status() == "load-failed" end)

    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(target_win))
    assert.is_not_nil(fre.view.inspect(child, ctx.tabpage))
    local line = vim.api.nvim_buf_get_lines(child.bufnr, 0, 1, false)[1]
    assert.is_truthy(line:find("[fre] Error loading injected child load failure", 1, true))
  end)

  it("rejects file selection when preparation invalidates the exact source", function()
    local instance = ready({ ["file.txt"] = "x" })
    local ctx = context_for(instance, "file.txt")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, { "ordinary target" })
    vim.api.nvim_win_set_buf(target_win, target_buf)
    vim.api.nvim_set_current_win(ctx.winid)
    local external_source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(external_source_buf, 0, -1, false, { "external source" })
    local selected_path = path.absolute(fixture:path("file.txt"))
    local before_count = instance_count()
    local raised = false
    local group = vim.api.nvim_create_augroup(
      "FreActionSourceBufReadPost" .. tostring(instance.id), { clear = true })
    vim.api.nvim_create_autocmd("BufReadPost", {
      group = group,
      once = true,
      callback = function(args)
        if path.equal(vim.api.nvim_buf_get_name(args.buf), selected_path) then
          raised = true
          vim.api.nvim_win_set_buf(ctx.winid, external_source_buf)
        end
      end,
    })

    local err = error_text(function()
      actions.select(ctx, { target_winid = target_win })
    end)
    vim.api.nvim_del_augroup_by_id(group)

    assert.is_truthy(err:find("source is no longer valid", 1, true))
    assert.is_true(raised)
    assert.are.equal(target_buf, vim.api.nvim_win_get_buf(target_win))
    assert.are.equal(external_source_buf, vim.api.nvim_win_get_buf(ctx.winid))
    assert.is_true(vim.api.nvim_buf_is_valid(external_source_buf))
    assert.are.equal(-1, vim.fn.bufnr(selected_path))
    assert.are.equal(before_count, instance_count())
  end)

  it("rejects directory selection when managed child registration invalidates the source", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, { "ordinary target" })
    vim.api.nvim_win_set_buf(target_win, target_buf)
    vim.api.nvim_set_current_win(ctx.winid)
    local external_source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(external_source_buf, 0, -1, false, { "external source" })
    local before_count = instance_count()
    local child
    local child_id
    local child_bufnr
    fre._set_fs_adapter({ load = function() end })
    local manager = manager_module.default
    local original_register = manager.register
    manager.register = function(target, created, policy)
      local registered = original_register(target, created, policy)
      if created ~= instance and path.equal(created.root, fixture:path("dir")) then
        child = created
        child_id = child.id
        child_bufnr = child.bufnr
        vim.api.nvim_win_set_buf(ctx.winid, external_source_buf)
      end
      return registered
    end

    local ok, err = pcall(actions.select, ctx, { target_winid = target_win })
    manager.register = original_register
    assert.is_false(ok)
    err = tostring(err)

    assert.is_truthy(err:find("source is no longer valid", 1, true))
    assert.is_not_nil(child)
    assert.are.equal("destroyed", child:status())
    assert.is_nil(manager_module.default:find_by_id(child_id))
    assert.is_nil(manager_module.default:find_by_buf(child_bufnr))
    assert.is_false(vim.api.nvim_buf_is_valid(child_bufnr))
    assert.are.equal(before_count, instance_count())
    assert.are.equal(target_buf, vim.api.nvim_win_get_buf(target_win))
    assert.are.equal(external_source_buf, vim.api.nvim_win_get_buf(ctx.winid))
    assert.is_true(vim.api.nvim_buf_is_valid(external_source_buf))
  end)

  it("cleans a directory child after an exact-target pre-commit install failure", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(target_win, target_buf)
    vim.api.nvim_set_current_win(ctx.winid)
    local before_count = instance_count()

    local err = error_text(function()
      actions.select(ctx, {
        target_winid = target_win,
        instance = { window = { options = { fre_not_a_real_option = true } } },
      })
    end)

    assert.is_truthy(err)
    assert.are.equal(before_count, instance_count())
    assert.are.equal(target_buf, vim.api.nvim_win_get_buf(target_win))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    assert.is_not_nil(fre.view.inspect(instance, ctx.tabpage))
  end)

  it("cleans a prepared child when the exact target buffer and owner change", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    local target_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(target_win, target_buf)
    vim.api.nvim_set_current_win(ctx.winid)
    local target_owner = wait_ready(fre.new({ root = fixture.root, columns = {} }))
    local source_view = assert(fre.view.inspect(instance, ctx.tabpage))
    local before_count = instance_count()
    local child_id
    local child_bufnr

    fre._set_fs_adapter({ load = function() end })
    local manager = manager_module.default
    local original_register = manager.register
    manager.register = function(target, created, policy)
      local registered = original_register(target, created, policy)
      if created ~= instance and created ~= target_owner
          and path.equal(created.root, fixture:path("dir")) then
        child_id = created.id
        child_bufnr = created.bufnr
        vim.api.nvim_set_current_win(target_win)
        target_owner:open({ position = "current" })
        vim.api.nvim_set_current_win(ctx.winid)
      end
      return registered
    end

    local ok, err = pcall(actions.select, ctx, { target_winid = target_win })
    manager.register = original_register
    assert.is_false(ok)
    err = tostring(err)

    assert.is_truthy(err:find("target window changed during selection preparation", 1, true))
    assert.is_not_nil(child_id)
    assert.is_not_nil(child_bufnr)
    assert.are.equal(before_count, instance_count())
    assert.is_nil(manager_module.default:find_by_id(child_id))
    assert.is_nil(manager_module.default:find_by_buf(child_bufnr))
    assert.is_false(vim.api.nvim_buf_is_valid(child_bufnr))
    assert.are.equal(target_owner.bufnr, vim.api.nvim_win_get_buf(target_win))
    assert.are.same({
      winid = target_win,
      origin_winid = target_win,
      layout = { position = "current" },
    }, fre.view.inspect(target_owner, ctx.tabpage))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    assert.are.same(source_view, fre.view.inspect(instance, ctx.tabpage))
  end)


  it("keeps a selected file committed after exact-target focus failure", function()
    local instance = ready({ ["file.txt"] = "x" })
    local ctx = context_for(instance, "file.txt")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(target_win, vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_current_win(ctx.winid)
    local set_current_win = vim.api.nvim_set_current_win
    vim.api.nvim_set_current_win = function(winid)
      if winid == target_win then error("injected focus failure") end
      return set_current_win(winid)
    end

    local ok, err = pcall(actions.select, ctx, { target_winid = target_win })
    vim.api.nvim_set_current_win = set_current_win

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected focus failure", 1, true))
    assert.are.equal(path.absolute(fixture:path("file.txt")),
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target_win)))
    assert.is_not_nil(fre.view.inspect(instance, ctx.tabpage))
  end)

  it("keeps a selected file committed after source-hide restoration failure", function()
    local instance = ready({ ["file.txt"] = "x" })
    local ctx = context_for(instance, "file.txt")
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(target_win, vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_current_win(ctx.winid)
    local set_win_buf = vim.api.nvim_win_set_buf
    vim.api.nvim_win_set_buf = function(winid, bufnr)
      if winid == ctx.winid then error("injected source-hide failure") end
      return set_win_buf(winid, bufnr)
    end

    local ok, err = pcall(actions.select, ctx, {
      target_winid = target_win, hide_source = true,
    })
    vim.api.nvim_win_set_buf = set_win_buf

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected source-hide failure", 1, true))
    assert.are.equal(path.absolute(fixture:path("file.txt")),
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target_win)))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    assert.is_not_nil(fre.view.inspect(instance, ctx.tabpage))
  end)

  it("returns to the parent with the previous root selected but not expanded", function()
    fixture:tree({
      ["child/nested/file.txt"] = "x",
      ["sibling.txt"] = "s",
    })
    local instance = wait_ready(fre.new({
      root = fixture:path("child"),
      columns = {},
    }))
    local winid = open_current(instance)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    local ctx = actions.context()
    assert.are.equal("navigation", ctx.row_kind)
    assert.are.equal("parent", ctx.navigation_kind)

    local parent = wait_ready(actions.select(ctx, {
      instance = { expanded = { "child" } },
    }))
    assert.is_nil(rawget(parent.sync, "expanded"))
    local previous_root = parent.tree.nodes_by_path[path.absolute(fixture:path("child"))]
    assert.is_not_nil(previous_root)
    assert.is_false(previous_root.expanded)
    assert.is_nil(parent:get_pos("child/nested"))
    assert.are.same(parent:get_pos("child"), vim.api.nvim_win_get_cursor(winid))
  end)

  it("returns to the parent with the previous root selected in tabs and splits", function()
    fixture:tree({ ["child/nested/file.txt"] = "x" })
    local cases = {
      { kind = "tab" },
      { kind = "split", layout = { position = "right", size = 20 } },
    }
    for _, case in ipairs(cases) do
      pcall(vim.cmd, "silent! tabonly")
      pcall(vim.cmd, "silent! only")
      vim.cmd("enew")
      local instance = wait_ready(fre.new({
        root = fixture:path("child"),
        columns = {},
      }))
      open_current(instance)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ctx = actions.context()
      local parent
      if case.kind == "tab" then
        parent = actions.tab_select(ctx)
      else
        parent = actions.split_select(ctx, { layout = case.layout })
      end
      wait_ready(parent)
      local winid = vim.api.nvim_get_current_win()
      assert.is_nil(rawget(parent.sync, "expanded"))
      assert.is_false(parent.tree.nodes_by_path[path.absolute(fixture:path("child"))].expanded)
      assert.are.same(parent:get_pos("child"), vim.api.nvim_win_get_cursor(winid))
      parent:destroy()
      instance:destroy()
    end
  end)

  it("passes expanded descendants as values when entering a directory", function()
    fixture:tree({ ["src/x/x/file.txt"] = "x" })
    local instance = wait_ready(fre.new({ root = fixture.root, columns = {} }))
    instance:expand("src")
    wait_for(function()
      local node = instance.tree.nodes_by_path[path.absolute(fixture:path("src"))]
      return node and node.loaded
    end)
    instance:expand("src/x")
    wait_for(function()
      local node = instance.tree.nodes_by_path[path.absolute(fixture:path("src/x"))]
      return node and node.loaded
    end)
    instance:expand("src/x/x")
    wait_for(function()
      local node = instance.tree.nodes_by_path[path.absolute(fixture:path("src/x/x"))]
      return node and node.loaded
    end)

    local child = wait_ready(actions.select(context_for(instance, "src"), {
      instance = { expanded = { "ignored" } },
    }))
    assert.is_nil(rawget(child.sync, "expanded"))
    wait_for(function()
      local first = child.tree.nodes_by_path[path.absolute(fixture:path("src/x"))]
      local second = child.tree.nodes_by_path[path.absolute(fixture:path("src/x/x"))]
      return first and first.expanded and second and second.expanded and second.loaded
    end)
    assert.are.equal(path.absolute(fixture:path("src")), child.root)
  end)

  it("copies child options, replaces action-owned paths, and calls public fre.new", function()
    local source_sort = function(_, left, right) return left.name < right.name end
    local override_sort = function(_, left, right) return left.name > right.name end
    local instance = ready({ ["dir/nested/file.txt"] = "x" }, {
      hidden_file = true,
      sort = source_sort,
    })
    instance:expand("dir")
    wait_for(function() return instance:get_pos("dir/nested") ~= nil end)
    instance:expand("dir/nested")
    local ctx = context_for(instance, "dir")
    local overrides = {
      root = "caller-owned-root",
      expanded = { "caller-owned-expanded" },
      hidden_file = false,
      sort = override_sort,
      gc = { ttl_ms = 321, include_modified = true, group = "project" },
      buffer = { variables = { ticket_10 = { nested = "caller" } } },
    }
    local before = vim.deepcopy(overrides)
    local original_new = fre.new
    local calls = {}
    fre.new = function(options)
      calls[#calls + 1] = options
      return original_new(options)
    end

    local ok, child = pcall(actions.select, ctx, { instance = overrides })
    fre.new = original_new
    assert.is_true(ok, tostring(child))
    local passed = assert(calls[1])

    assert.are.equal(1, #calls)
    assert.are_not.equal(overrides, passed)
    assert.are_not.equal(overrides.gc, passed.gc)
    assert.are_not.equal(overrides.buffer, passed.buffer)
    assert.are_not.equal(overrides.buffer.variables.ticket_10,
      passed.buffer.variables.ticket_10)
    assert.are.same(before, overrides)
    assert.are.equal(path.absolute(fixture:path("dir")), passed.root)
    assert.are.same({ "nested" }, passed.expanded)
    assert.is_false(passed.hidden_file)
    assert.are.equal(override_sort, passed.sort)
    assert.are.same(before.gc, passed.gc)
    assert.is_nil(passed.manager)
    assert.is_nil(passed.config)
    assert.is_nil(passed.metadata)
    assert.are.equal(child, fre.get_instance(child.bufnr))
    assert.are.equal(child, manager_module.default:find_by_group("project")[child.id])
    assert.are.same({
      instance_id = child.id,
      bufnr = child.bufnr,
      group = "project",
      ttl_ms = 321,
      include_modified = true,
      hidden = false,
      eligible = false,
    }, manager_module.default:get_gc_controller():inspect(child))
    assert.is_false(child:get_hidden_file())
    assert.are.equal(override_sort, child:get_sort())
  end)

  it("derives only current navigation behavior and resolves absent GC from current defaults", function()
    local source_sort = function(_, left, right) return left.name > right.name end
    fre.setup({
      default_file_explorer = false,
      columns = {},
      gc = {
        ttl_ms = 900, include_modified = true, default_group = "project",
        groups = { default = 0, project = 0 },
      },
    })
    local instance = ready({ ["dir/child.txt"] = "x" }, {
      hidden_file = false,
      sort = source_sort,
    })
    instance:set_hidden_file(true)
    local source_policy = manager_module.default:get_gc_controller():inspect(instance)
    assert.are.equal("project", source_policy.group)
    assert.are.equal(900, source_policy.ttl_ms)
    assert.is_true(source_policy.include_modified)

    fre.setup({
      default_file_explorer = false,
      columns = {},
      gc = {
        ttl_ms = 27, include_modified = false, default_group = "default",
        groups = { default = 0, project = 0 },
      },
    })
    local original_new = fre.new
    local passed
    fre.new = function(options)
      passed = options
      return original_new(options)
    end
    local ok, child = pcall(actions.select, context_for(instance, "dir"))
    fre.new = original_new
    assert.is_true(ok, tostring(child))

    assert.are.same({
      root = path.absolute(fixture:path("dir")),
      expanded = {},
      sort = source_sort,
      hidden_file = true,
    }, passed)
    assert.are.equal(source_sort, child:get_sort())
    assert.is_true(child:get_hidden_file())
    assert.are.same({
      instance_id = child.id,
      bufnr = child.bufnr,
      group = "default",
      ttl_ms = 27,
      include_modified = false,
      hidden = false,
      eligible = false,
    }, manager_module.default:get_gc_controller():inspect(child))
    assert.are.equal(child, manager_module.default:find_by_group("default")[child.id])
    assert.are.equal(instance, manager_module.default:find_by_group("project")[instance.id])
  end)

  it("destroys a public-new child through its normal lifecycle after precommit failure", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local ctx = context_for(instance, "dir")
    local original_new = fre.new
    local prepared
    local destroy_calls = 0
    fre.new = function(options)
      prepared = original_new(options)
      local destroy = prepared.destroy
      prepared.destroy = function(self)
        destroy_calls = destroy_calls + 1
        return destroy(self)
      end
      return prepared
    end

    local ok, err = pcall(actions.select, ctx, {
      instance = { window = { options = { fre_not_a_real_option = true } } },
    })
    fre.new = original_new

    assert.is_false(ok)
    assert.is_truthy(tostring(err))
    assert.are.equal(1, destroy_calls)
    assert.are.equal("destroyed", prepared:status())
    assert.is_nil(fre.get_instance_by_id(prepared.id))
    assert.is_nil(fre.get_instance(prepared.bufnr))
    assert.is_nil(manager_module.default:get_gc_controller():inspect(prepared))
  end)

  it("keeps a committed directory peer alive when the source is destroyed", function()
    local instance = ready({ ["dir/child.txt"] = "x" })
    local source_id = instance.id
    local child = wait_ready(actions.select(context_for(instance, "dir")))
    local child_win = vim.api.nvim_get_current_win()

    instance:destroy()

    assert.is_nil(fre.get_instance_by_id(source_id))
    assert.are.equal("ready", child:status())
    assert.are.equal(child, fre.get_instance_by_id(child.id))
    assert.are.equal(child, fre.get_instance(child.bufnr))
    assert.is_true(vim.api.nvim_win_is_valid(child_win))
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(child_win))
    assert.is_not_nil(fre.view.inspect(child, vim.api.nvim_get_current_tabpage()))
  end)

  it("creates directory children in the exact target and a new tab with explicit effective overrides", function()
    local sort_fn = function(_, a, b) return a.name > b.name end
    local instance = ready({ ["same/a.txt"] = "a", ["tab/b.txt"] = "b" }, {
      hidden_file = true,
    })
    local target = open_current(instance)
    local same_ctx = context_for(instance, "same")
    local overrides = {
      hidden_file = false,
      sort = sort_fn,
      mapping = { n = { x = function() end } },
      window = { options = { cursorline = true } },
    }
    local child = actions.select(same_ctx, { instance = overrides })
    overrides.hidden_file = true
    overrides.mapping.n.y = function() end
    assert.are.equal(path.absolute(fixture:path("same")), child.root)
    assert.are.equal(target, vim.fn.bufwinid(child.bufnr))
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(target))
    assert.is_true(vim.api.nvim_get_option_value("cursorline", { win = target }))
    assert.is_false(child.buffer:hidden_files())
    assert.are.equal(sort_fn, child.tree:get_comparator())
    assert.is_nil(rawget(child.buffer, "mapping"))
    assert.are.equal("ready", instance:status())
    wait_ready(child)

    instance:open({ position = "current" })
    local source_tab = vim.api.nvim_get_current_tabpage()
    local tab_ctx = context_for(instance, "tab")
    local tab_child = actions.tab_select(tab_ctx, { instance = { hidden_file = false } })
    local target_tab = vim.api.nvim_get_current_tabpage()
    local target_win = vim.api.nvim_get_current_win()
    assert.are_not.equal(source_tab, target_tab)
    assert.are.equal(tab_child.bufnr, vim.api.nvim_get_current_buf())
    assert.are.equal(path.absolute(fixture:path("tab")), tab_child.root)
    assert.is_false(tab_child.buffer:hidden_files())
    assert.is_true(#vim.fn.win_findbuf(instance.bufnr) > 0)
    assert.are.same({
      winid = target_win,
      origin_winid = target_win,
      layout = { position = "current" },
    }, fre.view.inspect(tab_child, target_tab))
    wait_ready(tab_child)
    local _, relaid = tab_child:open({ position = "right", size = 20 })
    assert.are.equal(target_tab, vim.api.nvim_win_get_tabpage(relaid))
    assert.are.equal(20, vim.api.nvim_win_get_width(relaid))
    assert.are.same({
      winid = relaid, origin_winid = target_win,
      layout = { position = "right", size = 20 },
    }, fre.view.inspect(tab_child, target_tab))
    local _, current = tab_child:open({ position = "current" })
    assert.are.equal(target_win, current)
    assert.are.same({
      winid = current, origin_winid = current, layout = { position = "current" },
    }, fre.view.inspect(tab_child, target_tab))
    tab_child:hidden(target_tab)
    assert.is_false(vim.api.nvim_tabpage_is_valid(target_tab))
    assert.is_true(vim.api.nvim_win_is_valid(tab_ctx.winid))
  end)

  it("creates directory children in all four exact split directions and leaves the source visible", function()
    fixture:tree({
      ["left/a"] = "a", ["right/a"] = "a", ["top/a"] = "a", ["bottom/a"] = "a",
    })
    local cases = {
      { name = "left", size = 24, axis = "width" },
      { name = "right", size = 25, axis = "width" },
      { name = "top", size = 8, axis = "height" },
      { name = "bottom", size = 9, axis = "height" },
    }
    for _, case in ipairs(cases) do
      pcall(vim.cmd, "silent! only")
      local instance = ready({}, { hidden_file = true })
      local source = open_current(instance)
      local ctx = context_for(instance, case.name)
      local child = actions.split_select(ctx, {
        layout = { position = case.name, size = case.size },
        instance = { hidden_file = false },
      })
      local child_win = vim.api.nvim_get_current_win()
      local source_tab = vim.api.nvim_get_current_tabpage()
      assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(child_win))
      assert.are.equal(path.absolute(fixture:path(case.name)), child.root)
      assert.is_false(child.buffer:hidden_files())
      assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source))
      assert.are.equal("ready", instance:status())
      assert.are.same({
        winid = child_win,
        origin_winid = source,
        layout = { position = case.name, size = case.size },
      }, fre.view.inspect(child, source_tab))
      if case.axis == "width" then
        assert.are.equal(case.size, vim.api.nvim_win_get_width(child_win))
      else
        assert.are.equal(case.size, vim.api.nvim_win_get_height(child_win))
      end
      local row, col = screenpos(child_win)
      if case.name == "left" then assert.are.equal(1, col) end
      if case.name == "right" then assert.is_true(col > 1) end
      if case.name == "top" then assert.are.equal(1, row) end
      if case.name == "bottom" then assert.is_true(row > 1) end
      wait_ready(child)
      child:hidden(source_tab)
      assert.is_false(vim.api.nvim_win_is_valid(child_win))
      assert.is_true(vim.api.nvim_win_is_valid(source))
      child:destroy()
      instance:destroy()
    end
  end)

  it("opens files in new tabs and every requested split without replacing the source", function()
    local instance = ready({ ["file.txt"] = "x" })
    local source = open_current(instance)
    local source_tab = vim.api.nvim_get_current_tabpage()
    local ctx = context_for(instance, "file.txt")
    local tab_buf = actions.tab_select(ctx)
    assert.are_not.equal(source_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(tab_buf, vim.api.nvim_get_current_buf())
    assert.are.equal(path.absolute(fixture:path("file.txt")), vim.api.nvim_buf_get_name(tab_buf))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source))

    vim.api.nvim_set_current_tabpage(source_tab)
    vim.api.nvim_set_current_win(source)
    for _, position_name in ipairs({ "left", "right", "top", "bottom" }) do
      pcall(vim.cmd, "silent! only")
      instance:open({ position = "current" })
      ctx = context_for(instance, "file.txt")
      local bufnr = actions.split_select(ctx, {
        layout = { position = position_name, size = (position_name == "left" or position_name == "right") and 20 or 7 },
      })
      assert.are.equal(bufnr, vim.api.nvim_get_current_buf())
      assert.is_true(#vim.fn.win_findbuf(instance.bufnr) > 0)
    end
  end)

  it("applies tab and split hide_source only to the captured source tab", function()
    fixture:tree({ ["file.txt"] = "x", ["dir/child.txt"] = "y" })
    local cases = {
      { action = "tab", entry = "file.txt", kind = "file" },
      { action = "tab", entry = "dir", kind = "directory" },
      { action = "split", entry = "file.txt", kind = "file" },
      { action = "split", entry = "dir", kind = "directory" },
    }
    for _, case in ipairs(cases) do
      pcall(vim.cmd, "silent! tabonly")
      pcall(vim.cmd, "silent! only")
      vim.cmd("enew")
      local instance = ready({})
      local source_win = open_current(instance)
      local source_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local other_tab = vim.api.nvim_get_current_tabpage()
      instance:open({ position = "current" })
      vim.api.nvim_set_current_tabpage(source_tab)
      vim.api.nvim_set_current_win(source_win)
      local ctx = context_for(instance, case.entry)
      local result
      if case.action == "tab" then
        result = actions.tab_select(ctx, { hide_source = true })
      else
        result = actions.split_select(ctx, {
          layout = { position = "right", size = 20 },
          hide_source = true,
        })
      end
      local target_tab = vim.api.nvim_get_current_tabpage()
      local target_win = vim.api.nvim_get_current_win()
      assert.is_nil(fre.view.inspect(instance, source_tab))
      assert.is_not_nil(fre.view.inspect(instance, other_tab))
      if case.kind == "file" then
        assert.are.equal(result, vim.api.nvim_win_get_buf(target_win))
        assert.is_nil(manager_module.default:find_by_buf(result))
      else
        assert.are.equal(result.bufnr, vim.api.nvim_win_get_buf(target_win))
        assert.is_not_nil(fre.view.inspect(result, target_tab))
      end
      if case.kind == "directory" then pcall(result.destroy, result) end
      pcall(instance.destroy, instance)
    end
  end)

  it("rejects invalid tab and split options and anchors without side effects", function()
    local instance = ready({ ["file.txt"] = "x" })
    local ctx = context_for(instance, "file.txt")
    local source_view = assert(fre.view.inspect(instance, ctx.tabpage))
    local float_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor", width = 8, height = 2, row = 0, col = 0,
    })
    vim.cmd("tabnew")
    local cross_tab_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_tabpage(ctx.tabpage)
    vim.api.nvim_set_current_win(ctx.winid)
    local stale_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor", width = 8, height = 2, row = 3, col = 0,
    })
    vim.api.nvim_win_close(stale_win, true)

    local before_count = instance_count()
    local before_tabs = vim.api.nvim_list_tabpages()
    local before_windows = window_buffers()
    local selected_path = path.absolute(fixture:path("file.txt"))
    assert.are.equal(-1, vim.fn.bufnr(selected_path))
    local invalid = {
      function() actions.tab_select(ctx, { hide_source = "yes" }) end,
      function() actions.split_select(ctx, {
        layout = { position = "right", size = 20 }, hide_source = "yes",
      }) end,
      function() actions.tab_select(ctx, { instance = {} }) end,
      function() actions.split_select(ctx, {
        layout = { position = "right", size = 20 }, instance = {},
      }) end,
      function() actions.split_select(ctx, { layout = { position = "current" } }) end,
      function() actions.split_select(ctx, {
        layout = { position = "right", size = 20 }, anchor_winid = float_win,
      }) end,
      function() actions.split_select(ctx, {
        layout = { position = "right", size = 20 }, anchor_winid = cross_tab_win,
      }) end,
      function() actions.split_select(ctx, {
        layout = { position = "right", size = 20 }, anchor_winid = stale_win,
      }) end,
    }
    for _, callback in ipairs(invalid) do
      assert.is_truthy(error_text(callback))
      assert.are.equal(before_count, instance_count())
      assert.are.same(before_tabs, vim.api.nvim_list_tabpages())
      assert.are.same(before_windows, window_buffers())
      assert.are.equal(-1, vim.fn.bufnr(selected_path))
      assert.are.same(source_view, fre.view.inspect(instance, ctx.tabpage))
    end
  end)

  it("requires an explicit ordinary anchor for float split file and directory selections", function()
    local instance = ready({ ["file.txt"] = "x", ["dir/child.txt"] = "y" })
    local _, float_win = instance:open({
      position = "float", width = 32, height = 10, row = 2, col = 4,
    })
    local source_tab = vim.api.nvim_get_current_tabpage()
    local source_view = assert(fre.view.inspect(instance, source_tab))
    local before_count = instance_count()
    local before_tabs = vim.api.nvim_list_tabpages()
    local before_windows = window_buffers()
    local selected_path = path.absolute(fixture:path("file.txt"))
    assert.are.equal(-1, vim.fn.bufnr(selected_path))

    for _, name in ipairs({ "file.txt", "dir" }) do
      vim.api.nvim_win_set_cursor(float_win, { row_for(instance, name), 0 })
      local ctx = actions.context()
      local err = error_text(function()
        actions.split_select(ctx, { layout = { position = "right", size = 20 } })
      end)
      assert.is_truthy(err:find("anchor_winid is required", 1, true))
      assert.are.equal(before_count, instance_count())
      assert.are.same(before_tabs, vim.api.nvim_list_tabpages())
      assert.are.same(before_windows, window_buffers())
      assert.are.same(source_view, fre.view.inspect(instance, source_tab))
      assert.are.equal(-1, vim.fn.bufnr(selected_path))
    end
  end)

  it("uses an explicit float origin as the exact split anchor for files and directories", function()
    fixture:tree({ ["file.txt"] = "x", ["dir/child.txt"] = "y" })
    for _, case in ipairs({
      { entry = "file.txt", kind = "file" },
      { entry = "dir", kind = "directory" },
    }) do
      pcall(vim.cmd, "silent! tabonly")
      pcall(vim.cmd, "silent! only")
      vim.cmd("enew")
      local instance = ready({})
      local origin = vim.api.nvim_get_current_win()
      local _, float_win = instance:open({
        position = "float", width = 32, height = 10, row = 2, col = 4,
      })
      local source_tab = vim.api.nvim_get_current_tabpage()
      vim.api.nvim_win_set_cursor(float_win, { row_for(instance, case.entry), 0 })
      local ctx = actions.context()
      local result = actions.split_select(ctx, {
        layout = { position = "right", size = 20 },
        anchor_winid = origin,
      })
      local target_win = vim.api.nvim_get_current_win()
      local _, origin_col = screenpos(origin)
      local _, target_col = screenpos(target_win)
      assert.is_true(target_col > origin_col)
      assert.is_true(vim.api.nvim_win_is_valid(float_win))
      assert.is_not_nil(fre.view.inspect(instance, source_tab))
      if case.kind == "file" then
        assert.are.equal(result, vim.api.nvim_win_get_buf(target_win))
        assert.is_nil(manager_module.default:find_by_buf(result))
        vim.api.nvim_win_close(target_win, true)
      else
        assert.are.same({
          winid = target_win,
          origin_winid = origin,
          layout = { position = "right", size = 20 },
        }, fre.view.inspect(result, source_tab))
        result:hidden(source_tab)
        assert.is_false(vim.api.nvim_win_is_valid(target_win))
      end
      pcall(instance.destroy, instance)
    end
  end)

  it("uses a real dynamic mapping to keep directories in a float and send files to its origin", function()
    local function dynamic_select(ctx)
      local inspected = fre.view.inspect(ctx.instance, ctx.tabpage)
      if not inspected then error("missing active View") end
      if inspected.layout.position == "float" and ctx.entry
          and (ctx.entry.kind == "file" or ctx.entry.kind == "symlink") then
        if not inspected.origin_winid
            or not vim.api.nvim_win_is_valid(inspected.origin_winid) then
          error("missing active View origin")
        end
        return actions.select(ctx, {
          target_winid = inspected.origin_winid,
          hide_source = true,
        })
      end
      return actions.select(ctx)
    end
    fre.setup({
      default_file_explorer = false,
      mapping = { n = { ["<CR>"] = dynamic_select } },
    })
    local instance = ready({ ["dir/file.txt"] = "x" })
    local origin = vim.api.nvim_get_current_win()
    local _, float_win = instance:open({
      position = "float", width = 32, height = 10, row = 2, col = 4,
    })
    vim.api.nvim_win_set_cursor(float_win, { row_for(instance, "dir"), 0 })

    local child = invoke(instance.bufnr, "n", "<CR>")
    wait_ready(child)
    assert.are.equal(float_win, vim.api.nvim_get_current_win())
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(float_win))
    assert.is_nil(fre.view.inspect(instance))
    assert.are.equal(float_win, assert(fre.view.inspect(child)).winid)

    vim.api.nvim_win_set_cursor(float_win, { row_for(child, "file.txt"), 0 })
    local selected = invoke(child.bufnr, "n", "<CR>")
    assert.are.equal(selected, vim.api.nvim_win_get_buf(origin))
    assert.are.equal(path.absolute(fixture:path("dir", "file.txt")),
      vim.api.nvim_buf_get_name(selected))
    assert.is_false(vim.api.nvim_win_is_valid(float_win))
    assert.is_nil(fre.view.inspect(child))
  end)

  it("cleans exact tab and split destinations after file install failures", function()
    local instance = ready({ ["created.txt"] = "new", ["existing.txt"] = "old" })
    local source_win = open_current(instance)
    local source_tab = vim.api.nvim_get_current_tabpage()
    local source_view = assert(fre.view.inspect(instance, source_tab))

    local function inject(ctx, callback, selected_path)
      local destination_win
      local set_buf = vim.api.nvim_win_set_buf
      vim.api.nvim_win_set_buf = function(winid, bufnr)
        set_buf(winid, bufnr)
        if path.equal(vim.api.nvim_buf_get_name(bufnr), selected_path) then
          destination_win = winid
          error("injected destination install failure")
        end
      end
      local ok, err = pcall(callback, ctx)
      vim.api.nvim_win_set_buf = set_buf
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("injected destination install failure", 1, true))
      assert.is_not_nil(destination_win)
      assert.is_false(vim.api.nvim_win_is_valid(destination_win))
      assert.is_true(vim.api.nvim_win_is_valid(source_win))
      assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source_win))
      assert.are.same(source_view, fre.view.inspect(instance, source_tab))
    end

    local created_path = path.absolute(fixture:path("created.txt"))
    assert.are.equal(-1, vim.fn.bufnr(created_path))
    local ctx = context_for(instance, "created.txt")
    local tabs_before = #vim.api.nvim_list_tabpages()
    inject(ctx, function(value) return actions.tab_select(value) end, created_path)
    assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
    assert.are.equal(-1, vim.fn.bufnr(created_path))

    ctx = context_for(instance, "created.txt")
    local windows_before = #vim.api.nvim_tabpage_list_wins(source_tab)
    inject(ctx, function(value)
      return actions.split_select(value, { layout = { position = "right", size = 20 } })
    end, created_path)
    assert.are.equal(windows_before, #vim.api.nvim_tabpage_list_wins(source_tab))
    assert.are.equal(-1, vim.fn.bufnr(created_path))

    local existing_path = path.absolute(fixture:path("existing.txt"))
    local existing_buf = vim.fn.bufadd(existing_path)
    vim.fn.bufload(existing_buf)
    ctx = context_for(instance, "existing.txt")
    inject(ctx, function(value) return actions.tab_select(value) end, existing_path)
    assert.is_true(vim.api.nvim_buf_is_valid(existing_buf))
    assert.is_true(vim.api.nvim_buf_is_loaded(existing_buf))
    assert.are.equal(existing_buf, vim.fn.bufnr(existing_path))
  end)

  it("restores file selection destinations after real BufWinEnter failures", function()
    local instance = ready({ ["created.txt"] = "new", ["existing.txt"] = "old", ["tail.txt"] = "tail" }, {
      window = { options = { number = true, cursorline = true } },
    })
    local function window_view(winid)
      return {
        cursor = vim.api.nvim_win_get_cursor(winid),
        view = vim.api.nvim_win_call(winid, vim.fn.winsaveview),
      }
    end
    local function inject_bufwinenter(target_win, selected_path, callback, mutate)
      local group = vim.api.nvim_create_augroup(
        "FreActionBufWinEnterInjected" .. tostring(instance.id), { clear = true })
      local raised = false
      vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(args)
          if not raised and vim.api.nvim_win_get_buf(target_win) == args.buf
              and path.equal(vim.api.nvim_buf_get_name(args.buf), selected_path) then
            raised = true
            mutate()
            error("injected action BufWinEnter failure")
          end
        end,
      })
      local ok, err = pcall(callback)
      vim.api.nvim_del_augroup_by_id(group)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("injected action BufWinEnter failure", 1, true))
      assert.is_true(raised)
    end

    local created_path = path.absolute(fixture:path("created.txt"))
    local created_ctx = context_for(instance, "created.txt")
    local source_win = created_ctx.winid
    vim.api.nvim_win_set_cursor(source_win, { row_for(instance, "tail.txt"), 0 })
    local source_tab = vim.api.nvim_get_current_tabpage()
    local source_view = window_view(source_win)
    local source_inspect = assert(fre.view.inspect(instance, source_tab))
    local source_state = instance:status()
    local source_number = vim.wo[source_win].number
    local source_cursorline = vim.wo[source_win].cursorline
    local before_windows = window_buffers()
    assert.are.equal(-1, vim.fn.bufnr(created_path))
    inject_bufwinenter(source_win, created_path, function()
      actions.select(created_ctx)
    end, function()
      vim.api.nvim_set_option_value("number", not source_number, { win = source_win })
      vim.api.nvim_set_option_value("cursorline", not source_cursorline, { win = source_win })
    end)
    assert.are.same(before_windows, window_buffers())
    assert.are.equal(source_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(source_win, vim.api.nvim_get_current_win())
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source_win))
    assert.are.same(source_view, window_view(source_win))
    assert.are.same(source_inspect, fre.view.inspect(instance, source_tab))
    assert.are.equal(source_number, vim.wo[source_win].number)
    assert.are.equal(source_cursorline, vim.wo[source_win].cursorline)
    assert.are.equal(source_state, instance:status())
    assert.are.equal(-1, vim.fn.bufnr(created_path))

    local existing_path = path.absolute(fixture:path("existing.txt"))
    local existing_buf = vim.fn.bufadd(existing_path)
    vim.fn.bufload(existing_buf)
    vim.cmd("tabnew")
    local target_tab = vim.api.nvim_get_current_tabpage()
    local target_win = vim.api.nvim_get_current_win()
    local unrelated_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { "zero", "one two", "three" })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = unrelated_buf })
    vim.api.nvim_win_set_buf(target_win, unrelated_buf)
    vim.api.nvim_win_set_cursor(target_win, { 2, 3 })
    vim.wo[target_win].number = false
    vim.wo[target_win].cursorline = false
    local target_view = window_view(target_win)
    vim.api.nvim_set_current_tabpage(source_tab)
    vim.api.nvim_set_current_win(source_win)
    local existing_ctx = context_for(instance, "existing.txt")
    source_view = window_view(source_win)
    source_state = instance:status()
    before_windows = window_buffers()
    inject_bufwinenter(target_win, existing_path, function()
      actions.select(existing_ctx, { target_winid = target_win })
    end, function()
      vim.api.nvim_set_option_value("number", true, { win = target_win })
      vim.api.nvim_set_option_value("cursorline", true, { win = target_win })
    end)
    assert.are.same(before_windows, window_buffers())
    assert.are.equal(source_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(source_win, vim.api.nvim_get_current_win())
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source_win))
    assert.are.same(source_view, window_view(source_win))
    assert.are.equal(source_state, instance:status())
    assert.is_true(vim.api.nvim_tabpage_is_valid(target_tab))
    assert.are.equal(unrelated_buf, vim.api.nvim_win_get_buf(target_win))
    assert.are.same(target_view, window_view(target_win))
    assert.are.equal("wipe", vim.api.nvim_get_option_value("bufhidden", { buf = unrelated_buf }))
    assert.is_false(vim.wo[target_win].number)
    assert.is_false(vim.wo[target_win].cursorline)
    assert.is_true(vim.api.nvim_buf_is_valid(existing_buf))
    assert.is_true(vim.api.nvim_buf_is_loaded(existing_buf))
    assert.are.equal(existing_buf, vim.fn.bufnr(existing_path))
  end)

  it("uses selected-buffer BufWinEnter as the tab and split precommit boundary", function()
    local cases = {
      { destination = "tab", entry = "file.txt", kind = "file" },
      { destination = "tab", entry = "dir", kind = "directory" },
      { destination = "split", entry = "file.txt", kind = "file" },
      { destination = "split", entry = "dir", kind = "directory" },
    }
    for index, case in ipairs(cases) do
      pcall(vim.cmd, "silent! tabonly")
      pcall(vim.cmd, "silent! only")
      vim.cmd("enew")
      fre._reset_fs_adapter()
      local instance = ready({ ["file.txt"] = "file", ["dir/child.txt"] = "child" })
      local source_win = open_current(instance)
      local source_tab = vim.api.nvim_get_current_tabpage()
      local source_view = assert(fre.view.inspect(instance, source_tab))
      local source_state = instance:status()
      vim.cmd("tabnew")
      local unrelated_tab = vim.api.nvim_get_current_tabpage()
      local unrelated_win = vim.api.nvim_get_current_win()
      local unrelated_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { "unrelated" })
      vim.api.nvim_win_set_buf(unrelated_win, unrelated_buf)
      vim.api.nvim_set_current_tabpage(source_tab)
      vim.api.nvim_set_current_win(source_win)
      local ctx = context_for(instance, case.entry)
      local source_cursor = vim.api.nvim_win_get_cursor(source_win)
      local source_saved_view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
      local selected_path = path.absolute(fixture:path(case.entry))
      local before_count = instance_count()
      local before_tabs = #vim.api.nvim_list_tabpages()
      local child
      local child_id
      local child_bufnr
      local manager = manager_module.default
      local original_register = manager.register
      if case.kind == "directory" then
        fre._set_fs_adapter({ load = function() end })
        manager.register = function(target, created, policy)
          local registered = original_register(target, created, policy)
          if created ~= instance and path.equal(created.root, selected_path) then
            child = created
            child_id = child.id
            child_bufnr = child.bufnr
          end
          return registered
        end
      else
        assert.are.equal(-1, vim.fn.bufnr(selected_path))
      end

      local raised = false
      local destination_win
      local group = vim.api.nvim_create_augroup(
        "FreActionCreatedBufWinEnter" .. tostring(instance.id) .. tostring(index), { clear = true })
      vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function(args)
          local selected = case.kind == "file"
            and path.equal(vim.api.nvim_buf_get_name(args.buf), selected_path)
            or (child ~= nil and args.buf == child.bufnr)
          if not raised and selected then
            raised = true
            destination_win = vim.api.nvim_get_current_win()
            error("injected created destination BufWinEnter failure")
          end
        end,
      })
      local ok, err
      if case.destination == "tab" then
        ok, err = pcall(actions.tab_select, ctx)
      else
        ok, err = pcall(actions.split_select, ctx, {
          layout = { position = "right", size = 20 },
        })
      end
      manager.register = original_register
      vim.api.nvim_del_augroup_by_id(group)

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find(
        "injected created destination BufWinEnter failure", 1, true))
      assert.is_true(raised)
      assert.is_not_nil(destination_win)
      assert.is_false(vim.api.nvim_win_is_valid(destination_win))
      assert.are.equal(before_tabs, #vim.api.nvim_list_tabpages())
      assert.are.equal(source_tab, vim.api.nvim_get_current_tabpage())
      assert.are.equal(source_win, vim.api.nvim_get_current_win())
      assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source_win))
      assert.are.same(source_cursor, vim.api.nvim_win_get_cursor(source_win))
      assert.are.same(source_saved_view, vim.api.nvim_win_call(source_win, vim.fn.winsaveview))
      assert.are.same(source_view, fre.view.inspect(instance, source_tab))
      assert.are.equal(source_state, instance:status())
      assert.is_true(vim.api.nvim_tabpage_is_valid(unrelated_tab))
      assert.is_true(vim.api.nvim_win_is_valid(unrelated_win))
      assert.are.equal(unrelated_buf, vim.api.nvim_win_get_buf(unrelated_win))
      assert.are.equal(before_count, instance_count())
      if case.kind == "file" then
        assert.are.equal(-1, vim.fn.bufnr(selected_path))
      else
        assert.are.equal("destroyed", child:status())
        assert.is_nil(manager_module.default:find_by_id(child_id))
        assert.is_nil(manager_module.default:find_by_buf(child_bufnr))
        assert.is_false(vim.api.nvim_buf_is_valid(child_bufnr))
      end
      instance:destroy()
    end
  end)

  it("suppresses destination placeholder tab events and selects into the exact new tab", function()
    local instance = ready({ ["file.txt"] = "file" })
    local caller_win = open_current(instance)
    local caller_tab = vim.api.nvim_get_current_tabpage()
    local ctx = context_for(instance, "file.txt")
    local source_view = assert(fre.view.inspect(instance, caller_tab))
    local source_cursor = vim.api.nvim_win_get_cursor(caller_win)
    local source_saved_view = vim.api.nvim_win_call(caller_win, vim.fn.winsaveview)
    local source_state = instance:status()
    vim.cmd("tabnew")
    local unrelated_tab = vim.api.nvim_get_current_tabpage()
    local unrelated_win = vim.api.nvim_get_current_win()
    local unrelated_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { "unrelated" })
    vim.api.nvim_win_set_buf(unrelated_win, unrelated_buf)
    vim.api.nvim_set_current_tabpage(caller_tab)
    vim.api.nvim_set_current_win(caller_win)
    local before_tabs = #vim.api.nvim_list_tabpages()
    local events = { TabNew = 0, TabNewEntered = 0 }
    local group = vim.api.nvim_create_augroup(
      "FreActionSuppressedTabEvents" .. tostring(instance.id), { clear = true })
    for _, event in ipairs({ "TabNew", "TabNewEntered" }) do
      vim.api.nvim_create_autocmd(event, {
        group = group,
        callback = function()
          events[event] = events[event] + 1
          error("injected placeholder " .. event .. " failure")
        end,
      })
    end

    local ok, selected = pcall(actions.tab_select, ctx)
    vim.api.nvim_del_augroup_by_id(group)

    assert.is_true(ok, tostring(selected))
    local destination_tab = vim.api.nvim_get_current_tabpage()
    local destination_win = vim.api.nvim_get_current_win()
    assert.are.equal(before_tabs + 1, #vim.api.nvim_list_tabpages())
    assert.are_not.equal(caller_tab, destination_tab)
    assert.are_not.equal(unrelated_tab, destination_tab)
    assert.are.equal(selected, vim.api.nvim_win_get_buf(destination_win))
    assert.are.equal(path.absolute(fixture:path("file.txt")), vim.api.nvim_buf_get_name(selected))
    assert.are.same({ TabNew = 0, TabNewEntered = 0 }, events)
    assert.is_true(vim.api.nvim_win_is_valid(caller_win))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(caller_win))
    assert.are.same(source_cursor, vim.api.nvim_win_get_cursor(caller_win))
    assert.are.same(source_saved_view, vim.api.nvim_win_call(caller_win, vim.fn.winsaveview))
    assert.are.same(source_view, fre.view.inspect(instance, caller_tab))
    assert.are.equal(source_state, instance:status())
    assert.is_true(vim.api.nvim_tabpage_is_valid(unrelated_tab))
    assert.is_true(vim.api.nvim_win_is_valid(unrelated_win))
    assert.are.equal(unrelated_buf, vim.api.nvim_win_get_buf(unrelated_win))
  end)

  it("rejects unknown, invalid instance, and non-split inputs before side effects", function()
    local instance = ready({ ["dir/a"] = "a", ["file.txt"] = "f" })
    local ctx = context_for(instance, "dir")
    local before_count = instance_count()
    local before_windows = window_buffers()
    local before_tabs = vim.api.nvim_list_tabpages()
    local invalid = {
      function() actions.tab_select(ctx, { instance = { inherit = instance } }) end,
      function() actions.select(ctx, { extra = true }) end,
      function() actions.tab_select(ctx, { instance = "bad" }) end,
      function() actions.select(ctx, { instance = { mapping = { n = { x = false } } } }) end,
      function() actions.split_select(ctx, { layout = { position = "current" } }) end,
      function() actions.split_select(ctx, { layout = { position = "float", width = 20, height = 5 } }) end,
      function() actions.split_select(ctx, { layout = { position = "left", size = 1000 } }) end,
    }
    for _, callback in ipairs(invalid) do
      assert.is_truthy(error_text(callback))
      assert.are.equal(before_count, instance_count())
      assert.are.same(before_windows, window_buffers())
      assert.are.same(before_tabs, vim.api.nvim_list_tabpages())
    end
  end)

  it("rolls back and destroys directory children when current, tab, or split display fails", function()
    local instance = ready({ ["dir/a"] = "a" })
    local source = open_current(instance)
    local ctx = context_for(instance, "dir")
    local bad = { window = { options = { fre_not_a_real_option = true } } }
    local before_count = instance_count()
    local before_tabs = #vim.api.nvim_list_tabpages()
    local before_wins = #vim.api.nvim_tabpage_list_wins(0)

    assert.is_truthy(error_text(function() actions.select(ctx, { instance = bad }) end))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source))
    assert.are.equal(before_count, instance_count())

    assert.is_truthy(error_text(function() actions.tab_select(ctx, { instance = bad }) end))
    assert.are.equal(before_tabs, #vim.api.nvim_list_tabpages())
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.are.equal(before_count, instance_count())

    assert.is_truthy(error_text(function()
      actions.split_select(ctx, {
        layout = { position = "right", size = 20 },
        instance = bad,
      })
    end))
    assert.are.equal(before_wins, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source))
    assert.are.equal(before_count, instance_count())
  end)

  it("uses public refresh forms and discards modified drafts without confirmation", function()
    local instance = ready({ ["a.txt"] = "a" })
    local ctx = context_for(instance, "a.txt")
    local calls = {}
    instance.refresh = function(_, ...)
      local values = { n = select("#", ...), ... }
      calls[#calls + 1] = values
    end
    local adapter = confirmation_adapter()
    actions._set_ui_adapter(adapter)

    vim.bo[instance.bufnr].modified = false
    actions.refresh(ctx)
    assert.are.equal(1, #calls)
    assert.are.equal(0, calls[1].n)

    vim.bo[instance.bufnr].modified = true
    actions.refresh(ctx)
    assert.are.equal(0, #adapter.decisions)
    assert.are.equal(2, #calls)
    assert.are.equal(1, calls[2].n)
    assert.are.same({ force = true }, calls[2][1])
  end)
end)
