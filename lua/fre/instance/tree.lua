local path = require("fre.path")

local Tree = {}
Tree.__index = Tree

local function directory_state(node)
  if node.kind ~= "directory" then
    return
  end
  node.children_by_name = node.children_by_name or {}
  node.children_order = node.children_order or {}
  node.load_state = node.load_state or "unloaded"
  node.loaded = node.load_state == "loaded"
  node.children_cached = node.loaded
  if node.expanded == nil then node.expanded = false end
  node.load_generation = node.load_generation or 0
end

local function metadata(entry)
  local stat = entry.stat or {}
  return {
    stat = entry.stat,
    link = entry.link,
    real_path = entry.real_path,
    mode = stat.mode or entry.mode or 0,
    mtime = stat.mtime or entry.mtime or { sec = 0, nsec = 0 },
  }
end

local function detached_copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    result[detached_copy(key, seen)] = detached_copy(item, seen)
  end
  return result
end

function Tree.new(root_path, instance_id, comparator)
  local self = setmetatable({
    root_path = root_path,
    instance_id = instance_id,
    comparator = comparator,
    id_state = { latest = 1 },
    nodes_by_id = {},
    nodes_by_path = {},
  }, Tree)
  local root = {
    id = 1,
    name = "",
    path = root_path,
    kind = "directory",
    parent = nil,
    parent_id = nil,
    expanded = true,
    load_generation = 0,
    load_state = "unloaded",
    loaded = false,
    children_cached = false,
    children_by_name = {},
    children_order = {},
  }
  self.root = root
  self.nodes_by_id[root.id] = root
  self.nodes_by_path[root.path] = root
  return self
end

function Tree:entry(node)
  local relative_path = ""
  if node ~= self.root then
    relative_path = assert(path.relative(self.root_path, node.path))
  end
  return {
    instance_id = self.instance_id,
    node_id = node.id,
    absolute_path = node.path,
    relative_path = relative_path,
    name = node.name,
    kind = node.kind,
  }
end

function Tree:set_comparator(comparator)
  self.comparator = comparator
end

function Tree:get_comparator()
  return self.comparator
end

function Tree:latest_node_id()
  return self.id_state.latest
end

function Tree:root_node()
  return self.root
end

function Tree:node_by_id(id)
  return self.nodes_by_id[id]
end

function Tree:node_by_path(node_path)
  return self.nodes_by_path[node_path]
end

function Tree:contains(node)
  return node ~= nil and self.nodes_by_id[node.id] == node
end

function Tree:iter_nodes()
  return pairs(self.nodes_by_id)
end

function Tree:begin_load(node, state)
  state = state or "loading"
  node.load_generation = (node.load_generation or 0) + 1
  node.load_state = state
  if state == "loading" then
    node.loaded = false
    node.children_cached = false
  end
  return node.load_generation
end

function Tree:is_current_load(node, generation, state)
  return self:contains(node) and node.load_generation == generation
    and (state == nil or node.load_state == state)
end

function Tree:mark_unloaded(node)
  node.load_state = "unloaded"
  node.loaded = false
  node.children_cached = false
end

function Tree:mark_loaded(node)
  node.load_state = "loaded"
  node.loaded = true
  node.children_cached = true
end

function Tree:set_expanded(node, expanded)
  node.expanded = expanded
end

function Tree:collapse_all()
  local changed = false
  for _, node in self:iter_nodes() do
    if node ~= self.root and node.kind == "directory" and node.expanded then
      node.expanded = false
      changed = true
    end
  end
  return changed
end

function Tree:invalidate_loads(node)
  if node.kind == "directory" then
    local preserved = node.loaded or node.children_cached
    node.load_generation = (node.load_generation or 0) + 1
    node._load_waiters = {}
    node._rescan_waiters = {}
    node.load_state = preserved and "loaded" or "unloaded"
    node.loaded = preserved
    node.children_cached = preserved
  end
  for _, child in ipairs(node.children_order or {}) do
    self:invalidate_loads(child)
  end
end

