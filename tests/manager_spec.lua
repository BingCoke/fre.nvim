local manager_module = require("fre.manager")

local next_id = 1
local function instance(_, bufnr, group)
  local id = next_id
  next_id = id + 1
  return {
    id = id,
    bufnr = bufnr,
    config = { gc = { group = group or "default" } },
    is_destroyed = function() return false end,
    is_destroying = function() return false end,
  }
end

describe("fre manager", function()

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

  it("moves registered GC membership without changing other indexes", function()
    local manager = manager_module.new()
    manager:setup({ gc = { ttl_ms = 0, groups = { default = 0, project = 0 } } })
    local bufnr = vim.api.nvim_create_buf(false, true)
    local registered = instance(manager, bufnr)
    vim.b[bufnr].fre = { gc_group = "default" }
    manager:register(registered)

    assert.are.equal(registered, manager:move_to_group(registered, "project"))
    assert.is_nil(manager.groups.default.instances[registered.id])
    assert.are.equal(registered, manager.groups.project.instances[registered.id])
    assert.are.equal(registered, manager:find_by_id(registered.id))
    assert.are.equal(registered, manager:find_by_buf(bufnr))
    assert.are.equal("project", registered.config.gc.group)
    assert.are.equal("project", vim.b[bufnr].fre.gc_group)

    local project_members = manager.groups.project.instances
    assert.are.equal(registered, manager:move_to_group(registered, "project"))
    assert.are.equal(project_members, manager.groups.project.instances)
    assert.are.equal(registered, project_members[registered.id])

    local before_metadata = vim.b[bufnr].fre
    assert.has_error(function() manager:move_to_group(registered, "missing") end)
    assert.are.equal("project", registered.config.gc.group)
    assert.are.same(before_metadata, vim.b[bufnr].fre)
    assert.are.equal(registered, manager.groups.project.instances[registered.id])

    manager:remove(registered)
    assert.has_error(function() manager:move_to_group(registered, "default") end)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("rolls back group migration when metadata assignment fails", function()
    local manager = manager_module.new()
    manager:setup({ gc = { ttl_ms = 0, groups = { default = 0, project = 0 } } })
    local bufnr = vim.api.nvim_create_buf(false, true)
    local registered = instance(manager, bufnr)
    vim.b[bufnr].fre = { gc_group = "default" }
    manager:register(registered)

    local real_b = vim.b
    vim.b = setmetatable({}, {
      __index = function(_, buffer)
        local variables = real_b[buffer]
        return setmetatable({}, {
          __index = function(_, name) return variables[name] end,
          __newindex = function(_, name, value)
            if name == "fre" then error("injected metadata setter failure") end
            variables[name] = value
          end,
        })
      end,
    })
    local ok, err = pcall(manager.move_to_group, manager, registered, "project")
    vim.b = real_b

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected metadata setter failure", 1, true))
    assert.are.equal(registered, manager.groups.default.instances[registered.id])
    assert.is_nil(manager.groups.project.instances[registered.id])
    assert.are.equal("default", registered.config.gc.group)
    assert.are.equal("default", vim.b[bufnr].fre.gc_group)

    manager:remove(registered)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("consumes only matching live presentation facts through its User autocmd", function()
    local manager = manager_module.new()
    manager:setup({ gc = { ttl_ms = 0, groups = { default = 0, project = 0 } } })
    local first_buf = vim.api.nvim_create_buf(false, true)
    local second_buf = vim.api.nvim_create_buf(false, true)
    local first = instance(manager, first_buf)
    local second = instance(manager, second_buf)
    manager:register(first)
    manager:register(second)

    local function emit(data)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "FreInstancePresentationChanged", modeline = false, data = data,
      })
    end

    local first_hidden = first.hidden_since
    local second_hidden = second.hidden_since
    emit({ instance_id = first.id, bufnr = second.bufnr, visible = true })
    emit({ instance_id = first.id + 10000, bufnr = first.bufnr, visible = true })
    emit({ instance_id = first.id, bufnr = first.bufnr + 10000, visible = true })
    assert.are.equal(first_hidden, first.hidden_since)
    assert.are.equal(second_hidden, second.hidden_since)

    emit({ instance_id = first.id, bufnr = first.bufnr, visible = true })
    assert.is_nil(first.hidden_since)
    assert.are.equal(second_hidden, second.hidden_since)

    emit({ instance_id = first.id, bufnr = first.bufnr, visible = false })
    assert.is_number(first.hidden_since)
    local final_hidden = first.hidden_since

    manager.instances_by_id[first.id] = nil
    emit({ instance_id = first.id, bufnr = first.bufnr, visible = true })
    assert.are.equal(final_hidden, first.hidden_since)
    manager.instances_by_id[first.id] = first

    first.is_destroying = function() return true end
    first.hidden_since = nil
    emit({ instance_id = first.id, bufnr = first.bufnr, visible = false })
    assert.is_nil(first.hidden_since)

    manager:remove(first)
    manager:remove(second)
    vim.api.nvim_buf_delete(first_buf, { force = true })
    vim.api.nvim_buf_delete(second_buf, { force = true })
  end)

end)
