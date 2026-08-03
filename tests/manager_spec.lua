local manager_module = require("fre.manager")

local next_id = 1

local function instance(bufnr)
  local id = "manager-test-" .. tostring(next_id)
  next_id = next_id + 1
  local state = "ready"
  return {
    id = id,
    bufnr = bufnr,
    is_ready = function() return state == "ready" end,
    is_destroyed = function() return state == "destroyed" end,
    is_destroying = function() return state == "destroying" end,
    status = function() return state end,
    set_state = function(_, value) state = value end,
    sync_view = function() end,
    destroy = function(self)
      state = "destroyed"
      vim.api.nvim_exec_autocmds("User", {
        pattern = "FreInstanceDestroyed",
        modeline = false,
        data = { instance_id = self.id, bufnr = self.bufnr },
      })
    end,
  }
end

local function resolved(manager, gc_options)
  local core, policy = manager:resolve_instance_config({ gc = gc_options or {} })
  return core, policy
end

local function register(manager, subject, gc_options)
  local _, policy = resolved(manager, gc_options)
  return manager:register(subject, policy)
end

local function emit(pattern, data)
  vim.api.nvim_exec_autocmds("User", {
    pattern = pattern,
    modeline = false,
    data = data,
  })
end

describe("fre manager", function()
  it("resolves core configuration separately from GC enrollment policy", function()
    local manager = manager_module.new()
    manager:setup({
      hidden_file = true,
      gc = { ttl_ms = 75, include_modified = true, default_group = "project" },
    })

    local core, policy = manager:resolve_instance_config({
      hidden_file = false,
      gc = { ttl_ms = 25, include_modified = false, group = "default" },
    })

    assert.is_false(core.hidden_file)
    assert.is_nil(core.gc)
    assert.are.same({ ttl_ms = 25, include_modified = false, group = "default" }, policy)
  end)

  it("validates GC policy before core construction", function()
    local manager = manager_module.new()
    local constructed = false
    local real_new = require("fre.instance").new
    require("fre.instance").new = function(...)
      constructed = true
      return real_new(...)
    end

    local ok, err = pcall(manager.create_instance, manager, {
      root = ".",
      gc = { group = "missing" },
    })
    require("fre.instance").new = real_new

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("unknown group", 1, true))
    assert.is_false(constructed)
  end)

  it("rejects caller IDs and duplicate live opaque registration", function()
    local manager = manager_module.new()
    local ok, err = pcall(manager.create_instance, manager, {
      root = ".", id = "caller-selected",
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("do not accept id", 1, true))

    local first_buf = vim.api.nvim_create_buf(false, true)
    local second_buf = vim.api.nvim_create_buf(false, true)
    local first = instance(first_buf)
    local second = instance(second_buf)
    second.id = first.id
    register(manager, first)
    local duplicate_ok, duplicate_err = pcall(register, manager, second)
    assert.is_false(duplicate_ok)
    assert.is_truthy(tostring(duplicate_err):find("already registered", 1, true))
    assert.are.equal(first, manager:find_by_id(first.id))
    assert.are.equal(first, manager:find_by_buf(first.bufnr))
    assert.is_nil(manager:find_by_buf(second.bufnr))
    assert.is_nil(manager:get_gc_controller():inspect(second))

    assert.is_nil(manager:remove(first))
    assert.are.equal(first, manager:find_by_id(first.id))
    assert.are.equal(first, manager:find_by_buf(first.bufnr))
    assert.is_not_nil(manager:get_gc_controller():inspect(first))
    first:destroy()
    assert.is_nil(manager:find_by_id(first.id))
    assert.is_nil(manager:find_by_buf(first.bufnr))
    assert.is_nil(manager:get_gc_controller():inspect(first))
    vim.api.nvim_buf_delete(first_buf, { force = true })
    vim.api.nvim_buf_delete(second_buf, { force = true })
  end)

  it("keeps group definitions and membership exclusively in GC", function()
    local manager = manager_module.new()
    local first_buf = vim.api.nvim_create_buf(false, true)
    local second_buf = vim.api.nvim_create_buf(false, true)
    local first = instance(first_buf)
    local second = instance(second_buf)
    register(manager, first)
    register(manager, second, { group = "project" })

    assert.is_nil(manager.groups)
    assert.are.equal(first, manager:find_by_group("default")[first.id])
    assert.are.equal(second, manager:find_by_group("project")[second.id])
    assert.are.equal(10, manager:get_gc_controller():group_capacity("default"))
    assert.are.equal(5, manager:get_gc_controller():group_capacity("project"))

    first:destroy()
    second:destroy()
    vim.api.nvim_buf_delete(first_buf, { force = true })
    vim.api.nvim_buf_delete(second_buf, { force = true })
  end)

  it("records complete snapshotted enrollment policy without Instance or buffer mirrors", function()
    local manager = manager_module.new()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.b[bufnr].fre = { version = 1, instance_id = "metadata-subject", root = "." }
    local subject = instance(bufnr)
    register(manager, subject, { ttl_ms = 42, include_modified = true, group = "project" })

    local entry = assert(manager:get_gc_controller():inspect(subject))
    assert.are.same({
      instance_id = subject.id,
      bufnr = bufnr,
      group = "project",
      ttl_ms = 42,
      include_modified = true,
      hidden = true,
      eligible = true,
    }, entry)
    assert.is_nil(subject.config)
    assert.is_nil(subject.hidden_since)
    assert.is_nil(subject._gc_timer)
    assert.is_nil(vim.b[bufnr].fre.gc_group)

    subject:destroy()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("filters lifecycle, presentation, and activity facts by both live indexes", function()
    local manager = manager_module.new()
    manager:setup({ gc = { ttl_ms = 0, groups = { default = 0, project = 0 } } })
    local first_buf = vim.api.nvim_create_buf(false, true)
    local second_buf = vim.api.nvim_create_buf(false, true)
    local first = instance(first_buf)
    local second = instance(second_buf)
    register(manager, first)
    register(manager, second)

    local initial = manager:get_gc_controller():inspect(first)
    emit("FreInstancePresentationChanged", {
      instance_id = first.id, bufnr = second.bufnr, visible = true,
    })
    emit("FreInstanceActivityChanged", {
      instance_id = first.id .. "-other", bufnr = first.bufnr,
      activity = "write", active = true,
    })
    emit("FreReady", {
      instance_id = first.id, bufnr = first.bufnr + 10000,
      error = nil, result = {},
    })
    assert.are.same(initial, manager:get_gc_controller():inspect(first))

    emit("FreInstancePresentationChanged", {
      instance_id = first.id, bufnr = first.bufnr, visible = true,
    })
    assert.is_false(manager:get_gc_controller():inspect(first).hidden)
    emit("FreInstanceActivityChanged", {
      instance_id = first.id, bufnr = first.bufnr,
      activity = "write", active = true,
    })
    assert.is_false(manager:get_gc_controller():inspect(first).eligible)
    emit("FreInstanceActivityChanged", {
      instance_id = first.id, bufnr = first.bufnr,
      activity = "write", active = false,
    })
    emit("FreInstancePresentationChanged", {
      instance_id = first.id, bufnr = first.bufnr, visible = false,
    })
    assert.is_true(manager:get_gc_controller():inspect(first).hidden)

    first:set_state("destroying")
    emit("FreInstanceDestroying", { instance_id = first.id, bufnr = first.bufnr })
    assert.is_false(manager:get_gc_controller():inspect(first).eligible)
    first:set_state("destroyed")
    emit("FreInstanceDestroyed", { instance_id = first.id, bufnr = first.bufnr })
    assert.is_nil(manager:find_by_id(first.id))
    assert.is_nil(manager:find_by_buf(first.bufnr))
    assert.is_nil(manager:get_gc_controller():inspect(first))

    emit("FreReady", { instance_id = first.id, bufnr = first.bufnr, result = {} })
    emit("FreInstancePresentationChanged", {
      instance_id = first.id, bufnr = first.bufnr, visible = true,
    })
    emit("FreInstanceActivityChanged", {
      instance_id = first.id, bufnr = first.bufnr, activity = "write", active = false,
    })
    emit("FreInstanceDestroyed", { instance_id = first.id, bufnr = first.bufnr })
    assert.are.equal(second, manager:find_by_id(second.id))
    assert.is_not_nil(manager:get_gc_controller():inspect(second))

    second:destroy()
    vim.api.nvim_buf_delete(first_buf, { force = true })
    vim.api.nvim_buf_delete(second_buf, { force = true })
  end)
end)