function Tree:is_active_directory(node)
  if node == self.root then return true end
  local current = node
  while current and current ~= self.root do
    if current.kind ~= "directory" or not current.expanded then return false end
    current = current.parent
  end
  return current == self.root
end

function Tree:active_directories()
  local result = { self.root }
  local function visit(parent)
    for _, node in ipairs(parent.children_order or {}) do
      if node.kind == "directory" and node.expanded then
        result[#result + 1] = node
        if node.children_cached then visit(node) end
      end
    end
  end
  visit(self.root)
  return result
end

function Tree:active_expanded_paths()
  local result = {}
  for index, node in ipairs(self:active_directories()) do
    if index > 1 then result[#result + 1] = node.path end
  end
  return result
end

function Tree.clone(source)
  local self = setmetatable({
    root_path = source.root_path,
    instance_id = source.instance_id,
    comparator = source.comparator,
    id_state = source.id_state,
    nodes_by_id = {},
    nodes_by_path = {},
  }, Tree)

  local function clone_node(node, parent)
    local result = {
      id = node.id,
      name = node.name,
      path = node.path,
      kind = node.kind,
      parent = parent,
      parent_id = parent and parent.id or nil,
      stat = detached_copy(node.stat),
      link = detached_copy(node.link),
      real_path = node.real_path,
      mode = node.mode,
      mtime = detached_copy(node.mtime),
      expanded = node.expanded,
      load_generation = node.load_generation or 0,
    }
    self.nodes_by_id[result.id] = result
    self.nodes_by_path[result.path] = result
    if result.kind == "directory" then
      result.load_state = node.load_state
      result.loaded = node.loaded
      result.children_cached = node.children_cached
      result.children_by_name = {}
      result.children_order = {}
      for _, child in ipairs(node.children_order or {}) do
        local cloned_child = clone_node(child, result)
        result.children_by_name[cloned_child.name] = cloned_child
        result.children_order[#result.children_order + 1] = cloned_child
      end
    end
    return result
  end

  self.root = clone_node(source.root, nil)
  return self
end

function Tree:_allocate_id()
  self.id_state.latest = self.id_state.latest + 1
  local id = self.id_state.latest
  return id
end

function Tree:_new_node(parent, entry)
  local info = metadata(entry)
  local node = {
    id = self:_allocate_id(),
    name = entry.name,
    path = path.resolve(parent.path, entry.name),
    kind = entry.kind,
    parent = parent,
    parent_id = parent.id,
    stat = info.stat,
    link = info.link,
    real_path = info.real_path,
    mode = info.mode,
    mtime = info.mtime,
    expanded = false,
    load_generation = 0,
  }
  directory_state(node)
  return node
end

function Tree:_detach(node)
  if node.kind == "directory" then
    for _, child in ipairs(node.children_order or {}) do
      self:_detach(child)
    end
  end
  self.nodes_by_id[node.id] = nil
  if self.nodes_by_path[node.path] == node then
    self.nodes_by_path[node.path] = nil
  end
end

function Tree:_register(node)
  self.nodes_by_id[node.id] = node
  self.nodes_by_path[node.path] = node
end

local function shallow_copy(source)
  local result = {}
  for key, value in pairs(source) do result[key] = value end
  return result
end

function Tree:snapshot_directory(parent)
  local child_metadata = {}
  for _, child in pairs(parent.children_by_name or {}) do
    child_metadata[child] = {
      stat = child.stat, link = child.link, real_path = child.real_path,
      mode = child.mode, mtime = child.mtime,
    }
  end
  return {
    children_by_name = parent.children_by_name,
    children_order = parent.children_order,
    load_state = parent.load_state,
    loaded = parent.loaded,
    children_cached = parent.children_cached,
    real_path = parent.real_path,
    nodes_by_id = shallow_copy(self.nodes_by_id),
    nodes_by_path = shallow_copy(self.nodes_by_path),
    child_metadata = child_metadata,
  }
end

function Tree:restore_directory(parent, snapshot)
  self.nodes_by_id = snapshot.nodes_by_id
  self.nodes_by_path = snapshot.nodes_by_path
  for child, info in pairs(snapshot.child_metadata) do
    child.stat = info.stat
    child.link = info.link
    child.real_path = info.real_path
    child.mode = info.mode
    child.mtime = info.mtime
  end
  parent.children_by_name = snapshot.children_by_name
  parent.children_order = snapshot.children_order
  parent.load_state = snapshot.load_state
  parent.loaded = snapshot.loaded
  parent.children_cached = snapshot.children_cached
  parent.real_path = snapshot.real_path
end

function Tree:adopt(source)
  self.root = source.root
  self.root_path = source.root_path
  self.comparator = source.comparator
  self.nodes_by_id = source.nodes_by_id
  self.nodes_by_path = source.nodes_by_path
end

function Tree:reconcile(parent, entries)
  directory_state(parent)
  local previous = parent.children_by_name
  local ordered = {}
  local by_name = {}
  local updates = {}
  local reused = {}

  for _, entry in ipairs(entries or {}) do
    if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then
      error("fre: directory adapter returned an invalid entry", 0)
    end
    if entry.name:find("[\r\n]") then
      error("fre: unsupported entry name " .. entry.name .. ": contains CR or LF", 0)
    end
    if type(entry.kind) ~= "string" or entry.kind == "" then
      error("fre: directory adapter returned an invalid kind for " .. entry.name, 0)
    end
    if by_name[entry.name] then
      error("fre: directory adapter returned duplicate entry " .. entry.name, 0)
    end
    local old = previous[entry.name]
    local node
    if old and old.kind == entry.kind then
      node = old
      reused[node] = true
      updates[node] = metadata(entry)
    else
      node = self:_new_node(parent, entry)
    end
    by_name[entry.name] = node
    ordered[#ordered + 1] = node
  end

  table.sort(ordered, function(a, b)
    return self.comparator(self:entry(parent), self:entry(a), self:entry(b))
  end)

  for _, old in pairs(previous) do
    if not reused[old] then self:_detach(old) end
  end
  for node, info in pairs(updates) do
    node.stat = info.stat
    node.link = info.link
    node.real_path = info.real_path
    node.mode = info.mode
    node.mtime = info.mtime
  end
  for _, node in ipairs(ordered) do
    if self.nodes_by_id[node.id] == nil then self:_register(node) end
  end

  parent.children_by_name = by_name
  parent.children_order = ordered
  parent.load_state = "loaded"
  parent.loaded = true
  parent.children_cached = true
  return ordered
end

function Tree:sort_cached()
  local function visit(parent)
    if parent.loaded then
      table.sort(parent.children_order, function(a, b)
        return self.comparator(self:entry(parent), self:entry(a), self:entry(b))
      end)
    end
    for _, child in ipairs(parent.children_order or {}) do
      if child.kind == "directory" and child.children_cached then visit(child) end
    end
  end
  visit(self.root)
end

function Tree:find_child(parent, name)
  local direct = parent.children_by_name and parent.children_by_name[name]
  if direct then return direct end
  if path.is_windows(self.root_path) then
    for child_name, child in pairs(parent.children_by_name or {}) do
      if child_name:lower() == name:lower() then return child end
    end
  end
  return nil
end

function Tree:project(include_node)
  local nodes = {}
  local ranges = {}
  local function visit(node)
    if include_node and not include_node(node) then return end
    local first = #nodes + 1
    nodes[first] = node
    if node.kind == "directory" and node.expanded and node.loaded then
      for _, child in ipairs(node.children_order or {}) do visit(child) end
    end
    local last = #nodes
    ranges[node.id] = { start_row = first, end_row = last, size = last - first + 1 }
  end
  for _, child in ipairs(self.root.children_order or {}) do visit(child) end
  ranges[self.root.id] = {
    start_row = #nodes > 0 and 1 or nil,
    end_row = #nodes > 0 and #nodes or nil,
    size = #nodes,
  }
  return { nodes = nodes, ranges = ranges, size = #nodes }
end

return Tree
