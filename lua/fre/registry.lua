local Registry = {}
Registry.__index = Registry

local next_registry_id = 1

local function fail(message, level)
  error("fre.registry: " .. message, level or 3)
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

local function decimal_width(id)
  return #tostring(id)
end

-- Marker text omits registry_id, so each Registry needs a disjoint numeric ID sequence.
local function instance_id(registry_id, sequence)
  local registry_index = registry_id - 1
  local sequence_index = sequence - 1
  local sum = registry_index + sequence_index
  return sum * (sum + 1) / 2 + sequence_index + 1
end

local function report_event_error(err)
  pcall(vim.notify, "fre: Registry marker width event failed: " .. tostring(err), vim.log.levels.ERROR)
end

function Registry.new()
  local registry_id = next_registry_id
  next_registry_id = registry_id + 1
  return setmetatable({
    registry_id = registry_id,
    _next_instance_sequence = 1,
    _consumed_instance_ids = {},
    _marker_sources = {},
    _marker_widths = { instance = 3, node = 3, generation = 1 },
    _width_event_scheduled = false,
  }, Registry)
end

function Registry:_schedule_width_event()
  if self._width_event_scheduled then return end
  self._width_event_scheduled = true
  vim.schedule(function()
    self._width_event_scheduled = false
    local widths = self._marker_widths
    local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "FreRegistryMarkerWidthsChanged",
      modeline = false,
      data = {
        registry_id = self.registry_id,
        instance_width = widths.instance,
        node_width = widths.node,
        generation = widths.generation,
      },
    })
    if not ok then report_event_error(err) end
  end)
end

function Registry:_observe_marker_id(field, id)
  if type(id) ~= "number" or id < 0 or id % 1 ~= 0 then
    fail(field .. " marker ID must be a non-negative integer")
  end
  local width = math.max(3, decimal_width(id))
  if width <= self._marker_widths[field] then return false end
  self._marker_widths[field] = width
  self._marker_widths.generation = self._marker_widths.generation + 1
  self:_schedule_width_event()
  return true
end

function Registry:allocate_instance_id()
  local sequence = self._next_instance_sequence
  self._next_instance_sequence = sequence + 1
  local id = instance_id(self.registry_id, sequence)
  self._consumed_instance_ids[id] = true
  self:_observe_marker_id("instance", id)
  return id
end

function Registry:is_instance_id_consumed(id)
  return self._consumed_instance_ids[id] == true
end

function Registry:observe_node_id(id)
  return self:_observe_marker_id("node", id)
end

function Registry:marker_widths()
  return {
    instance = self._marker_widths.instance,
    node = self._marker_widths.node,
    generation = self._marker_widths.generation,
  }
end

function Registry:register_marker_source(instance_id, source)
  if not positive_integer(instance_id) or not self._consumed_instance_ids[instance_id] then
    fail("instance ID was not allocated by this Registry")
  end
  if type(source) ~= "table" then fail("marker source must be a table") end
  if self._marker_sources[instance_id] ~= nil then
    fail("marker source is already registered: " .. tostring(instance_id))
  end
  self._marker_sources[instance_id] = source
  return source
end

function Registry:remove_marker_source(instance_id, source)
  local current = self._marker_sources[instance_id]
  if current == nil or source ~= nil and current ~= source then return nil end
  self._marker_sources[instance_id] = nil
  return current
end

function Registry:find_marker_source(instance_id)
  return self._marker_sources[instance_id]
end

local M = {
  new = Registry.new,
}
M.default = Registry.new()

return M
