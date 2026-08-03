local config = require("fre.config")
local buffer = require("fre.instance.buffer")
local Instance = require("fre.instance")
local Sync = require("fre.instance.sync")
local manager_module = require("fre.manager")
local mapping = require("fre.mapping")
local fre = require("fre")
local path = require("fre.path")
local fs = require("tests.helpers.fs")

local instances = {}
local fixture
local event_group = "FreTicket03Spec"

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(1500, predicate, 10))
end

local function lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local unit_separator = string.char(31)
local marker_pattern = "^" .. unit_separator
  .. "fre:%d+:.-:%d+" .. unit_separator

local function assert_markers(bufnr)
  for row, line in ipairs(lines(bufnr)) do
    assert.is_truthy(line:match(marker_pattern), "missing marker on row " .. row)
  end
end

local function projected_paths(instance)
  local result = {}
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(instance.buffer:decode(row))
    if decoded.row_kind == "entry" then result[#result + 1] = decoded.path end
  end
  return result
end

describe("fre async hidden instances", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
    vim.api.nvim_create_augroup(event_group, { clear = true })
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if not instance:is_destroyed() then
        instance:destroy()
      end
    end
    vim.api.nvim_del_augroup_by_name(event_group)
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("returns immediately with an independent loading buffer and stable lexical root", function()
    local pending
    fre._set_fs_adapter({
      load = function(root, done)
        pending = done
      end,
    })
    assert.has_error(function() fre.new({}) end)

    local instance = keep(fre.new({ root = "." }))
    assert.are.equal("creating", instance:status())
    assert.are.equal(path.absolute("."), instance.root)
    assert.is_true(vim.api.nvim_buf_is_valid(instance.bufnr))
    assert.are.equal("acwrite", vim.bo[instance.bufnr].buftype)
    assert.are.equal("", lines(instance.bufnr)[1])
    local non_fre = vim.api.nvim_create_buf(false, true)
    assert.is_nil(fre.get_instance(non_fre))
    vim.api.nvim_set_current_buf(non_fre)
    assert.is_nil(fre.get_instance())
    vim.api.nvim_buf_delete(non_fre, { force = true })
    assert.are.equal(instance, fre.get_instance_by_id(instance.id))
    assert.are.equal(instance, fre.get_instance(instance.bufnr))
    assert.is_not_nil(pending)

    pending(nil, {})
    wait_for(function() return instance:is_ready() end)
  end)

  it("sets a window cursor to a snapshot path after readiness", function()
    local pending
    fre._set_fs_adapter({
      load = function(_, done) pending = done end,
    })
    local instance = keep(fre.new({ root = fixture.root, columns = {} }))
    local opened, winid = instance:open({ position = "current" })
    assert.are.equal(instance, opened)
    assert.are.equal("number", type(winid))
    assert.are.equal(instance, instance:set_cursor_to_path("b.txt", winid))

    pending(nil, {
      { name = "a.txt", kind = "file" },
      { name = "b.txt", kind = "file" },
    })
    wait_for(function()
      return instance:is_ready()
        and vim.deep_equal(instance:get_pos("b.txt"), vim.api.nvim_win_get_cursor(winid))
    end)
    assert.has_error(function() instance:set_cursor_to_path("missing.txt", winid) end)
  end)

  it("keeps instances and buffers separate, including current-buffer lookup", function()
    local callbacks = {}
    fre._set_fs_adapter({
      load = function(root, done)
        callbacks[#callbacks + 1] = done
      end,
    })
    local first = keep(fre.new({ root = fixture:mkdir("one") }))
    local second = keep(fre.new({ root = fixture:mkdir("two") }))
    assert.are_not.equal(first.id, second.id)
    assert.are_not.equal(first.bufnr, second.bufnr)
    vim.api.nvim_set_current_buf(second.bufnr)
    assert.are.equal(second, fre.get_instance())
    assert.are.equal(first, fre.get_instance(first.bufnr))
    callbacks[1](nil, {})
    callbacks[2](nil, {})
    wait_for(function() return first:is_ready() and second:is_ready() end)
    assert.are.equal(first, fre.get_instance_by_id(first.id))
  end)

  it("loads direct children asynchronously and renders root-relative paths", function()
    fixture:tree({ ["adir"] = true, ["b.txt"] = "ok" })
    local instance = keep(fre.new({ root = fixture.root }))
    assert.are.equal("creating", instance:status())
    wait_for(function() return instance:is_ready() end)
    assert_markers(instance.bufnr)
    assert.are.same({ "adir/", "b.txt" }, projected_paths(instance))
    assert.are.equal(instance.tree.root, instance.tree.nodes_by_path[instance.root]) -- root has no rendered row
    assert.is_truthy(instance.tree.nodes_by_id[2])
    assert.is_truthy(instance.tree.nodes_by_id[3])
  end)

  it("sorts with fresh public Entry arguments including the root parent", function()
    local pending
    local calls = {}
    local seen_tables = {}
    fre._set_fs_adapter({
      load = function(_, done) pending = done end,
    })
    local instance = keep(fre.new({
      root = fixture.root,
      sort = function(parent, a, b)
        assert.is_nil(seen_tables[parent])
        assert.is_nil(seen_tables[a])
        assert.is_nil(seen_tables[b])
        seen_tables[parent] = true
        seen_tables[a] = true
        seen_tables[b] = true
        local a_name, b_name = a.name, b.name
        calls[#calls + 1] = {
          parent = vim.deepcopy(parent),
          a = vim.deepcopy(a),
          b = vim.deepcopy(b),
        }
        a.name = "caller mutation"
        return a_name < b_name
      end,
    }))
    pending(nil, {
      { name = "z.txt", kind = "file" },
      { name = "middle", kind = "directory" },
      { name = "a.txt", kind = "file" },
    }, fixture.root)
    wait_for(function() return instance:is_ready() end)
    assert_markers(instance.bufnr)
    assert.are.same({ "a.txt", "middle/", "z.txt" }, projected_paths(instance))
    assert.is_true(#calls > 0)
    local allowed = {
      instance_id = true, node_id = true, absolute_path = true,
      relative_path = true, name = true, kind = true,
    }
    local function assert_public_entry(entry)
      local count = 0
      for key in pairs(entry) do
        assert.is_true(allowed[key] == true)
        count = count + 1
      end
      assert.are.equal(6, count)
      assert.are.equal(instance.id, entry.instance_id)
      assert.is_true(entry.node_id > 0 and entry.node_id % 1 == 0)
      assert.is_nil(entry.stat)
      assert.is_nil(entry.parent_id)
    end
    for _, call in ipairs(calls) do
      assert_public_entry(call.parent)
      assert.are.same({
        instance_id = instance.id,
        node_id = 1,
        absolute_path = instance.root,
        relative_path = "",
        name = "",
        kind = "directory",
      }, call.parent)
      for _, entry in ipairs({ call.a, call.b }) do
        assert_public_entry(entry)
        assert.are.equal(entry.name, entry.relative_path)
        assert.are.equal(path.resolve(instance.root, entry.name), entry.absolute_path)
      end
    end
  end)

  it("turns comparator errors into one load-failed completion", function()
    local pending
    local callback_count = 0
    local callback_error
    local events = {}
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreReady",
      callback = function(args) events[#events + 1] = args.data end,
    })
    fre._set_fs_adapter({
      load = function(_, done) pending = done end,
    })
    local instance = keep(fre.new({
      root = fixture.root,
      sort = function() error("sort exploded") end,
    }))
    instance:when_ready(function(err)
      callback_count = callback_count + 1
      callback_error = err
    end)
    pending(nil, {
      { name = "b.txt", kind = "file" },
      { name = "a.txt", kind = "file" },
    }, fixture.root)
    pending(nil, {})
    wait_for(function()
      return instance:status() == "load-failed" and callback_count == 1 and #events == 1
    end)
    assert.is_truthy(tostring(callback_error):find("sort exploded", 1, true))
    assert.are.equal(callback_error, events[1].error)
    assert.is_nil(events[1].result)
    assert.is_truthy(lines(instance.bufnr)[1]:find("sort exploded", 1, true))
    vim.wait(50, function() return false end, 10)
    assert.are.equal(1, callback_count)
    assert.are.equal(1, #events)
  end)

  it("accepts a directory symlink root when the platform permits it", function()
    local target = fixture:mkdir("target")
    fixture:write("target/file.txt", "x")
    local link, err = fixture:symlink(target, "root-link")
    if not link then
      assert.is_truthy(err)
      return
    end
    local resolved, resolve_err = vim.uv.fs_realpath(link)
    if not resolved then
      assert.is_truthy(resolve_err)
      return
    end
    local instance = keep(fre.new({ root = link }))
    wait_for(function() return not instance:is_creating() end)
    assert.are.equal("ready", instance:status())
    assert_markers(instance.bufnr)
    assert.are.same({ "file.txt" }, projected_paths(instance))
  end)

  it("reports nonexistent and file roots without unregistering the instance", function()
    local missing = keep(fre.new({ root = fixture:path("missing") }))
    local file = keep(fre.new({ root = fixture:write("file", "x") }))
    wait_for(function() return missing:status() == "load-failed" and file:status() == "load-failed" end)
    assert.is_truthy(lines(missing.bufnr)[1]:find("%[fre%] Error loading", 1, false))
    assert.is_truthy(lines(file.bufnr)[1]:find("%[fre%] Error loading", 1, false))
    assert.are.equal(missing, fre.get_instance_by_id(missing.id))
    assert.are.equal(file, fre.get_instance(file.bufnr))
    assert.is_false(lines(missing.bufnr)[1]:sub(1, 1) == string.char(31))
    missing:open()
    assert.are.equal(missing.bufnr, vim.api.nvim_get_current_buf())
    assert.are.equal("load-failed", missing:status())
  end)

  it("delivers when_ready and FreReady exactly once for one attempt", function()
    local pending
    local events = {}
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreReady",
      callback = function(args)
        events[#events + 1] = args.data
      end,
    })
    fre._set_fs_adapter({
      load = function(_, done) pending = done end,
    })
    local instance = keep(fre.new({ root = fixture.root }))
    local callback_count = 0
    local callback_error
    instance:when_ready(function(err)
      callback_count = callback_count + 1
      callback_error = err
    end)
    pending(nil, {})
    pending(nil, {})
    wait_for(function() return instance:is_ready() and #events == 1 and callback_count == 1 end)
    assert.is_nil(callback_error)
    assert.are.equal(instance.id, events[1].instance_id)
    assert.are.equal(instance.bufnr, events[1].bufnr)
    assert.is_nil(events[1].error)
    assert.is_table(events[1].result)

    local late_count = 0
    instance:when_ready(function() late_count = late_count + 1 end)
    wait_for(function() return late_count == 1 end)
    assert.are.equal(1, late_count)
  end)

  it("notifies queued observers before a reentrant FreReady destroy", function()
    local pending
    local order = {}
    local callback_on_main_loop = false
    local instance
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreReady",
      callback = function()
        order[#order + 1] = "event"
        instance:destroy()
      end,
    })
    fre._set_fs_adapter({
      load = function(_, done) pending = done end,
    })
    instance = keep(fre.new({ root = fixture.root }))
    instance:when_ready(function(err)
      assert.is_nil(err)
      callback_on_main_loop = not vim.in_fast_event()
      order[#order + 1] = "callback"
    end)
    pending(nil, {}, fixture.root)
    wait_for(function() return instance:is_destroyed() end)
    assert.is_true(callback_on_main_loop)
    assert.are.same({ "callback", "event" }, order)
  end)

  it("installs required metadata, copied variables, and protects fre metadata", function()
    local instance = keep(fre.new({
      root = fixture.root,
      buffer = {
        options = { modifiable = false },
        variables = { answer = 42, nested = { ok = true } },
      },
    }))
    assert.are.equal("acwrite", vim.bo[instance.bufnr].buftype)
    assert.are.equal("hide", vim.bo[instance.bufnr].bufhidden)
    assert.is_false(vim.bo[instance.bufnr].swapfile)
    assert.is_false(vim.bo[instance.bufnr].buflisted)
    assert.are.equal("fre", vim.bo[instance.bufnr].filetype)
    assert.is_false(vim.bo[instance.bufnr].modifiable)
    assert.are.equal(42, vim.b[instance.bufnr].answer)
    assert.are.same({ ok = true }, vim.b[instance.bufnr].nested)
    assert.are.same({
      version = 1,
      instance_id = instance.id,
      root = instance.root,
    }, vim.b[instance.bufnr].fre)
    assert.is_nil(rawget(instance, "config"))
    assert.is_nil(rawget(instance.buffer, "config"))
    assert.is_table(instance.buffer.columns)
    assert.is_nil(rawget(instance.buffer, "buffer_options"))
    assert.is_nil(rawget(instance.buffer, "buffer_variables"))
    assert.is_nil(rawget(instance.buffer, "mapping"))
    assert.is_nil(rawget(instance.buffer, "use_mapping_default"))
    assert.is_nil(rawget(instance.sync, "config"))
    wait_for(function() return instance:is_ready() end)
    assert.is_nil(rawget(instance.sync, "expanded"))
    assert.is_false(instance.sync.auto_expand_single_directory)
    assert.is_nil(rawget(instance.work, "get_mutation_adapter"))
    assert.is_table(instance.work.mutation_adapter)
    assert.is_table(instance.work.write_ui_adapter)
    assert.is_nil(vim.b[instance.bufnr].fre.gc_group)
    assert.has_error(function()
      fre.new({ root = fixture.root, buffer = { variables = { fre = "no" } } })
    end)
  end)

  it("copies only known core inputs to their owners and accepts concrete adapters", function()
    local root = path.absolute(fixture.root)
    fixture:mkdir("dir")
    local effective = config.resolve_instance(config.resolve_setup(), {
      root = root,
      expanded = { "dir" },
      buffer = {
        options = { modifiable = false },
        variables = { retained_only_in_nvim = { value = 1 } },
      },
      mapping = { n = { x = function() end } },
    }, root)
    local caller_owned = { nested = { value = 1 } }
    effective.caller_owned = caller_owned

    local load_callbacks = {}
    local fs_adapter = {
      load = function(_, done) load_callbacks[#load_callbacks + 1] = done end,
    }
    local watch_adapter = require("fre.watch").default
    local mutation_adapter = require("fre.mutation.fs").default
    local write_ui_adapter = require("fre.write_ui")
    local options = config.copy(effective)
    options.root = root
    options.fs_adapter = fs_adapter
    options.watch_adapter = watch_adapter
    options.mutation_adapter = mutation_adapter
    options.write_ui_adapter = write_ui_adapter
    local instance = keep(Instance.new(options))

    assert.is_nil(rawget(instance, "caller_owned"))
    assert.is_nil(rawget(instance.buffer, "caller_owned"))
    assert.is_nil(rawget(instance.sync, "caller_owned"))
    assert.is_nil(rawget(instance.work, "caller_owned"))
    assert.are.equal(fs_adapter, instance.sync.fs_adapter)
    assert.are.equal(watch_adapter, instance.sync.watch.adapter)
    assert.are.equal(mutation_adapter, instance.work.mutation_adapter)
    assert.are.equal(write_ui_adapter, instance.work.write_ui_adapter)
    assert.are.same({ "dir" }, rawget(instance.sync, "expanded"))
    assert.are_not.equal(effective.columns, instance.buffer.columns)
    assert.are_not.equal(effective.layout, instance.view.default_layout)
    assert.are_not.equal(effective.window.options, instance.view.window_options)
    assert.is_nil(rawget(instance.buffer, "buffer_options"))
    assert.is_nil(rawget(instance.buffer, "buffer_variables"))
    assert.is_nil(rawget(instance.buffer, "mapping"))
    assert.is_nil(rawget(instance.buffer, "use_mapping_default"))

    effective.expanded[1] = "caller-mutated"
    effective.columns[1] = nil
    effective.layout.size = 99
    effective.window.options.wrap = true
    caller_owned.nested.value = 2
    assert.are.same({ "dir" }, rawget(instance.sync, "expanded"))
    assert.is_not_nil(instance.buffer.columns[1])
    assert.are_not.equal(99, instance.view.default_layout.size)
    assert.is_false(instance.view.window_options.wrap)
    assert.are.same({ value = 1 }, vim.b[instance.bufnr].retained_only_in_nvim)

    assert.is_nil(rawget(instance, "manager"))
    assert.is_function(load_callbacks[1])
    load_callbacks[1](nil, { { name = "dir", kind = "directory" } }, root)
    wait_for(function() return load_callbacks[2] ~= nil end)
    load_callbacks[2](nil, {}, path.resolve(root, "dir"))
    wait_for(function() return instance:is_ready() end)
    assert.is_nil(rawget(instance.sync, "expanded"))
    assert.is_true(instance.tree.nodes_by_path[path.resolve(root, "dir")].expanded)
    assert.is_not_nil(instance:get_pos("dir"))
  end)

  it("retries a failed initial load and permits explicit cleanup", function()
    local callbacks = {}
    local events = {}
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreReady",
      callback = function(args) events[#events + 1] = args.data end,
    })
    fre._set_fs_adapter({
      load = function(_, done) callbacks[#callbacks + 1] = done end,
    })
    local instance = keep(fre.new({ root = fixture.root }))
    local failures, successes, refresh_completions = 0, 0, 0
    instance:when_ready(function(err)
      if err then failures = failures + 1 end
    end)
    callbacks[1]("first failure")
    wait_for(function() return instance:status() == "load-failed" and failures == 1 and #events == 1 end)
    assert.are.equal("first failure", events[1].error)
    instance:refresh({ on_complete = function(err)
      assert.is_nil(err)
      refresh_completions = refresh_completions + 1
    end })
    instance:when_ready(function(err)
      if not err then successes = successes + 1 end
    end)
    assert.are.equal("creating", instance:status())
    callbacks[2](nil, {})
    wait_for(function()
      return instance:is_ready() and failures == 1 and successes == 1
        and refresh_completions == 1 and #events == 2
    end)
    assert.is_nil(events[2].error)
    assert.are.equal(instance.id, events[2].instance_id)
    local bufnr, id = instance.bufnr, instance.id
    instance:destroy()
    assert.are.equal("destroyed", instance:status())
    assert.is_nil(fre.get_instance(bufnr))
    assert.is_nil(fre.get_instance_by_id(id))
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)

  it("registers only after core construction returns and before scheduled completion", function()
    local manager = manager_module.new()
    local ready_registration
    local core_returned = false
    local gc_enrolled = false
    manager:set_fs_adapter({
      load = function(_, done) done(nil, {}) end,
    })
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreReady",
      callback = function(args)
        local by_id = manager:find_by_id(args.data.instance_id)
        local by_buf = manager:find_by_buf(args.data.bufnr)
        local group = manager:find_by_group("default")
        ready_registration = by_id ~= nil
          and by_id == by_buf
          and group[args.data.instance_id] == by_id
          and gc_enrolled
      end,
    })

    local original_new = Instance.new
    local original_register = manager.register
    local original_gc_register = manager._gc.register
    Instance.new = function(options, ...)
      assert.are.equal(0, select("#", ...))
      assert.is_string(options.id)
      assert.is_function(options.resolve_instance)
      assert.is_nil(options.gc)
      local created = original_new(options)
      assert.is_nil(rawget(created, "manager"))
      core_returned = true
      return created
    end
    manager.register = function(target, created, policy)
      assert.is_true(core_returned)
      return original_register(target, created, policy)
    end
    manager._gc.register = function(controller, created, policy)
      local registered = original_gc_register(controller, created, policy)
      gc_enrolled = true
      return registered
    end

    local ok, result = pcall(manager.create_instance, manager, { root = fixture.root })
    Instance.new = original_new
    manager.register = original_register
    manager._gc.register = original_gc_register
    assert.is_true(ok, tostring(result))
    local instance = keep(result)

    assert.are.equal(instance, manager:find_by_id(instance.id))
    assert.are.equal(instance, manager:find_by_buf(instance.bufnr))
    wait_for(function() return instance:is_ready() and ready_registration == true end)
  end)

  it("cleans failed core construction without registration or GC rollback", function()
    local manager = manager_module.new()
    local root = path.absolute(fixture.root)
    local allocated = {}
    local registrations = 0
    local enrollments = 0
    local original_new = Instance.new
    local original_register = manager.register
    local original_gc_register = manager._gc.register
    Instance.new = function(options)
      allocated[#allocated + 1] = options.id
      return original_new(options)
    end
    manager.register = function(target, created, policy)
      registrations = registrations + 1
      return original_register(target, created, policy)
    end
    manager._gc.register = function(controller, created, policy)
      enrollments = enrollments + 1
      return original_gc_register(controller, created, policy)
    end

    local stages = {
      {
        name = "buffer setup",
        install = function()
          local original = buffer.setup
          buffer.setup = function(instance)
            original(instance)
            error("injected buffer setup constructor fault")
          end
          return function() buffer.setup = original end
        end,
      },
      {
        name = "mapping setup",
        install = function()
          local original = mapping.setup
          mapping.setup = function(instance)
            original(instance)
            error("injected mapping setup constructor fault")
          end
          return function() mapping.setup = original end
        end,
      },
    }

    for _, stage in ipairs(stages) do
      local pending
      manager:set_fs_adapter({ load = function(_, done) pending = done end })
      local before_buffers = vim.api.nvim_list_bufs()
      local before_allocations = #allocated
      local restore = stage.install()
      local ok, err = pcall(manager.create_instance, manager, { root = root })
      restore()

      local failed_id = allocated[#allocated]
      assert.is_false(ok, stage.name)
      assert.is_truthy(tostring(err):find("injected " .. stage.name, 1, true), tostring(err))
      assert.are.equal(before_allocations + 1, #allocated)
      assert.is_string(failed_id)
      assert.are.same(before_buffers, vim.api.nvim_list_bufs())
      assert.is_nil(manager:find_by_id(failed_id))
      assert.is_nil(manager:find_by_group("default")[failed_id])
      if pending then
        pending(nil, {})
        vim.wait(20, function() return false end, 5)
        assert.are.same(before_buffers, vim.api.nvim_list_bufs())
      end
    end

    Instance.new = original_new
    manager.register = original_register
    manager._gc.register = original_gc_register
    assert.are.equal(0, registrations)
    assert.are.equal(0, enrollments)
    assert.are_not.equal(allocated[1], allocated[2])
  end)

  it("cleans core resources when managed registration fails atomically", function()
    local timers = { created = 0, stopped = 0, closed = 0 }
    local manager = manager_module.new()
    manager:set_gc_adapter({
      now = function() return 0 end,
      new_timer = function()
        timers.created = timers.created + 1
        return {}
      end,
      timer_start = function(handle, _, callback)
        handle.callback = callback
        return true
      end,
      timer_stop = function(handle)
        if not handle.stopped then
          handle.stopped = true
          timers.stopped = timers.stopped + 1
        end
      end,
      close = function(handle)
        if not handle.closed then
          handle.closed = true
          timers.closed = timers.closed + 1
        end
      end,
      schedule = vim.schedule,
    })
    manager:setup({
      default_file_explorer = false,
      columns = {},
      gc = { ttl_ms = 100 },
    })
    local pending
    manager:set_fs_adapter({ load = function(_, done) pending = done end })
    local before_buffers = vim.api.nvim_list_bufs()
    local constructed
    local ready_events = 0
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreReady",
      callback = function() ready_events = ready_events + 1 end,
    })
    local original_gc_register = manager._gc.register
    manager._gc.register = function(controller, created, policy)
      constructed = created
      local registered = original_gc_register(controller, created, policy)
      error("injected managed registration failure")
      return registered
    end

    local ok, err = pcall(manager.create_instance, manager, { root = fixture.root })
    manager._gc.register = original_gc_register

    local failed_id = constructed.id
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected managed registration failure", 1, true))
    assert.is_function(pending)
    assert.are.equal("destroyed", constructed:status())
    assert.is_false(vim.api.nvim_buf_is_valid(constructed.bufnr))
    assert.is_nil(manager:find_by_id(failed_id))
    assert.is_nil(manager:find_by_buf(constructed.bufnr))
    assert.is_nil(manager:find_by_group("default")[failed_id])
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())
    assert.are.same({ created = 1, stopped = 1, closed = 1 }, timers)
    pending(nil, {})
    vim.wait(20, function() return false end, 5)
    assert.are.equal(0, ready_events)
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())
  end)

  it("cleans core ownership before managed registration when initial load start fails", function()
    local manager = manager_module.new()
    local pending
    manager:set_fs_adapter({ load = function(_, done) pending = done end })
    local before_buffers = vim.api.nvim_list_bufs()
    local failed_id
    local original_new = Instance.new
    Instance.new = function(options)
      failed_id = options.id
      return original_new(options)
    end
    local registrations = 0
    local original_register = manager.register
    local original_load_initial = Sync.load_initial
    manager.register = function(target, created, policy)
      registrations = registrations + 1
      return original_register(target, created, policy)
    end
    Sync.load_initial = function(sync, ...)
      original_load_initial(sync, ...)
      error("injected load start failure")
    end

    local ok, err = pcall(manager.create_instance, manager, { root = fixture.root })
    manager.register = original_register
    Sync.load_initial = original_load_initial
    Instance.new = original_new

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected load start failure", 1, true))
    assert.is_function(pending)
    assert.are.equal(0, registrations)
    assert.is_string(failed_id)
    assert.is_nil(manager:find_by_id(failed_id))
    assert.is_nil(manager:find_by_group("default")[failed_id])
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())

    pending(nil, {})
    vim.wait(20, function() return false end, 5)
    assert.is_nil(manager:find_by_id(failed_id))
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())
  end)
end)
