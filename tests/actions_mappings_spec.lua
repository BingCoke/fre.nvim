local actions = require("fre.actions")
local buffer = require("fre.buffer")
local fre = require("fre")
local manager_module = require("fre.manager")
local path = require("fre.path")
local fs = require("tests.helpers.fs")

local fixture
local original_geometry

local function wait_for(predicate)
  assert.is_true(vim.wait(2500, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function()
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
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
      if instance.state ~= "destroyed" then pcall(instance.destroy, instance) end
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

  it("exports ordinary action functions without a registry protocol", function()
    local names = {
      "context", "expand", "collapse", "toggle_expand", "reveal",
      "open", "hidden", "toggle", "set_hidden_file", "toggle_hidden_file", "refresh",
      "select", "tab_select", "split_select", "confirm", "write", "destroy",
    }
    for _, name in ipairs(names) do assert.are.equal("function", type(actions[name]), name) end
    assert.is_nil(actions.registry)
    assert.is_nil(actions.dispatch)
    assert.is_nil(actions.descriptors)
  end)

  it("builds fresh exact normal and visual contexts and propagates malformed-row errors", function()
    local instance = ready({ ["alpha.txt"] = "a", ["beta.txt"] = "b" })
    local row = row_for(instance, "alpha.txt")
    local winid = open_current(instance)
    local decoded = buffer.decode(instance, row)
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

  it("installs the exact default normal map base with no h, l, insert, or visual defaults", function()
    local instance = ready({ ["a.txt"] = "a" })
    local normal = keymaps(instance.bufnr, "n")
    local actual = {}
    for lhs in pairs(normal) do actual[#actual + 1] = lhs end
    table.sort(actual)
    assert.are.same({ "<CR>", "R", "g.", "q", "za", "zc", "zv" }, actual)
    assert.is_nil(normal.h)
    assert.is_nil(normal.l)
    assert.are.same({}, keymaps(instance.bufnr, "i"))
    assert.are.same({}, keymaps(instance.bufnr, "v"))
    assert.is_nil(instance.config.mapping.n)
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
    assert.are.equal(new_x, instance.config.mapping.n.x)
    assert.are.equal(setup_x, instance.config.mapping.n.y)
    assert.is_nil(instance.config.mapping.n["<CR>"])

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
    local ctx = {
      instance = fake, bufnr = fake.bufnr,
      entry = { absolute_path = "snapshot/path", kind = "directory" },
    }
    actions.expand(ctx)
    actions.collapse(ctx)
    actions.toggle_expand(ctx)
    actions.reveal(ctx)
    actions.open(ctx, { layout = { position = "current" } })
    actions.hidden(ctx)
    actions.toggle(ctx, { layout = { position = "left", size = 10 } })
    actions.set_hidden_file(ctx, { hidden_file = true })
    actions.toggle_hidden_file(ctx)
    actions.destroy(ctx)
    assert.are.same({
      { "expand", "snapshot/path" }, { "collapse", "snapshot/path" },
      { "toggle_expand", "snapshot/path" }, { "reveal", "snapshot/path" },
      { "open", { position = "current" } }, { "hidden" },
      { "toggle", { position = "left", size = 10 } },
      { "set_hidden_file", true }, { "toggle_hidden_file" }, { "destroy" },
    }, calls)
  end)

  it("opens file and symlink snapshot paths and hides a final replaced source view", function()
    local target = fixture:write("target.txt", "target")
    local link = fixture:symlink(target, "target-link")
    local instance = ready({ ["other.txt"] = "other" })
    local ctx = context_for(instance, "target.txt")
    local row = ctx.row
    local line = vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1]
    set_line(instance, row, line:gsub("target%.txt$", "edited-destination.txt"))
    local bufnr = actions.select(actions.context())
    assert.are.equal(path.absolute(target), vim.api.nvim_buf_get_name(bufnr))
    assert.are.equal(bufnr, vim.api.nvim_win_get_buf(ctx.winid))
    assert.are.equal("ready-hidden", instance.state)

    if link then
      local linked = ready({})
      local link_ctx = context_for(linked, "target-link")
      assert.are.equal("symlink", link_ctx.entry.kind)
      local link_buf = actions.select(link_ctx)
      assert.are.equal(path.absolute(target), vim.api.nvim_buf_get_name(link_buf))
      assert.are.equal(instance_count(), 2)
      assert.are.equal(link_buf, vim.api.nvim_win_get_buf(link_ctx.winid))
    end
  end)

  it("uses explicit same-tab and cross-tab targets and rejects invalid targets and nil entries", function()
    local instance = ready({ ["file.txt"] = "x", ["dir/child.txt"] = "y" })
    local source_win = open_current(instance)
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()
    vim.cmd("enew")
    vim.api.nvim_set_current_win(source_win)
    local ctx = context_for(instance, "file.txt")
    actions.select(ctx, { target_winid = target })
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source_win))
    assert.are.equal(path.absolute(fixture:path("file.txt")),
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target)))
    assert.are.equal("ready-visible", instance.state)

    vim.cmd("tabnew")
    local cross_target = vim.api.nvim_get_current_win()
    local cross_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("enew")
    vim.api.nvim_set_current_win(source_win)
    ctx = context_for(instance, "file.txt")
    actions.select(ctx, { target_winid = cross_target })
    assert.are.equal(cross_tab, vim.api.nvim_win_get_tabpage(cross_target))
    assert.are.equal(path.absolute(fixture:path("file.txt")),
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(cross_target)))
    local cross_child = actions.select(context_for(instance, "dir"), {
      target_winid = cross_target,
    })
    assert.are.equal(cross_child.bufnr, vim.api.nvim_win_get_buf(cross_target))
    assert.are.equal(path.absolute(fixture:path("dir")), cross_child.root)

    local stale = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = "editor", width = 5, height = 2, row = 0, col = 0,
    })
    vim.api.nvim_win_close(stale, true)
    local before_count = instance_count()
    local before_buffers = window_buffers()
    local dir_ctx = context_for(instance, "dir")
    assert.is_truthy(error_text(function()
      actions.select(dir_ctx, { target_winid = stale })
    end):find("target window", 1, true))
    assert.are.equal(before_count, instance_count())
    assert.are.same(before_buffers, window_buffers())
    dir_ctx.entry = nil
    assert.is_truthy(error_text(function() actions.select(dir_ctx) end):find("requires an entry", 1, true))
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

    local parent = wait_ready(actions.select(ctx))
    local previous_root = parent.nodes_by_path[path.absolute(fixture:path("child"))]
    assert.is_not_nil(previous_root)
    assert.is_false(previous_root.expanded)
    assert.is_nil(parent:get_pos("child/nested"))
    assert.are.same(parent:get_pos("child"), vim.api.nvim_win_get_cursor(winid))
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
    assert.is_false(child.current_hidden_file)
    assert.are.equal(sort_fn, child.current_sort)
    assert.is_nil(child.config.mapping.n.y)
    assert.are.equal("ready-hidden", instance.state)
    wait_ready(child)

    instance:open({ position = "current" })
    local source_tab = vim.api.nvim_get_current_tabpage()
    local tab_ctx = context_for(instance, "tab")
    local tab_child = actions.tab_select(tab_ctx, { instance = { hidden_file = false } })
    assert.are_not.equal(source_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(tab_child.bufnr, vim.api.nvim_get_current_buf())
    assert.are.equal(path.absolute(fixture:path("tab")), tab_child.root)
    assert.is_false(tab_child.current_hidden_file)
    assert.is_true(#vim.fn.win_findbuf(instance.bufnr) > 0)
    wait_ready(tab_child)
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
      assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(child_win))
      assert.are.equal(path.absolute(fixture:path(case.name)), child.root)
      assert.is_false(child.current_hidden_file)
      assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(source))
      assert.are.equal("ready-visible", instance.state)
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

  it("rolls back file tab set-buffer failures and cleans only action-created buffers", function()
    local instance = ready({ ["created.txt"] = "new", ["existing.txt"] = "old" })
    local caller_win = open_current(instance)
    vim.cmd("vsplit")
    local unrelated_win = vim.api.nvim_get_current_win()
    local unrelated_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(unrelated_win, unrelated_buf)
    vim.api.nvim_set_current_win(caller_win)

    local caller_tab = vim.api.nvim_get_current_tabpage()
    local caller_buf = vim.api.nvim_get_current_buf()
    local function snapshot()
      return {
        tabs = vim.api.nvim_list_tabpages(),
        windows = window_buffers(),
        layout = vim.fn.winlayout(),
      }
    end
    local function inject_set_buf_failure(ctx)
      local set_buf = vim.api.nvim_win_set_buf
      vim.api.nvim_win_set_buf = function(winid, bufnr)
        set_buf(winid, bufnr)
        error("injected tab set_buf failure")
      end
      local ok, err = pcall(actions.tab_select, ctx)
      vim.api.nvim_win_set_buf = set_buf
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("injected tab set_buf failure", 1, true))
    end
    local function assert_restored(before)
      assert.are.same(before.tabs, vim.api.nvim_list_tabpages())
      assert.are.same(before.windows, window_buffers())
      assert.are.same(before.layout, vim.fn.winlayout())
      assert.are.equal(caller_tab, vim.api.nvim_get_current_tabpage())
      assert.are.equal(caller_win, vim.api.nvim_get_current_win())
      assert.are.equal(caller_buf, vim.api.nvim_get_current_buf())
      assert.are.equal(caller_buf, vim.api.nvim_win_get_buf(caller_win))
      assert.is_true(vim.api.nvim_win_is_valid(unrelated_win))
      assert.are.equal(unrelated_buf, vim.api.nvim_win_get_buf(unrelated_win))
    end

    local created_path = path.absolute(fixture:path("created.txt"))
    assert.are.equal(-1, vim.fn.bufnr(created_path))
    local created_ctx = context_for(instance, "created.txt")
    local before = snapshot()
    inject_set_buf_failure(created_ctx)
    assert_restored(before)
    assert.are.equal(-1, vim.fn.bufnr(created_path))

    local existing_path = path.absolute(fixture:path("existing.txt"))
    local existing_buf = vim.fn.bufadd(existing_path)
    vim.fn.bufload(existing_buf)
    assert.is_true(vim.api.nvim_buf_is_valid(existing_buf))
    local existing_ctx = context_for(instance, "existing.txt")
    before = snapshot()
    inject_set_buf_failure(existing_ctx)
    assert_restored(before)
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
    local source_metadata = vim.api.nvim_win_get_var(source_win, "fre_layout_" .. instance.id)
    local source_state = instance.state
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
    assert.are.same(source_metadata,
      vim.api.nvim_win_get_var(source_win, "fre_layout_" .. instance.id))
    assert.are.equal(source_number, vim.wo[source_win].number)
    assert.are.equal(source_cursorline, vim.wo[source_win].cursorline)
    assert.are.equal(source_state, instance.state)
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
    local stale_metadata = { layout = { position = "current" }, effective = { position = "current" } }
    vim.api.nvim_win_set_var(target_win, "fre_layout_" .. instance.id, stale_metadata)
    local target_view = window_view(target_win)
    vim.api.nvim_set_current_tabpage(source_tab)
    vim.api.nvim_set_current_win(source_win)
    local existing_ctx = context_for(instance, "existing.txt")
    source_view = window_view(source_win)
    source_state = instance.state
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
    assert.are.equal(source_state, instance.state)
    assert.is_true(vim.api.nvim_tabpage_is_valid(target_tab))
    assert.are.equal(unrelated_buf, vim.api.nvim_win_get_buf(target_win))
    assert.are.same(target_view, window_view(target_win))
    assert.are.equal("wipe", vim.api.nvim_get_option_value("bufhidden", { buf = unrelated_buf }))
    assert.is_false(vim.wo[target_win].number)
    assert.is_false(vim.wo[target_win].cursorline)
    assert.are.same(stale_metadata,
      vim.api.nvim_win_get_var(target_win, "fre_layout_" .. instance.id))
    assert.is_true(vim.api.nvim_buf_is_valid(existing_buf))
    assert.is_true(vim.api.nvim_buf_is_loaded(existing_buf))
    assert.are.equal(existing_buf, vim.fn.bufnr(existing_path))
  end)

  it("removes tabs created before real TabNewEntered failures without leaks", function()
    local instance = ready({ ["file.txt"] = "file", ["dir/child.txt"] = "child" })
    local caller_win = open_current(instance)
    local caller_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local unrelated_tab = vim.api.nvim_get_current_tabpage()
    local unrelated_win = vim.api.nvim_get_current_win()
    local unrelated_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(unrelated_win, unrelated_buf)
    vim.api.nvim_set_current_tabpage(caller_tab)
    vim.api.nvim_set_current_win(caller_win)

    local function snapshot()
      return {
        tabs = vim.api.nvim_list_tabpages(),
        windows = window_buffers(),
        buffers = vim.api.nvim_list_bufs(),
        view = vim.api.nvim_win_call(caller_win, vim.fn.winsaveview),
        cursor = vim.api.nvim_win_get_cursor(caller_win),
        state = instance.state,
        instances = instance_count(),
      }
    end
    local cases = {
      { name = "file.txt", kind = "file" },
      { name = "dir", kind = "directory" },
    }
    for index, case in ipairs(cases) do
      local ctx = context_for(instance, case.name)
      local selected_path = path.absolute(fixture:path(case.name))
      local before = snapshot()
      local transient
      local group = vim.api.nvim_create_augroup(
        "FreActionTabNewInjected" .. tostring(instance.id) .. tostring(index), { clear = true })
      vim.api.nvim_create_autocmd("TabNewEntered", {
        group = group,
        once = true,
        callback = function()
          transient = vim.api.nvim_get_current_tabpage()
          vim.api.nvim_set_current_tabpage(unrelated_tab)
          error("injected action TabNewEntered failure")
        end,
      })
      local ok, err = pcall(actions.tab_select, ctx)
      vim.api.nvim_del_augroup_by_id(group)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("injected action TabNewEntered failure", 1, true))
      assert.is_truthy(transient)
      assert.is_false(vim.api.nvim_tabpage_is_valid(transient))
      assert.are.same(before.tabs, vim.api.nvim_list_tabpages())
      assert.are.same(before.windows, window_buffers())
      assert.are.same(before.buffers, vim.api.nvim_list_bufs())
      assert.are.equal(before.instances, instance_count())
      assert.are.equal(before.state, instance.state)
      assert.are.equal(caller_tab, vim.api.nvim_get_current_tabpage())
      assert.are.equal(caller_win, vim.api.nvim_get_current_win())
      assert.are.equal(instance.bufnr, vim.api.nvim_get_current_buf())
      assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(caller_win))
      assert.are.same(before.view, vim.api.nvim_win_call(caller_win, vim.fn.winsaveview))
      assert.are.same(before.cursor, vim.api.nvim_win_get_cursor(caller_win))
      assert.is_true(vim.api.nvim_tabpage_is_valid(unrelated_tab))
      assert.is_true(vim.api.nvim_win_is_valid(unrelated_win))
      assert.are.equal(unrelated_buf, vim.api.nvim_win_get_buf(unrelated_win))
      if case.kind == "file" then assert.are.equal(-1, vim.fn.bufnr(selected_path)) end
    end
  end)

  it("rejects action-owned, unknown, invalid instance, and non-split inputs before side effects", function()
    local instance = ready({ ["dir/a"] = "a", ["file.txt"] = "f" })
    local ctx = context_for(instance, "dir")
    local before_count = instance_count()
    local before_windows = window_buffers()
    local before_tabs = vim.api.nvim_list_tabpages()
    local invalid = {
      function() actions.select(ctx, { instance = { root = "other" } }) end,
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

  it("uses public refresh forms and confirms modified drafts exactly once", function()
    local instance = ready({ ["a.txt"] = "a" })
    local ctx = context_for(instance, "a.txt")
    local calls = {}
    instance.refresh = function(_, ...)
      local values = { n = select("#", ...), ... }
      calls[#calls + 1] = values
    end

    vim.bo[instance.bufnr].modified = false
    actions.refresh(ctx)
    assert.are.equal(1, #calls)
    assert.are.equal(0, calls[1].n)

    local adapter = confirmation_adapter()
    actions._set_ui_adapter(adapter)
    local draft = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    local baseline = vim.deepcopy(instance.view.baseline)
    vim.bo[instance.bufnr].modified = true
    actions.refresh(ctx)
    assert.are.equal(1, #adapter.decisions)
    assert.are.equal(1, #calls)
    adapter.decisions[1](false)
    adapter.decisions[1](true)
    assert.are.equal(1, #calls)
    assert.are.same(draft, vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false))
    assert.are.same(baseline, instance.view.baseline)
    assert.is_true(vim.bo[instance.bufnr].modified)

    actions.refresh(ctx)
    assert.are.equal(2, #adapter.decisions)
    adapter.decisions[2](true)
    adapter.decisions[2](true)
    assert.are.equal(2, #calls)
    assert.are.equal(1, calls[2].n)
    assert.are.same({ force = true }, calls[2][1])
  end)
end)
