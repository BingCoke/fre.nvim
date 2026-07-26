local path = require("fre.path")

local M = {}

local function split(relative)
  local result = {}
  for component in relative:gmatch("[^/]+") do
    result[#result + 1] = component
  end
  return result
end

local function sorted_children(node)
  local names = {}
  for name in pairs(node.children or {}) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function new_trie_node(desired)
  return {
    desired = desired,
    children = {},
    status = "pending",
  }
end

local function child_for(children, component, windows)
  local child = children[component]
  if child or not windows then return child, component end
  for name, candidate in pairs(children) do
    if name:lower() == component:lower() then return candidate, name end
  end
  return nil, component
end

local function insert(root, relative, desired, windows)
  local current = root
  for _, component in ipairs(split(relative)) do
    local child, key = child_for(current.children, component, windows)
    if not child then
      child = new_trie_node(nil)
      current.children[key] = child
    end
    current = child
  end
  current.desired = desired
end

function M.snapshot(predecessor)
  if type(predecessor) ~= "table" or type(predecessor.root) ~= "string"
      or type(predecessor.root_node) ~= "table" then
    return nil
  end

  local states = {}
  local function visit(node)
    if type(node) ~= "table" or node.kind ~= "directory" then return false end
    local descendant_expanded = false
    if node.children_cached or node.loaded then
      for _, child in ipairs(node.children_order or {}) do
        if visit(child) then descendant_expanded = true end
      end
    end
    local expanded = node.expanded == true
    if node ~= predecessor.root_node and (expanded or descendant_expanded) then
      states[#states + 1] = { path = tostring(node.path), expanded = expanded }
    end
    return expanded or descendant_expanded
  end
  visit(predecessor.root_node)
  table.sort(states, function(left, right) return left.path < right.path end)

  return {
    root = tostring(predecessor.root),
    states = states,
  }
end

function M.compile(snapshot, new_root)
  local trie = new_trie_node(true)
  trie.status = "done"
  if type(snapshot) ~= "table" or type(snapshot.root) ~= "string"
      or type(snapshot.states) ~= "table" then
    return trie
  end

  local windows = path.is_windows(snapshot.root) or path.is_windows(new_root)
  trie.windows = windows
  local old_root = path.normalize(snapshot.root, { windows = windows })
  new_root = path.normalize(new_root, { windows = windows })

  if path.contains(old_root, new_root) then
    for _, state in ipairs(snapshot.states) do
      if path.contains(new_root, state.path) then
        local relative = path.relative(new_root, state.path)
        if relative and relative ~= "" then
          insert(trie, relative, state.expanded == true, windows)
        end
      end
    end
  elseif path.contains(new_root, old_root) then
    local connector = path.relative(new_root, old_root)
    local components = split(connector or "")
    for index = 1, #components do
      insert(trie, table.concat(vim.list_slice(components, 1, index), "/"), true, windows)
    end
    for _, state in ipairs(snapshot.states) do
      local relative = path.relative(new_root, state.path)
      if relative and relative ~= "" then insert(trie, relative, state.expanded == true, windows) end
    end
  end

  return trie
end

local function find_trie_node(trie, relative)
  local current = trie
  for _, component in ipairs(split(relative)) do
    current = child_for(current.children, component, trie.windows)
    if not current then return nil end
  end
  return current
end

local function missing_error(err)
  if type(err) == "table" then
    local code = tostring(err.code or err.name or ""):upper()
    if code == "ENOENT" or code == "ENOTDIR" then return true end
  end
  local message = tostring(err):lower()
  return message:find("enoent", 1, true) ~= nil
    or message:find("enotdir", 1, true) ~= nil
    or message:find("no such file", 1, true) ~= nil
    or message:find("not a directory", 1, true) ~= nil
end

local drive_children

local function drop(node)
  node.status = "dropped"
  node.children = {}
end

local function render_expansion(instance, node)
  if node.expanded then return true end
  node.expanded = true
  local ok, err = pcall(instance._render_success, instance)
  if not ok then
    node.expanded = false
    instance:_projection()
    instance:_report_async_error(err)
    return false
  end
  instance:_sync_watchers()
  return true
end

local function drive_child(instance, parent, name, pending)
  if pending.status == "loading" or pending.status == "dropped"
      or pending.status == "dormant" then
    return
  end

  local node = instance.tree:find_child(parent, name)
  if not node or node.kind ~= "directory" then
    drop(pending)
    return
  end
  if pending.status == "done" then
    if node.expanded and node.loaded then drive_children(instance, node, pending) end
    return
  end
  if pending.desired == false then
    pending.status = "dormant"
    return
  end
  if pending.desired == nil then
    drop(pending)
    return
  end
  if not render_expansion(instance, node) then
    drop(pending)
    return
  end

  pending.status = "loading"
  instance:_ensure_directory_loaded(node, function(err)
    if pending.status ~= "loading" or instance._destroyed
        or instance.nodes_by_id[node.id] ~= node or not node.expanded then
      return
    end
    if err then
      drop(pending)
      if not missing_error(err) then
        instance:_report_async_error("inherited expansion failed for " .. node.path .. ": " .. tostring(err))
      end
      return
    end
    pending.status = "done"
    drive_children(instance, node, pending)
  end)
end

drive_children = function(instance, parent, pending)
  if instance._destroyed or not parent.expanded then return end
  for _, name in ipairs(sorted_children(pending)) do
    drive_child(instance, parent, name, pending.children[name])
  end
end

function M.start(instance)
  local trie = instance._inheritance_trie
  if not trie or trie.started or instance._destroyed then return end
  trie.started = true
  drive_children(instance, instance.root_node, trie)
end

local function reactivate(node)
  if node.status == "dormant" then node.status = "pending" end
  for _, child in pairs(node.children) do reactivate(child) end
end

function M.resume(instance, relative)
  local trie = instance._inheritance_trie
  if not trie or instance._destroyed then return end
  local pending = find_trie_node(trie, relative)
  local node = instance:_cached_node(relative)
  if not pending or pending.status == "dropped" or not node or node.kind ~= "directory"
      or not node.expanded or not node.loaded then
    return
  end
  pending.status = "done"
  for _, child in pairs(pending.children) do reactivate(child) end
  drive_children(instance, node, pending)
end

local function make_dormant(node)
  if node.status ~= "done" and node.status ~= "dropped" then node.status = "dormant" end
  for _, child in pairs(node.children) do make_dormant(child) end
end

function M.collapse(instance, relative)
  local trie = instance._inheritance_trie
  if not trie then return end
  local pending = find_trie_node(trie, relative)
  if not pending then return end
  for _, child in pairs(pending.children) do make_dormant(child) end
  if pending.status ~= "done" and pending.status ~= "dropped" then pending.status = "dormant" end
end

return M
