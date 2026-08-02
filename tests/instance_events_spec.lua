local actions = require("fre.actions")
local fre = require("fre")
local mutation_fs = require("fre.mutation.fs")
local fs = require("tests.helpers.fs")
local manager_module = require("fre.manager")
local real_fs = require("fre.fs").default

local fixture
local instances
local event_group = "FreTicket04Events"

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(2500, predicate, 10))
end

local function ready(entries)
  fixture:tree(entries or {})
  local instance = keep(fre.new({ root = fixture.root, columns = {} }))
  wait_for(function() return instance:status() == "ready" end)
  return instance
end

local function assert_serializable(data)
  local ok, encoded = pcall(vim.json.encode, data)
  assert.is_true(ok, tostring(encoded))
  assert.is_string(encoded)
  for key, value in pairs(data) do
    assert.is_not.equal("function", type(value), key)
    assert.is_not.equal("userdata", type(value), key)
    assert.is_not.equal("thread", type(value), key)
  end
end

local function capture(pattern, callback)
  vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = pattern,
    callback = function(args)
      assert.is_table(args.data)
      assert_serializable(args.data)
      callback(args.data)
    end,
  })
end

describe("fre finite Instance User events", function()
  local original_notify

  before_each(function()
    fixture = fs.new()
    instances = {}
    original_notify = vim.notify
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
    actions._reset_ui_adapter()
    vim.api.nvim_create_augroup(event_group, { clear = true })
  end)

  after_each(function()
    actions._reset_ui_adapter()
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
    vim.notify = original_notify
    for _, instance in ipairs(instances) do
      if not instance:is_destroyed() then pcall(instance.destroy, instance) end
    end
    pcall(vim.api.nvim_del_augroup_by_name, event_group)
    fixture:cleanup()
  end)

  it("publishes created before return and ready after queued observers", function()
    local order = {}
    local created_data
    local ready_data
    local manager = manager_module.default
    capture("FreInstanceCreated", function(data)
      order[#order + 1] = "created"
      created_data = data
      local instance = manager:find_by_id(data.instance_id)
      assert.is_not_nil(instance)
      assert.are.equal(instance.bufnr, data.bufnr)
      assert.are.equal("creating", instance:status())
    end)
    capture("FreReady", function(data)
      order[#order + 1] = "ready"
      ready_data = data
      local instance = manager:find_by_id(data.instance_id)
      assert.is_not_nil(instance)
      assert.are.equal("ready", instance:status())
    end)

    local pending
    fre._set_fs_adapter({ load = function(_, done) pending = done end })
    local instance = keep(fre.new({ root = fixture.root, columns = {} }))
    assert.are.same({ "created" }, order)
    assert.are.equal(instance.id, created_data.instance_id)
    assert.are.equal(instance.bufnr, created_data.bufnr)

    instance:when_ready(function(err)
      assert.is_nil(err)
      order[#order + 1] = "observer"
    end)
    pending(nil, {})
    wait_for(function() return instance:is_ready() and ready_data ~= nil end)
    assert.are.same({ "created", "observer", "ready" }, order)
    assert.are.equal(instance.id, ready_data.instance_id)
    assert.are.equal(instance.bufnr, ready_data.bufnr)
    assert.is_nil(ready_data.error)
    assert.is_table(ready_data.result)
  end)

  it("normalizes only non-serializable errors in the FreReady event payload", function()
    local thrown = { message = "sort exploded", callback = function() end }
    local pending
    local ready_data
    local observed_error
    capture("FreReady", function(data) ready_data = data end)
    fre._set_fs_adapter({ load = function(_, done) pending = done end })
    local instance = keep(fre.new({
      root = fixture.root,
      columns = {},
      sort = function() error(thrown, 0) end,
    }))
    instance:when_ready(function(err) observed_error = err end)

    pending(nil, {
      { name = "b.txt", kind = "file" },
      { name = "a.txt", kind = "file" },
    }, fixture.root)
    wait_for(function() return instance:status() == "load-failed" and ready_data ~= nil end)

    assert.are.equal(thrown, observed_error)
    assert.are.equal(thrown, instance:failure())
    assert.are.same({
      instance_id = instance.id,
      bufnr = instance.bufnr,
      error = "non-serializable error (table)",
    }, ready_data)
    assert.is_nil(ready_data.result)
  end)

  it("publishes only presentation boundary transitions", function()
    local events = {}
    capture("FreInstancePresentationChanged", function(data)
      events[#events + 1] = data
    end)
    local instance = ready({ ["a.txt"] = "a" })

    instance:open({ position = "current" })
    instance:open({ position = "current" })
    instance:hidden()
    instance:hidden()
    instance:open({ position = "current" })

    assert.are.equal(3, #events)
    assert.are.same({ instance_id = instance.id, bufnr = instance.bufnr, visible = true }, events[1])
    assert.are.same({ instance_id = instance.id, bufnr = instance.bufnr, visible = false }, events[2])
    assert.are.same({ instance_id = instance.id, bufnr = instance.bufnr, visible = true }, events[3])
  end)

  it("publishes refresh, write, and execution activity boundaries", function()
    local events = {}
    capture("FreInstanceActivityChanged", function(data)
      events[#events + 1] = data
    end)
    local instance = ready({ ["a.txt"] = "a" })

    local refresh_done
    fre._set_fs_adapter({ load = function(_, done) refresh_done = done end })
    local refresh_complete = false
    instance:refresh({ on_complete = function() refresh_complete = true end })
    assert.are.same({
      instance_id = instance.id, bufnr = instance.bufnr, activity = "refresh", active = true,
    }, events[1])
    assert.is_true(instance.sync:is_busy())
    refresh_done(nil, { { name = "a.txt", kind = "file" } }, fixture.root)
    wait_for(function() return refresh_complete and not instance.sync:is_busy() end)
    assert.are.same({
      instance_id = instance.id, bufnr = instance.bufnr, activity = "refresh", active = false,
    }, events[2])

    local write_request = instance.work:_acquire_write()
    assert.are.same({
      instance_id = instance.id, bufnr = instance.bufnr, activity = "write", active = true,
    }, events[3])
    assert.is_true(instance.work:is_write_active())
    instance.work:_release_write(write_request)
    assert.are.same({
      instance_id = instance.id, bufnr = instance.bufnr, activity = "write", active = false,
    }, events[4])

    local execution_done
    fre._set_mutation_adapter({
      create_file = function(_, done) execution_done = done end,
      create_directory = mutation_fs.default.create_directory,
      copy = mutation_fs.default.copy,
      move = mutation_fs.default.move,
      delete = mutation_fs.default.delete,
    })
    local execution = instance:execute({
      operations = { { type = "create_file", path = "created.txt" } },
    })
    wait_for(function() return execution_done ~= nil end)
    assert.are.same({
      instance_id = instance.id, bufnr = instance.bufnr, activity = "execution", active = true,
    }, events[5])
    assert.is_true(instance.work:is_execution_active())
    execution_done(nil)
    wait_for(function() return execution:get_status().state ~= "running" end)
    wait_for(function() return #events == 6 end)
    assert.are.same({
      instance_id = instance.id, bufnr = instance.bufnr, activity = "execution", active = false,
    }, events[6])
    assert.is_false(instance.work:is_execution_active())
  end)

  it("publishes the committed refresh end boundary during destruction exactly once", function()
    local sequence = {}
    local refresh_done
    local refresh_callbacks = 0
    capture("FreInstanceActivityChanged", function(data)
      if data.activity == "refresh" then
        sequence[#sequence + 1] = "refresh:" .. tostring(data.active)
      end
    end)
    capture("FreInstanceDestroying", function() sequence[#sequence + 1] = "destroying" end)
    capture("FreInstanceDestroyed", function() sequence[#sequence + 1] = "destroyed" end)
    local instance = ready({ ["a.txt"] = "a" })
    fre._set_fs_adapter({ load = function(_, done) refresh_done = done end })

    instance:refresh({ on_complete = function() refresh_callbacks = refresh_callbacks + 1 end })
    assert.are.same({ "refresh:true" }, sequence)
    instance:destroy()
    assert.are.same({
      "refresh:true", "destroying", "refresh:false", "destroyed",
    }, sequence)

    refresh_done(nil, { { name = "late.txt", kind = "file" } }, fixture.root)
    wait_for(function() return refresh_callbacks == 1 end)
    vim.wait(50, function() return false end, 10)
    assert.are.equal(1, refresh_callbacks)
    assert.are.same({
      "refresh:true", "destroying", "refresh:false", "destroyed",
    }, sequence)
  end)

  it("publishes destroying after the state commit and destroyed after cleanup", function()
    local destroying_data
    local destroyed_data
    local instance = ready({ ["a.txt"] = "a" })
    capture("FreInstanceDestroying", function(data)
      destroying_data = data
      assert.are.equal("destroying", instance:status())
      assert.is_true(vim.api.nvim_buf_is_valid(instance.bufnr))
    end)
    capture("FreInstanceDestroyed", function(data)
      destroyed_data = data
      assert.are.equal("destroyed", instance:status())
      assert.is_false(vim.api.nvim_buf_is_valid(instance.bufnr))
    end)

    instance:destroy()
    assert.are.same({ instance_id = instance.id, bufnr = instance.bufnr }, destroying_data)
    assert.are.same({ instance_id = instance.id, bufnr = instance.bufnr }, destroyed_data)
  end)

  it("isolates throwing observers and reports them asynchronously", function()
    local notifications = {}
    vim.notify = function(message) notifications[#notifications + 1] = message end
    capture("FreInstanceCreated", function()
      error("observer exploded")
    end)

    local instance = keep(fre.new({ root = fixture.root, columns = {} }))
    assert.is_true(vim.api.nvim_buf_is_valid(instance.bufnr))
    assert.are.equal("creating", instance:status())
    wait_for(function() return #notifications == 1 end)
    assert.is_truthy(notifications[1]:find("FreInstanceCreated", 1, true))
    assert.is_truthy(notifications[1]:find("observer exploded", 1, true))
  end)
end)
