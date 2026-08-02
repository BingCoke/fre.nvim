local manager_module = require("fre.manager")
local Registry = require("fre.registry")
local fs = require("tests.helpers.fs")

local fixture
local instances = {}
local event_group = "FreRegistrySpec"

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(1500, predicate, 10))
end

local function ready(manager, registry)
  fixture:write("alpha.txt", "alpha")
  local instance = keep(manager:create_instance({ root = fixture.root, columns = {} }))
  wait_for(function() return instance:is_ready() end)
  assert.are.equal(registry, manager._registry)
  return instance
end

local function entry_line(instance, relative_path)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = instance.buffer:decode(row)
    if decoded and decoded.entry and decoded.entry.relative_path == relative_path then
      return vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1]
    end
  end
  error("missing row for " .. relative_path)
end

local function append_line(instance, line)
  local row = vim.api.nvim_buf_line_count(instance.bufnr) + 1
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, -1, -1, false, { line })
  vim.bo[instance.bufnr].modifiable = modifiable
  return row
end

describe("fre Registry marker identity", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    vim.api.nvim_create_augroup(event_group, { clear = true })
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if not instance:is_destroyed() then instance:destroy() end
    end
    pcall(vim.api.nvim_del_augroup_by_name, event_group)
    fixture:cleanup()
  end)

  it("owns permanent process identity with isolated live sources", function()
    local first = Registry.new()
    local second = Registry.new()
    local first_id = first:allocate_instance_id()
    local second_id = second:allocate_instance_id()
    local source = { id = first_id }
    local second_widths = second:marker_widths()

    assert.is_true(first_id > 0)
    assert.is_true(second_id > first_id)
    assert.is_true(first:is_instance_id_consumed(first_id))
    assert.is_false(second:is_instance_id_consumed(first_id))
    assert.are_not.equal(first.registry_id, second.registry_id)

    first:register_marker_source(first_id, source)
    assert.are.equal(source, first:find_marker_source(first_id))
    assert.is_nil(second:find_marker_source(first_id))
    assert.are.equal(source, first:remove_marker_source(first_id, source))
    assert.is_nil(first:find_marker_source(first_id))
    assert.is_true(first:allocate_instance_id() > second_id)
    first:observe_node_id(1000)
    assert.are.same(second_widths, second:marker_widths())
    wait_for(function() return not first._width_event_scheduled end)
  end)

  it("provides the process default and explicit shared Registry composition", function()
    local default_manager = manager_module.new()
    local shared = Registry.new()
    local left = manager_module.new({ registry = shared })
    local right = manager_module.new({ registry = shared })

    assert.are.equal(Registry.default, default_manager._registry)
    assert.are.equal(shared, left._registry)
    assert.are.equal(shared, right._registry)
    assert.is_nil(left._next_id)
    assert.is_nil(left._consumed_ids)
    assert.is_nil(left._marker_widths)
    assert.is_nil(left.allocate_id)
    assert.is_nil(left.observe_node_id)
    assert.is_nil(left.get_marker_widths)
  end)

  it("publishes latest serializable marker widths once per turn", function()
    local registry = Registry.new()
    local events = {}
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreRegistryMarkerWidthsChanged",
      callback = function(args) events[#events + 1] = args.data end,
    })

    registry:observe_node_id(1000)
    registry:observe_node_id(10000)
    local committed = registry:marker_widths()

    assert.are.equal(0, #events)
    assert.are.equal(5, committed.node)
    assert.are.equal(3, committed.generation)
    wait_for(function() return #events == 1 end)
    assert.are.same({
      registry_id = registry.registry_id,
      instance_width = committed.instance,
      node_width = committed.node,
      generation = committed.generation,
    }, events[1])
    assert.is_string(vim.json.encode(events[1]))
  end)

  it("keeps committed widths when a Registry event observer throws", function()
    local registry = Registry.new()
    vim.v.errmsg = ""
    vim.api.nvim_create_autocmd("User", {
      group = event_group,
      pattern = "FreRegistryMarkerWidthsChanged",
      callback = function() error("injected Registry observer failure") end,
    })

    registry:observe_node_id(1000)
    local committed = registry:marker_widths()
    wait_for(function()
      return tostring(vim.v.errmsg):find("injected Registry observer failure", 1, true) ~= nil
    end)

    assert.are.equal(4, committed.node)
    assert.are.equal(2, committed.generation)
  end)

  it("registers a narrow Buffer source and removes it on destruction", function()
    local registry = Registry.new()
    local manager = manager_module.new({ registry = registry })
    local instance = ready(manager, registry)
    local source = registry:find_marker_source(instance.id)

    assert.is_table(source)
    assert.are_not.equal(instance.buffer, source)
    assert.are.equal(instance.id, source.id)
    assert.are.equal(instance.root, source.root)
    assert.is_table(source.tree)
    assert.is_nil(source.render)
    assert.is_nil(source.request_write)

    instance:destroy()
    assert.is_nil(registry:find_marker_source(instance.id))
  end)

  it("shares marker sources across explicit Managers independently of managed indexes", function()
    local registry = Registry.new()
    local source_manager = manager_module.new({ registry = registry })
    local target_manager = manager_module.new({ registry = registry })
    local source = ready(source_manager, registry)
    local target = ready(target_manager, registry)
    local target_row = append_line(target, entry_line(source, "alpha.txt"))

    assert.are.equal(source.id, target.buffer:decode(target_row).source_instance_id)
    source_manager:remove(source)
    assert.are.equal(source.id, target.buffer:decode(target_row).source_instance_id)

    source.buffer:teardown()
    local ok, err = pcall(target.buffer.decode, target.buffer, target_row)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("row " .. target_row .. ":", 1, true))
    assert.is_truthy(tostring(err):find("unknown instance", 1, true))
  end)

  it("rejects copied rows between explicitly isolated Registries", function()
    local source_registry = Registry.new()
    local target_registry = Registry.new()
    local source = ready(manager_module.new({ registry = source_registry }), source_registry)
    local target = ready(manager_module.new({ registry = target_registry }), target_registry)
    local target_row = append_line(target, entry_line(source, "alpha.txt"))

    local ok, err = pcall(target.buffer.decode, target.buffer, target_row)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("row " .. target_row .. ":", 1, true))
    assert.is_truthy(tostring(err):find("unknown instance", 1, true))
  end)

  it("filters foreign and stale width events before reprojecting a live Buffer", function()
    local registry = Registry.new()
    local manager = manager_module.new({ registry = registry })
    local instance = ready(manager, registry)
    local renders = 0
    local original_render = instance.buffer.render
    instance.buffer.render = function(target, ...)
      renders = renders + 1
      return original_render(target, ...)
    end
    local current = registry:marker_widths()

    vim.api.nvim_exec_autocmds("User", {
      pattern = "FreRegistryMarkerWidthsChanged",
      modeline = false,
      data = {
        registry_id = registry.registry_id + 1,
        instance_width = current.instance,
        node_width = current.node + 1,
        generation = current.generation + 100,
      },
    })
    vim.api.nvim_exec_autocmds("User", {
      pattern = "FreRegistryMarkerWidthsChanged",
      modeline = false,
      data = {
        registry_id = registry.registry_id,
        instance_width = current.instance,
        node_width = current.node,
        generation = current.generation,
      },
    })
    assert.are.equal(0, renders)

    registry:observe_node_id(10 ^ current.node)
    wait_for(function() return renders == 1 end)
    local grown = registry:marker_widths()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "FreRegistryMarkerWidthsChanged",
      modeline = false,
      data = {
        registry_id = registry.registry_id,
        instance_width = grown.instance,
        node_width = grown.node,
        generation = grown.generation,
      },
    })
    assert.are.equal(1, renders)
  end)
end)
