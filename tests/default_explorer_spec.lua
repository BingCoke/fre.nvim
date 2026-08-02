local actions = require("fre.actions")
local fre = require("fre")
local manager_module = require("fre.manager")
local path = require("fre.path")
local takeover_module = require("fre.takeover")
local fs = require("tests.helpers.fs")

local fixture
local controller
local manager
local original_controller
local original_resolve_instance_config
local cleanup_after_test = false

local function wait_for(predicate)
  assert.is_true(vim.wait(2000, predicate, 10))
end

local function error_text(callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  return tostring(err)
end

local function instance_count(target)
  local count = 0
  for _ in pairs(target.instances_by_id) do count = count + 1 end
  return count
end

local function gc_timer_adapter()
  local state = { handles = {}, stopped = 0, closed = 0 }
  local adapter = {
    now = function() return 0 end,
    new_timer = function()
      local handle = {}
      state.handles[#state.handles + 1] = handle
      return handle
    end,
    timer_start = function(handle, _, callback)
      handle.callback = callback
      return true
    end,
    timer_stop = function(handle)
      if not handle.stopped then
        handle.stopped = true
        state.stopped = state.stopped + 1
      end
    end,
    close = function(handle)
      if not handle.closed then
        handle.closed = true
        state.closed = state.closed + 1
      end
    end,
    schedule = vim.schedule,
  }
  return adapter, state
end

local function autocmds()
  return vim.api.nvim_get_autocmds({
    group = takeover_module.augroup_name,
    event = "BufEnter",
  })
end

local function goto_window(winid)
  vim.cmd("noautocmd call win_gotoid(" .. tostring(winid) .. ")")
end

local function show(bufnr, winid)
  if winid then goto_window(winid) end
  vim.cmd("noautocmd buffer " .. tostring(bufnr))
  return vim.api.nvim_get_current_win()
end

local function source_buffer(name, winid)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, name)
  show(bufnr, winid)
  return bufnr, vim.api.nvim_get_current_win()
end

local function manager_instances()
  local result = {}
  for _, instance in pairs(manager.instances_by_id) do result[#result + 1] = instance end
  return result
end

local function reset_editor()
  pcall(vim.cmd, "noautocmd silent! tabonly!")
  pcall(vim.cmd, "noautocmd silent! only!")
  pcall(vim.cmd, "noautocmd silent! enew!")
  for _, instance in ipairs(manager_instances()) do
    if instance:status() ~= "destroyed" then pcall(instance.destroy, instance) end
  end
  local current = vim.api.nvim_get_current_buf()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if bufnr ~= current and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

describe("fre ticket 20 default directory explorer", function()
  fixture = fs.new()
  fixture:tree({
    ["root.txt"] = "root",
    ["one/a.txt"] = "a",
    ["two/b.txt"] = "b",
    ["three/c.txt"] = "c",
    ["ordinary.txt"] = "file",
  })
  manager = manager_module.default
  controller = assert(manager._takeover)
  original_controller = {
    create_instance = controller._create_instance,
    replace_window = controller._replace_window,
    delete_source = controller._delete_source,
  }
  original_resolve_instance_config = manager.resolve_instance_config

  after_each(function()
    controller._create_instance = original_controller.create_instance
    controller._replace_window = original_controller.replace_window
    controller._delete_source = original_controller.delete_source
    manager.resolve_instance_config = original_resolve_instance_config
    fre._reset_fs_adapter()
    reset_editor()
    fre._reset_gc_adapter()
    fre.setup({})
    if cleanup_after_test then
      pcall(vim.api.nvim_del_augroup_by_name, "FileExplorer")
      fixture:cleanup()
    end
  end)

  it("commits true once, clears netrw, installs one autocmd, and immediately takes over the current directory", function()
    assert.is_nil(manager:get_default_file_explorer())
    assert.is_false(controller._enabled)
    assert.is_nil(vim.g.loaded_netrw)
    assert.is_nil(vim.g.loaded_netrwPlugin)
    local takeover_group_exists = pcall(autocmds)
    assert.is_false(takeover_group_exists)
    reset_editor()
    local netrw_runs = 0
    local file_explorer = vim.api.nvim_create_augroup("FileExplorer", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = file_explorer,
      callback = function() netrw_runs = netrw_runs + 1 end,
    })

    local source = source_buffer(fixture.root)
    netrw_runs = 0
    local invalid = error_text(function()
      fre.setup({ default_file_explorer = false, hidden_file = "invalid" })
    end)
    assert.is_truthy(invalid:find("hidden_file must be a boolean", 1, true))
    assert.is_nil(manager:get_default_file_explorer())
    assert.are.equal(source, vim.api.nvim_get_current_buf())
    assert.is_nil(vim.g.loaded_netrw)
    assert.is_nil(vim.g.loaded_netrwPlugin)
    assert.are.equal(1, #vim.api.nvim_get_autocmds({ group = "FileExplorer" }))
    takeover_group_exists = pcall(autocmds)
    assert.is_false(takeover_group_exists)
    fre.setup({
      default_file_explorer = true,
      hidden_file = true,
      columns = {},
      window = { options = { cursorline = true } },
    })

    assert.are.equal(1, vim.g.loaded_netrw)
    assert.are.equal(1, vim.g.loaded_netrwPlugin)
    assert.are.equal(0, netrw_runs)
    assert.are.same({}, vim.api.nvim_get_autocmds({ group = "FileExplorer" }))
    local installed = autocmds()
    assert.are.equal(1, #installed)

    local child = assert(fre.get_instance())
    assert.are.equal(path.absolute(fixture.root), child.root)
    assert.is_true(child.buffer:hidden_files())
    assert.is_true(vim.wo.cursorline)
    assert.is_false(vim.api.nvim_buf_is_valid(source))
    wait_for(function()
      return child:status() == "ready" or child:status() == "load-failed"
    end)
    assert.are.equal("ready", child:status(), tostring(child:failure()))

    local later_source = source_buffer(fixture:path("one"))
    fre.setup({ default_file_explorer = false, columns = {} })
    assert.are.equal(later_source, vim.api.nvim_get_current_buf())
    assert.is_nil(fre.get_instance())
    assert.is_true(manager:get_default_file_explorer())
    assert.are.equal(installed[1].id, autocmds()[1].id)
    assert.are.equal(1, #autocmds())

    local before = instance_count(manager)
    local err = error_text(function()
      fre.new({ root = fixture.root, default_file_explorer = false })
    end)
    assert.is_truthy(err:find("default_file_explorer is setup%-only"))
    assert.are.equal(before, instance_count(manager))
  end)

  it("resolves the exact takeover View when native jump-back returns to it", function()
    reset_editor()
    local source, winid = source_buffer(fixture.root)
    fre.setup({
      default_file_explorer = true,
      columns = {},
      gc = { ttl_ms = 60000 },
    })
    local instance = fre.get_instance()
    if not instance then instance = assert(controller:check(source, winid)) end
    wait_for(function() return instance:status() == "ready" end)

    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    vim.cmd("normal! G")
    local target_row
    for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
      local entry = instance:get_entry(row)
      if entry and entry.name == "root.txt" then target_row = row; break end
    end
    assert.is_not_nil(target_row)
    vim.api.nvim_win_set_cursor(winid, { target_row, 0 })
    local selected = actions.select(actions.context())

    assert.are.equal(selected, vim.api.nvim_get_current_buf())
    assert.is_nil(fre.view.inspect(instance))
    assert.are.equal(instance, fre.get_instance_by_id(instance.id))

    vim.cmd("normal! \15")

    assert.are.equal(instance.bufnr, vim.api.nvim_get_current_buf())
    assert.are.same({
      winid = winid,
      origin_winid = winid,
      layout = { position = "current" },
    }, fre.view.inspect(instance))
    assert.are.same(fre.view.inspect(instance), actions.context().view)
    vim.api.nvim_feedkeys(string.char(9), "nx", false)
    assert.are.equal(selected, vim.api.nvim_get_current_buf())
    vim.cmd("normal! " .. string.char(15))
    assert.are.equal(instance.bufnr, vim.api.nvim_get_current_buf())
    assert.are.same(fre.view.inspect(instance), actions.context().view)
  end)

  it("resolves the parent View when native jump-back returns to its Instance", function()
    reset_editor()
    local source, winid = source_buffer(fixture.root)
    fre.setup({
      default_file_explorer = true,
      columns = {},
      gc = { ttl_ms = 60000 },
    })
    local parent = fre.get_instance()
    if not parent then parent = assert(controller:check(source, winid)) end
    wait_for(function() return parent:status() == "ready" end)

    vim.cmd("normal! G")
    local directory_row
    for row = 1, vim.api.nvim_buf_line_count(parent.bufnr) do
      local entry = parent:get_entry(row)
      if entry and entry.name == "one" then directory_row = row; break end
    end
    assert.is_not_nil(directory_row)
    vim.api.nvim_win_set_cursor(winid, { directory_row, 0 })
    local child = actions.select(actions.context())
    wait_for(function() return child:status() == "ready" end)

    assert.are.equal(child.bufnr, vim.api.nvim_get_current_buf())
    assert.is_nil(fre.view.inspect(parent))
    assert.are.equal(winid, assert(fre.view.inspect(child)).winid)

    vim.cmd("normal! \15")

    assert.are.equal(parent.bufnr, vim.api.nvim_get_current_buf())
    assert.are.same({
      winid = winid,
      origin_winid = winid,
      layout = { position = "current" },
    }, fre.view.inspect(parent))
    assert.is_nil(fre.view.inspect(child))
    assert.are.same(fre.view.inspect(parent), actions.context().view)
    vim.api.nvim_feedkeys(string.char(9), "nx", false)
    assert.are.equal(child.bufnr, vim.api.nvim_get_current_buf())
    assert.is_nil(fre.view.inspect(parent))
    assert.are.same(fre.view.inspect(child), actions.context().view)
    vim.cmd("normal! " .. string.char(15))
    assert.are.equal(parent.bufnr, vim.api.nvim_get_current_buf())
    assert.are.same(fre.view.inspect(parent), actions.context().view)
  end)


  it("ignores invalid, unnamed, reserved, Manager-owned, URI, file, and mismatched targets", function()
    reset_editor()
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_get_current_buf()
    local before = instance_count(manager)

    assert.is_nil(controller:check(-1, current_win))
    assert.is_nil(controller:check(current_buf, -1))
    assert.is_nil(controller:check(current_buf, current_win))

    local mismatch = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(mismatch, fixture:path("three"))
    assert.is_nil(controller:check(mismatch, current_win))

    local reserved = source_buffer(fixture:path("one"))
    vim.api.nvim_buf_set_var(reserved, "fre", { reserved = true })
    assert.is_nil(controller:check(reserved, current_win))
    assert.are.equal(reserved, vim.api.nvim_get_current_buf())

    local uri = source_buffer("oil:///tmp/fre-ticket-20")
    assert.is_nil(controller:check(uri, current_win))
    assert.are.equal(uri, vim.api.nvim_get_current_buf())

    local file = source_buffer(fixture:path("ordinary.txt"))
    assert.is_nil(controller:check(file, current_win))
    assert.are.equal(file, vim.api.nvim_get_current_buf())

    local owned = fre.new({ root = fixture.root, columns = {} })
    show(owned.bufnr)
    vim.api.nvim_buf_del_var(owned.bufnr, "fre")
    assert.is_nil(controller:check(owned.bufnr, current_win))
    assert.are.equal(owned.bufnr, vim.api.nvim_get_current_buf())

    local closed_win
    vim.cmd("noautocmd split")
    closed_win = vim.api.nvim_get_current_win()
    vim.cmd("noautocmd close")
    assert.is_nil(controller:check(file, closed_win))
    assert.are.equal(before + 1, instance_count(manager))
  end)

  it("rejects a modified directory exactly and always clears the reentrancy guard", function()
    reset_editor()
    local source, winid = source_buffer(fixture:path("one"))
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved exact text", "line two" })
    vim.bo[source].modified = true
    vim.wo[winid].number = true
    vim.api.nvim_win_set_cursor(winid, { 2, 3 })
    local before = {
      text = vim.api.nvim_buf_get_lines(source, 0, -1, false),
      modified = vim.bo[source].modified,
      current_win = vim.api.nvim_get_current_win(),
      current_buf = vim.api.nvim_get_current_buf(),
      windows = vim.api.nvim_tabpage_list_wins(0),
      layout = vim.fn.winlayout(),
      view = vim.api.nvim_win_call(winid, vim.fn.winsaveview),
      number = vim.wo[winid].number,
      instances = instance_count(manager),
    }

    assert.are.equal("fre: cannot take over a modified directory buffer",
      error_text(function() controller:check(source, winid) end))
    assert.are.same(before.text, vim.api.nvim_buf_get_lines(source, 0, -1, false))
    assert.are.equal(before.modified, vim.bo[source].modified)
    assert.are.equal(before.current_win, vim.api.nvim_get_current_win())
    assert.are.equal(before.current_buf, vim.api.nvim_get_current_buf())
    assert.are.same(before.windows, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before.layout, vim.fn.winlayout())
    assert.are.same(before.view, vim.api.nvim_win_call(winid, vim.fn.winsaveview))
    assert.are.equal(before.number, vim.wo[winid].number)
    assert.are.equal(before.instances, instance_count(manager))
    assert.is_nil(controller._checking[source])
    assert.are.equal("fre: cannot take over a modified directory buffer",
      error_text(function() controller:check(source, winid) end))
  end)

  it("suppresses recursive source checks and constructs only one child", function()
    reset_editor()
    local source, winid = source_buffer(fixture:path("one"))
    local calls = 0
    controller._create_instance = function(target, root)
      calls = calls + 1
      assert.is_nil(controller:check(source, winid))
      return original_controller.create_instance(target, root)
    end

    local child = assert(controller:check(source, winid))
    assert.are.equal(1, calls)
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(winid))
    assert.are.equal(child, manager:find_by_buf(child.bufnr))
    assert.is_nil(controller._checking[source])
  end)

  it("creates distinct children per entered window and deletes the source only after its final view", function()
    reset_editor()
    local source, first_win = source_buffer(fixture:path("two"))
    vim.cmd("noautocmd vsplit")
    local second_win = vim.api.nvim_get_current_win()
    assert.are_not.equal(first_win, second_win)
    assert.are.equal(source, vim.api.nvim_win_get_buf(first_win))
    assert.are.equal(source, vim.api.nvim_win_get_buf(second_win))

    local first = assert(controller:check(source, second_win))
    assert.are.equal(first.bufnr, vim.api.nvim_win_get_buf(second_win))
    assert.are.equal(source, vim.api.nvim_win_get_buf(first_win))
    assert.is_true(vim.api.nvim_buf_is_valid(source))

    goto_window(first_win)
    local second = assert(controller:check(source, first_win))
    assert.are_not.equal(first.id, second.id)
    assert.are_not.equal(first.bufnr, second.bufnr)
    assert.are.equal(second.bufnr, vim.api.nvim_win_get_buf(first_win))
    assert.are.equal(first.bufnr, vim.api.nvim_win_get_buf(second_win))
    assert.is_false(vim.api.nvim_buf_is_valid(source))
    assert.are.equal(first, manager:find_by_id(first.id))
    assert.are.equal(second, manager:find_by_id(second.id))
  end)

  it("preserves the source for config, constructor, and replacement errors without leaking children", function()
    reset_editor()
    local function assert_source_preserved(source, winid, before_count, fragment, callback)
      local err = error_text(callback)
      assert.is_truthy(err:find(fragment, 1, true), err)
      assert.is_true(vim.api.nvim_buf_is_valid(source))
      assert.are.equal(source, vim.api.nvim_win_get_buf(winid))
      assert.are.equal(before_count, instance_count(manager))
      assert.is_nil(controller._checking[source])
    end

    local source, winid = source_buffer(fixture:path("one"))
    local before = instance_count(manager)
    manager.resolve_instance_config = function() error("injected config failure") end
    assert_source_preserved(source, winid, before, "injected config failure", function()
      controller:check(source, winid)
    end)
    manager.resolve_instance_config = original_resolve_instance_config

    controller._create_instance = function() error("injected constructor failure") end
    assert_source_preserved(source, winid, before, "injected constructor failure", function()
      controller:check(source, winid)
    end)
    controller._create_instance = original_controller.create_instance

    local created
    controller._create_instance = function(target, root)
      created = original_controller.create_instance(target, root)
      return created
    end
    controller._replace_window = function() error("injected replacement failure") end
    assert_source_preserved(source, winid, before, "injected replacement failure", function()
      controller:check(source, winid)
    end)
    assert.is_not_nil(created)
    assert.are.equal("destroyed", created:status())
    assert.is_false(vim.api.nvim_buf_is_valid(created.bufnr))
  end)

  it("cleans a real post-buffer constructor option failure without disturbing the source", function()
    reset_editor()
    local gc_adapter, gc_state = gc_timer_adapter()
    fre._set_gc_adapter(gc_adapter)
    fre.setup({
      columns = {},
      gc = { ttl_ms = 1000 },
      buffer = { options = { fre_ticket20_missing_option = true } },
    })
    local source, winid = source_buffer(fixture:path("one"))
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { "source line", "second line" })
    vim.bo[source].modified = false
    vim.api.nvim_win_set_cursor(winid, { 2, 3 })
    vim.wo[winid].number = true
    local before = {
      buffers = vim.api.nvim_list_bufs(),
      instances = instance_count(manager),
      view = vim.api.nvim_win_call(winid, vim.fn.winsaveview),
      options = { number = vim.wo[winid].number, cursorline = vim.wo[winid].cursorline },
      autocmds = autocmds(),
    }
    local allocated_id
    local registry = manager._registry
    local allocate_instance_id = registry.allocate_instance_id
    registry.allocate_instance_id = function(owner)
      allocated_id = allocate_instance_id(owner)
      return allocated_id
    end

    local err = error_text(function() controller:check(source, winid) end)
    registry.allocate_instance_id = allocate_instance_id
    fre.setup({})
    assert.is_truthy(err:lower():find("unknown option", 1, true), err)
    assert.is_true(registry:is_instance_id_consumed(allocated_id))
    assert.is_nil(registry:find_marker_source(allocated_id))
    assert.are.same(before.buffers, vim.api.nvim_list_bufs())
    assert.are.equal(before.instances, instance_count(manager))
    assert.are.equal(source, vim.api.nvim_win_get_buf(winid))
    assert.are.same(before.view, vim.api.nvim_win_call(winid, vim.fn.winsaveview))
    assert.are.equal(before.options.number, vim.wo[winid].number)
    assert.are.equal(before.options.cursorline, vim.wo[winid].cursorline)
    assert.are.same(before.autocmds, autocmds())
    assert.is_nil(manager:find_by_id(allocated_id))
    assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = "FreBuffer" .. allocated_id }))
    assert.are.same({}, gc_state.handles)
    assert.is_nil(controller._checking[source])
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      assert.are_not.equal("fre://" .. allocated_id, vim.api.nvim_buf_get_name(bufnr))
    end
  end)

  it("resolves a successful takeover as the exact current View", function()
    reset_editor()
    fre.setup({ columns = {}, window = { options = { cursorline = true } } })
    local source, winid = source_buffer(fixture:path("two"))

    local child = assert(controller:check(source, winid))
    local inspected = assert(fre.view.inspect(child))
    assert.are.equal(winid, inspected.winid)
    assert.are.equal(winid, inspected.origin_winid)
    assert.are.same({ position = "current" }, inspected.layout)
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(winid))
    assert.is_true(vim.wo[winid].cursorline)
    assert.is_false(vim.api.nvim_buf_is_valid(source))

    assert.is_true(child:hidden())
    assert.is_nil(fre.view.inspect(child))
    assert.is_true(vim.api.nvim_win_is_valid(winid))
    assert.are_not.equal(child.bufnr, vim.api.nvim_win_get_buf(winid))
  end)

  it("surfaces source deletion errors without rolling back the displayed child", function()
    reset_editor()
    local source, winid = source_buffer(fixture:path("one"))
    local first_child
    controller._create_instance = function(target, root)
      first_child = original_controller.create_instance(target, root)
      return first_child
    end
    controller._delete_source = function() error("injected source delete failure") end
    local err = error_text(function() controller:check(source, winid) end)
    assert.is_truthy(err:find("injected source delete failure", 1, true))
    assert.are.equal(first_child.bufnr, vim.api.nvim_win_get_buf(winid))
    assert.are.equal(first_child, manager:find_by_id(first_child.id))
    assert.is_true(vim.api.nvim_buf_is_valid(source))
    assert.is_nil(controller._checking[source])

    vim.api.nvim_buf_delete(source, { force = true })
    local post_source = source_buffer(fixture:path("two"))
    local post_win = vim.api.nvim_get_current_win()
    local post_child
    controller._create_instance = function(target, root)
      post_child = original_controller.create_instance(target, root)
      return post_child
    end
    controller._delete_source = function(bufnr)
      vim.api.nvim_buf_delete(bufnr, {})
      error("injected post-effect delete failure")
    end
    err = error_text(function() controller:check(post_source, post_win) end)
    assert.is_truthy(err:find("injected post%-effect delete failure"))
    assert.are.equal(post_child.bufnr, vim.api.nvim_win_get_buf(post_win))
    assert.are.equal(post_child, manager:find_by_id(post_child.id))
    assert.is_false(vim.api.nvim_buf_is_valid(post_source))
    assert.is_nil(controller._checking[post_source])
  end)

  it("keeps an asynchronously load-failed takeover registered and displayed", function()
    reset_editor()
    fre._set_fs_adapter({
      load = function(_, done) done("injected takeover load failure") end,
    })
    local source, winid = source_buffer(fixture:path("three"))
    local child = assert(controller:check(source, winid))
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(winid))
    assert.are.equal(child, manager:find_by_id(child.id))
    assert.is_false(vim.api.nvim_buf_is_valid(source))
    wait_for(function() return child:status() == "load-failed" end)
    assert.are.equal("injected takeover load failure", child:failure())
    assert.are.equal(child.bufnr, vim.api.nvim_win_get_buf(winid))
  end)

  it("keeps an isolated first-false Manager entirely outside process takeover", function()
    cleanup_after_test = true
    reset_editor()
    local enable_calls = 0
    local isolated = manager_module.new({
      takeover = function(target)
        local value = takeover_module.new(target)
        value.enable = function()
          enable_calls = enable_calls + 1
          error("false decision touched takeover")
        end
        return value
      end,
    })
    local before = {
      loaded_netrw = vim.g.loaded_netrw,
      loaded_netrwPlugin = vim.g.loaded_netrwPlugin,
      buffer = vim.api.nvim_get_current_buf(),
      window = vim.api.nvim_get_current_win(),
      autocmds = autocmds(),
    }

    isolated:setup({ default_file_explorer = false })
    isolated:setup({ default_file_explorer = true, hidden_file = true })
    assert.is_false(isolated:get_default_file_explorer())
    assert.is_true(isolated:get_setup_defaults().hidden_file)
    assert.are.equal(0, enable_calls)
    assert.are.equal(before.loaded_netrw, vim.g.loaded_netrw)
    assert.are.equal(before.loaded_netrwPlugin, vim.g.loaded_netrwPlugin)
    assert.are.equal(before.buffer, vim.api.nvim_get_current_buf())
    assert.are.equal(before.window, vim.api.nvim_get_current_win())
    assert.are.same(before.autocmds, autocmds())
  end)
end)
