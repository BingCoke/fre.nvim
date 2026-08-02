local fre = require("fre")
local manager_module = require("fre.manager")
local fs = require("tests.helpers.fs")

local fixture
local instances
local clock

local function wait_for(predicate, timeout)
  assert.is_true(vim.wait(timeout or 3000, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function()
    return instance:status() == "ready" or instance:status() == "load-failed"
  end)
  assert.are.equal("ready", instance:status(), tostring(instance:failure()))
  return instance
end

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function ready(opts)
  opts = vim.tbl_extend("force", { root = fixture.root, columns = {} }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function fake_clock()
  local now = 0
  local timers = {}
  local scheduled = {}
  local adapter = {}

  function adapter.now() return now end
  function adapter.new_timer()
    local timer = { active = false, closed = false }
    timers[#timers + 1] = timer
    return timer
  end
  function adapter.timer_start(timer, timeout, callback)
    timer.active = true
    timer.deadline = now + timeout
    timer.callback = callback
    return true
  end
  function adapter.timer_stop(timer)
    timer.active = false
    return true
  end
  function adapter.close(timer)
    timer.closed = true
    return true
  end
  function adapter.schedule(callback)
    scheduled[#scheduled + 1] = callback
    return true
  end

  local result = { adapter = adapter }
  function result:drain()
    while #scheduled > 0 do table.remove(scheduled, 1)() end
  end
  function result:advance(amount)
    now = now + amount
    local due = {}
    for _, timer in ipairs(timers) do
      if timer.active and timer.deadline <= now then
        timer.active = false
        due[#due + 1] = timer
      end
    end
    table.sort(due, function(left, right) return left.deadline < right.deadline end)
    for _, timer in ipairs(due) do timer.callback() end
    self:drain()
  end
  return result
end

local function scratch()
  return vim.api.nvim_create_buf(false, true)
end

local function set_modified(instance, value)
  vim.bo[instance.bufnr].modified = value
  vim.api.nvim_exec_autocmds("BufModifiedSet", {
    buffer = instance.bufnr,
    modeline = false,
  })
end

local function members(group)
  return manager_module.default:find_by_group(group)
end

local function gc_info(instance)
  return manager_module.default:get_gc_controller():inspect(instance)
end

local function assert_error_contains(callback, fragment)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find(fragment, 1, true), tostring(err))
end

describe("fre managed destruction and GC", function()
  local original_notify

  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture = fs.new()
    fixture:tree({ ["one.txt"] = "one" })
    instances = {}
    clock = fake_clock()
    original_notify = vim.notify
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
    fre._reset_watch_adapter()
    fre._set_gc_adapter(clock.adapter)
    fre.setup({
      default_file_explorer = false,
      columns = {},
      gc = { ttl_ms = 0, groups = { default = 0, project = 0 } },
    })
  end)

  after_each(function()
    vim.notify = original_notify
    fre._reset_mutation_adapter()
    fre._reset_fs_adapter()
    fre._reset_watch_adapter()
    for _, instance in ipairs(instances) do
      if not instance:is_destroyed() then
        local execution = instance.work and instance.work:active_execution()
        if execution and execution:get_status().state == "running" then
          pcall(execution.cancel, execution)
          vim.wait(500, function() return execution:get_status().state ~= "running" end, 10)
        end
        if instance.work and instance.work:is_write_active() then
          pcall(instance.work._release_write, instance.work, instance.work.write_request)
        end
        pcall(instance.destroy, instance)
      end
    end
    clock:drain()
    fre._reset_gc_adapter()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture:cleanup()
  end)

  it("removes Manager indexes and GC membership only at terminal destruction", function()
    local instance = ready({ gc = { ttl_ms = 100 } })
    local id, bufnr = instance.id, instance.bufnr
    assert.are.equal(instance, fre.get_instance_by_id(id))
    assert.are.equal(instance, members("default")[id])

    instance:destroy()

    assert.are.equal("destroyed", instance:status())
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_nil(fre.get_instance_by_id(id))
    assert.is_nil(fre.get_instance(bufnr))
    assert.is_nil(members("default")[id])
    assert.is_nil(gc_info(instance))
  end)

  it("keeps a failed destruction retryable and indexed until terminal cleanup", function()
    local instance = ready({ gc = { ttl_ms = 100 } })
    local id, bufnr = instance.id, instance.bufnr
    local original_delete = vim.api.nvim_buf_delete
    local original_call = vim.api.nvim_buf_call
    vim.api.nvim_buf_delete = function() error("API delete failed") end
    vim.api.nvim_buf_call = function() error("fallback delete failed") end
    local ok, err = pcall(instance.destroy, instance)
    vim.api.nvim_buf_delete = original_delete
    vim.api.nvim_buf_call = original_call

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("fallback delete failed", 1, true))
    assert.are.equal("destroying", instance:status())
    assert.are.equal(instance, fre.get_instance_by_id(id))
    assert.are.equal(instance, fre.get_instance(bufnr))
    assert.are.equal(instance, members("default")[id])
    assert.is_not_nil(gc_info(instance))

    instance:destroy()
    assert.are.equal("destroyed", instance:status())
    assert.is_nil(fre.get_instance_by_id(id))
    assert.is_nil(members("default")[id])
    assert.is_nil(gc_info(instance))
  end)

  it("completes the same terminal cleanup after external buffer deletion", function()
    for _, command in ipairs({ "bdelete!", "bwipeout!" }) do
      local instance = ready({ gc = { ttl_ms = 100 } })
      local id, bufnr = instance.id, instance.bufnr
      vim.cmd(command .. " " .. tostring(bufnr))
      wait_for(function() return instance:is_destroyed() end)

      assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
      assert.is_nil(fre.get_instance_by_id(id))
      assert.is_nil(fre.get_instance(bufnr))
      assert.is_nil(members("default")[id])
      assert.is_nil(gc_info(instance))
    end
  end)

  it("protects visible buffers and starts TTL from the final presentation leave", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 100, groups = { default = 0, project = 0 },
    } })
    local instance = ready()
    clock:advance(40)
    local first_tab = vim.api.nvim_get_current_tabpage()
    instance:open({ position = "current" })
    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    instance:open({ position = "current" })

    clock:advance(200)
    assert.are.equal("ready", instance:status())
    instance:hidden(second_tab)
    clock:advance(200)
    assert.are.equal("ready", instance:status())

    vim.api.nvim_set_current_tabpage(first_tab)
    instance:hidden(first_tab)
    clock:advance(99)
    assert.are.equal("ready", instance:status())
    clock:advance(1)
    assert.are.equal("destroyed", instance:status())
  end)

  it("does not reset a hidden interval on repeated presentation synchronization", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 50, groups = { default = 0, project = 0 },
    } })
    local instance = ready()
    clock:advance(25)
    instance:sync_view({ report = true })
    instance:sync_view({ report = true })
    clock:advance(24)
    assert.are.equal("ready", instance:status())
    clock:advance(1)
    assert.are.equal("destroyed", instance:status())
  end)

  it("uses actual Neovim visibility as the final destruction guard", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 20, groups = { default = 0, project = 0 },
    } })
    local instance = ready()
    vim.api.nvim_win_set_buf(0, instance.bufnr)
    clock:advance(20)
    assert.are.equal("ready", instance:status())
    assert.is_false(manager_module.default:is_gc_eligible(instance))

    vim.api.nvim_win_set_buf(0, scratch())
    wait_for(function() return gc_info(instance).hidden end)
    clock:advance(20)
    assert.are.equal("destroyed", instance:status())
  end)

  it("preserves independent zero-disable semantics for TTL and capacity", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 1, project = 0 },
    } })
    local older = ready()
    clock:advance(1)
    local newer = ready()
    assert.are.equal("destroyed", older:status())
    assert.are.equal("ready", newer:status())
    clock:advance(1000)
    assert.are.equal("ready", newer:status())

    newer:destroy()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 10, groups = { default = 0, project = 0 },
    } })
    local ttl = ready()
    clock:advance(10)
    assert.are.equal("destroyed", ttl:status())
  end)

  it("selects capacity victims deterministically while counting visible members", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, include_modified = false,
      groups = { default = 2, project = 0 },
    } })
    local first = ready()
    set_modified(first, true)
    clock:drain()
    clock:advance(1)
    local second = ready()
    set_modified(second, true)
    clock:drain()
    clock:advance(1)
    local third = ready()
    set_modified(third, true)
    clock:drain()
    set_modified(first, false)
    set_modified(second, false)
    set_modified(third, false)
    clock:drain()
    manager_module.default:get_gc_controller():enforce_group("default", third)

    assert.are.equal("destroyed", first:status())
    assert.are.equal("ready", second:status())
    assert.are.equal("ready", third:status())

    second:open({ position = "current" })
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 1, project = 0 },
    } })
    assert.are.equal("ready", second:status())
    assert.are.equal("destroyed", third:status())
  end)

  it("snapshots modified-buffer policy across later setup changes", function()
    local protected = ready({ gc = { ttl_ms = 20, include_modified = false } })
    set_modified(protected, true)
    fre.setup({ columns = {}, gc = {
      ttl_ms = 20, include_modified = true,
      groups = { default = 0, project = 0 },
    } })
    clock:advance(20)
    assert.are.equal("ready", protected:status())
    set_modified(protected, false)
    clock:drain()
    assert.are.equal("destroyed", protected:status())

    local disposable = ready()
    set_modified(disposable, true)
    clock:advance(20)
    assert.are.equal("destroyed", disposable:status())
  end)

  it("reconsiders hidden instances after write and execution activity ends", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 10, groups = { default = 0, project = 0 },
    } })
    local writing = ready()
    local request = writing.work:_acquire_write()
    clock:advance(10)
    assert.are.equal("ready", writing:status())
    writing.work:_release_write(request)
    clock:drain()
    assert.are.equal("destroyed", writing:status())

    local pending
    fre._set_mutation_adapter({
      create_file = function(_, done) pending = done end,
      create_directory = function(_, done) done(nil) end,
      copy = function(_, _, _, done) done(nil) end,
      move = function(_, _, done) done(nil) end,
      delete = function(_, _, done) done(nil) end,
    })
    local executing = ready()
    local execution = executing:execute({ operations = {
      { type = "create_file", path = "held.txt" },
    } })
    wait_for(function() return pending ~= nil end)
    clock:advance(10)
    assert.are.equal("ready", executing:status())
    pending(nil)
    wait_for(function() return execution:get_status().state == "succeeded" end)
    clock:drain()
    assert.are.equal("destroyed", executing:status())
  end)

  it("reconsiders a creating member after FreReady makes it eligible", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 1, project = 0 },
    } })
    local pending
    fre._set_fs_adapter({ load = function(_, done) pending = done end })
    local creating = keep(fre.new({ root = fixture.root, columns = {} }))
    fre._reset_fs_adapter()
    local visible = ready()
    visible:open({ position = "current" })
    assert.are.equal(2, vim.tbl_count(members("default")))

    pending(nil, {}, fixture.root)
    wait_for(function() return creating:is_ready() end)
    clock:drain()
    assert.are.equal("destroyed", creating:status())
    assert.are.equal("ready", visible:status())
  end)

  it("keeps managed creation committed when protected capacity enforcement fails", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 1, project = 0 },
    } })
    local victim = ready()
    local original_delete = vim.api.nvim_buf_delete
    local original_call = vim.api.nvim_buf_call
    local notices = {}
    vim.notify = function(message) notices[#notices + 1] = tostring(message) end
    vim.api.nvim_buf_delete = function(bufnr, ...)
      if bufnr == victim.bufnr then error("injected delete failure") end
      return original_delete(bufnr, ...)
    end
    vim.api.nvim_buf_call = function(bufnr, callback)
      if bufnr == victim.bufnr then error("injected fallback failure") end
      return original_call(bufnr, callback)
    end

    local ok, created = xpcall(function()
      return fre.new({ root = fixture.root, columns = {}, gc = { ttl_ms = 0 } })
    end, debug.traceback)
    vim.api.nvim_buf_delete = original_delete
    vim.api.nvim_buf_call = original_call

    assert.is_true(ok, tostring(created))
    keep(created)
    assert.are.equal("destroying", victim:status())
    assert.are.equal(victim, fre.get_instance_by_id(victim.id))
    assert.are.equal(victim, members("default")[victim.id])
    assert.are.equal(created, fre.get_instance_by_id(created.id))
    assert.are.equal(created, members("default")[created.id])
    clock:drain()
    assert.is_true(#notices > 0)
    assert.is_truthy(table.concat(notices, "\n"):find("capacity enforcement failed", 1, true))

    victim:destroy()
    assert.are.equal("destroyed", victim:status())
    assert.are.equal("creating", created:status())
    wait_ready(created)
  end)

  it("migrates authoritative membership without core or buffer GC metadata", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 100, groups = { default = 0, project = 0 },
    } })
    local instance = ready()
    clock:advance(25)

    assert.are.equal(instance, instance:setGroup("project"))
    assert.is_nil(members("default")[instance.id])
    assert.are.equal(instance, members("project")[instance.id])
    assert.are.equal("project", gc_info(instance).group)
    assert.is_nil(instance.config.gc)
    assert.is_nil(vim.b[instance.bufnr].fre.gc_group)

    clock:advance(74)
    assert.are.equal("ready", instance:status())
    clock:advance(1)
    assert.are.equal("destroyed", instance:status())
  end)

  it("protects a moved instance during target-capacity enforcement", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 0, project = 1 },
    } })
    local existing = ready({ gc = { group = "project" } })
    clock:advance(1)
    local moved = ready()

    moved:setGroup("project")

    assert.are.equal("destroyed", existing:status())
    assert.are.equal("ready", moved:status())
    assert.are.equal(moved, members("project")[moved.id])
    assert.are.equal("project", gc_info(moved).group)
  end)

  it("rolls back only GC-owned membership when migration enforcement fails", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 100, groups = { default = 0, project = 1 },
    } })
    local existing = ready({ gc = { group = "project" } })
    clock:advance(1)
    local moved = ready()
    local destroy = existing.destroy
    existing.destroy = function() error("injected target destroy failure") end

    local ok, err = pcall(moved.setGroup, moved, "project")
    existing.destroy = destroy

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected target destroy failure", 1, true))
    assert.are.equal(existing, members("project")[existing.id])
    assert.are.equal(moved, members("default")[moved.id])
    assert.is_nil(members("project")[moved.id])
    assert.are.equal("default", gc_info(moved).group)
    assert.is_nil(moved.config.gc)
    assert.is_nil(vim.b[moved.bufnr].fre.gc_group)
  end)

  it("updates GC-owned capacities and rejects removal of a live group", function()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 2, project = 0, temporary = 1 },
    } })
    local temporary = ready({ gc = { group = "temporary" } })
    assert.are.equal(1, manager_module.default:get_gc_controller():group_capacity("temporary"))

    assert_error_contains(function()
      fre.setup({ columns = {}, gc = {
        ttl_ms = 0, groups = { default = 2, project = 0 },
      } })
    end, "cannot remove GC group used by a live instance")
    assert.are.equal(temporary, members("temporary")[temporary.id])

    temporary:destroy()
    fre.setup({ columns = {}, gc = {
      ttl_ms = 0, groups = { default = 1, project = 0 },
    } })
    assert.is_nil(members("temporary"))
    assert.are.equal(1, manager_module.default:get_gc_controller():group_capacity("default"))
  end)
end)
