local manager_module = require("fre.manager")

local function instance(manager, bufnr, group)
  return {
    id = manager:allocate_id(),
    bufnr = bufnr,
    config = { gc = { group = group or "default" } },
  }
end

describe("fre manager", function()
  it("allocates positive IDs that are never reused", function()
    local manager = manager_module.new()
    local first = instance(manager, 101)
    manager:register(first)
    manager:remove(first)
    local second = instance(manager, 102)

    assert.are.equal(1, first.id)
    assert.are.equal(2, second.id)
    assert.is_true(second.id > first.id)
  end)

  it("rejects re-registration of an ID after its instance is removed", function()
    local manager = manager_module.new()
    local first = instance(manager, 111)
    manager:register(first)
    manager:remove(first)

    local reused = {
      id = first.id,
      bufnr = 112,
      config = { gc = { group = "default" } },
    }
    assert.has_error(function()
      manager:register(reused)
    end)
    assert.is_nil(manager:find_by_id(first.id))
    assert.is_nil(manager:find_by_buf(reused.bufnr))
    assert.is_nil(manager:find_by_group("default")[first.id])
  end)

  it("registers and finds instances through every index", function()
    local manager = manager_module.new()
    local first = instance(manager, 201, "default")
    local second = instance(manager, 202, "default")
    local project = instance(manager, 203, "project")
    manager:register(first)
    manager:register(second)
    manager:register(project)

    assert.are.equal(first, manager:find_by_id(first.id))
    assert.are.equal(second, manager:find_by_buf(second.bufnr))
    local defaults = manager:find_by_group("default")
    assert.are.equal(first, defaults[first.id])
    assert.are.equal(second, defaults[second.id])
    assert.is_nil(defaults[project.id])
    assert.are.equal(project, manager:find_by_group("project")[project.id])
    assert.is_nil(manager:find_by_group("missing"))
  end)

  it("returns an independent group membership map", function()
    local manager = manager_module.new()
    local registered = instance(manager, 301)
    manager:register(registered)
    local membership = manager:find_by_group("default")
    membership[registered.id] = nil

    assert.are.equal(registered, manager:find_by_group("default")[registered.id])
  end)

  it("removes ID, buffer, and group membership consistently", function()
    local manager = manager_module.new()
    local registered = instance(manager, 401)
    manager:register(registered)
    registered.bufnr = 999
    registered.config.gc.group = "project"

    assert.are.equal(registered, manager:remove(registered.id))
    assert.is_nil(manager:find_by_id(registered.id))
    assert.is_nil(manager:find_by_buf(401))
    assert.is_nil(manager:find_by_group("default")[registered.id])
    assert.is_nil(manager:remove(registered.id))
  end)

  it("rejects duplicate indexes and unknown group membership without partial registration", function()
    local manager = manager_module.new()
    local registered = instance(manager, 501)
    manager:register(registered)

    local duplicate_buffer = instance(manager, 501)
    assert.has_error(function()
      manager:register(duplicate_buffer)
    end)
    assert.is_nil(manager:find_by_id(duplicate_buffer.id))

    local unknown_group = instance(manager, 502, "missing")
    assert.has_error(function()
      manager:register(unknown_group)
    end)
    assert.is_nil(manager:find_by_id(unknown_group.id))
    assert.is_nil(manager:find_by_buf(unknown_group.bufnr))
  end)

  it("updates group capacities while preserving membership", function()
    local manager = manager_module.new()
    local registered = instance(manager, 601, "project")
    manager:register(registered)
    manager:setup({ gc = { groups = { project = 2 } } })

    assert.are.equal(2, manager.groups.project.capacity)
    assert.are.equal(registered, manager:find_by_group("project")[registered.id])
  end)

  it("atomically rejects removal of a group with live members", function()
    local manager = manager_module.new()
    manager:setup({ gc = { groups = { temporary = 1 } } })
    local registered = instance(manager, 701, "temporary")
    manager:register(registered)
    local before = manager:get_setup_defaults()

    assert.has_error(function()
      manager:setup({ gc = { groups = { temporary = nil } } })
    end)
    -- A nil map value cannot request removal because named maps merge by key.
    -- Recompute from built-ins is the actual removal attempt.
    assert.are.same(before, manager:get_setup_defaults())

    manager:remove(registered)
    manager:setup()
    assert.is_nil(manager.groups.temporary)
  end)
end)
