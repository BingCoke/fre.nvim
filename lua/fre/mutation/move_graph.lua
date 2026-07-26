local path = require("fre.path")

local M = {}

local function sorted_dependencies(action)
  local dependencies = {}
  for dependency in pairs(action.dependencies) do
    dependencies[#dependencies + 1] = dependency
  end
  table.sort(dependencies, function(left, right) return left.sequence < right.sequence end)
  return dependencies
end

local function components_for(actions)
  local index = 0
  local stack, on_stack = {}, {}
  local indexes, lowlinks = {}, {}
  local components = {}

  local function visit(action)
    index = index + 1
    indexes[action] = index
    lowlinks[action] = index
    stack[#stack + 1] = action
    on_stack[action] = true

    for _, dependency in ipairs(sorted_dependencies(action)) do
      if indexes[dependency] == nil then
        visit(dependency)
        lowlinks[action] = math.min(lowlinks[action], lowlinks[dependency])
      elseif on_stack[dependency] then
        lowlinks[action] = math.min(lowlinks[action], indexes[dependency])
      end
    end

    if lowlinks[action] == indexes[action] then
      local component = { actions = {}, dependencies = {} }
      while true do
        local member = table.remove(stack)
        on_stack[member] = nil
        component.actions[#component.actions + 1] = member
        if member == action then break end
      end
      table.sort(component.actions, function(left, right) return left.sequence < right.sequence end)
      component.sequence = component.actions[1].sequence
      components[#components + 1] = component
    end
  end

  for _, action in ipairs(actions) do
    if indexes[action] == nil then visit(action) end
  end

  local component_by_action = {}
  for _, component in ipairs(components) do
    for _, action in ipairs(component.actions) do component_by_action[action] = component end
  end
  for _, component in ipairs(components) do
    for _, action in ipairs(component.actions) do
      for dependency in pairs(action.dependencies) do
        local dependency_component = component_by_action[dependency]
        if dependency_component ~= component then
          component.dependencies[dependency_component] = true
        end
      end
    end
  end
  return components
end

local function is_cyclic(component)
  if #component.actions > 1 then return true end
  local action = component.actions[1]
  return action.dependencies[action] == true
end

local function cycle_error(component, describe)
  local labels = {}
  for _, action in ipairs(component.actions) do labels[#labels + 1] = describe(action) end
  error("fre: move dependency cycle is unsupported: " .. table.concat(labels, ", "), 3)
end

local function validate_move_cycle(component, windows, describe)
  local members = {}
  for _, action in ipairs(component.actions) do members[action] = true end
  local incoming = {}

  for _, action in ipairs(component.actions) do
    if action.type ~= "move" then cycle_error(component, describe) end
    local occupancy_dependency
    local internal_count = 0
    for dependency in pairs(action.dependencies) do
      if members[dependency] then
        internal_count = internal_count + 1
        if not action.occupancy_dependencies[dependency]
            or action.non_occupancy_dependencies[dependency] then
          cycle_error(component, describe)
        end
        occupancy_dependency = dependency
      end
    end
    if internal_count ~= 1
        or not path.equal(action.to, occupancy_dependency.from, { windows = windows }) then
      cycle_error(component, describe)
    end
    if incoming[occupancy_dependency] ~= nil then cycle_error(component, describe) end
    incoming[occupancy_dependency] = action
  end

  for _, action in ipairs(component.actions) do
    if incoming[action] == nil then cycle_error(component, describe) end
  end
  if #component.actions == 1 then
    local action = component.actions[1]
    if action.from == action.to then cycle_error(component, describe) end
  end
  return incoming
end

local function lower_cycle(component, incoming, reserved, windows)
  local pivot = component.actions[1]
  local function occupied(candidate)
    for _, known in ipairs(reserved) do
      if path.equal(candidate, known, { windows = windows }) then return true end
    end
    return false
  end
  local temporary = path.temporary_sibling(
    pivot.from,
    occupied,
    "move-cycle-" .. tostring(pivot.sequence)
  )
  reserved[#reserved + 1] = temporary

  local lowered = {
    {
      type = "move", from = pivot.from, to = temporary, kind = pivot.kind,
      row = pivot.row, internal = true,
    },
  }
  local current = incoming[pivot]
  while current ~= pivot do
    lowered[#lowered + 1] = current
    current = incoming[current]
  end
  lowered[#lowered + 1] = {
    type = "move", from = temporary, to = pivot.to, kind = pivot.kind,
    row = pivot.row, internal = true,
  }
  return lowered
end

function M.order_and_lower(actions, opts)
  opts = opts or {}
  local windows = opts.windows == true
  local describe = opts.describe or function(action) return tostring(action.sequence) end
  local reserved = vim.list_slice(opts.reserved_paths or {})
  local components = components_for(actions)

  for _, component in ipairs(components) do
    if is_cyclic(component) then
      component.incoming = validate_move_cycle(component, windows, describe)
    end
  end

  local ordered, display = {}, {}
  local emitted = {}
  while true do
    local selected
    for _, component in ipairs(components) do
      if not emitted[component] then
        local ready = true
        for dependency in pairs(component.dependencies) do
          if not emitted[dependency] then ready = false; break end
        end
        if ready and (selected == nil or component.sequence < selected.sequence) then
          selected = component
        end
      end
    end
    if selected == nil then break end
    emitted[selected] = true

    if selected.incoming then
      local lowered = lower_cycle(selected, selected.incoming, reserved, windows)
      for _, action in ipairs(lowered) do ordered[#ordered + 1] = action end
    else
      ordered[#ordered + 1] = selected.actions[1]
    end
    for _, action in ipairs(selected.actions) do display[#display + 1] = action end
  end

  if #display ~= #actions then
    error("fre: move dependency graph could not be ordered", 3)
  end
  return ordered, display
end

return M
