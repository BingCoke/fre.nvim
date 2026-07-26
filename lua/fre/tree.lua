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

function Tree.new(instance, root_path)
  local self = setmetatable({ instance = instance }, Tree)
  local root = {
    id = 1,
    name = "",
    path = root_path,
    kind = "directory",
    parent = nil,
    parent_id = nil,
    expanded = true,
    visible_size = 0,
    visible_start = nil,
    visible_end = nil,
    visible_range = nil,
    load_generation = 0,
    load_state = "unloaded",
    loaded = false,
    children_cached = false,
    children_by_name = {},
    children_order = {},
  }
  self.root = root
  instance._next_node_id = 1
  instance.root_node = root
  instance.nodes_by_id = { [root.id] = root }
  instance.nodes_by_path = { [root.path] = root }
  return self
end

function Tree.clone(source, instance)
  local self = setmetatable({ instance = instance }, Tree)
  instance.nodes_by_id = {}
  instance.nodes_by_path = {}

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
      visible_size = 0,
      visible_start = nil,
      visible_end = nil,
      visible_range = nil,
      row_extmark = nil,
      load_generation = node.load_generation or 0,
    }
    instance.nodes_by_id[result.id] = result
    instance.nodes_by_path[result.path] = result
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
  instance.root_node = self.root
  return self
end

function Tree:_allocate_id()
  self.instance._next_node_id = self.instance._next_node_id + 1
  return self.instance._next_node_id
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
    visible_size = 0,
    visible_start = nil,
    visible_end = nil,
    visible_range = nil,
    row_extmark = nil,
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
  self.instance.nodes_by_id[node.id] = nil
  if self.instance.nodes_by_path[node.path] == node then
    self.instance.nodes_by_path[node.path] = nil
  end
end

function Tree:_register(node)
  self.instance.nodes_by_id[node.id] = node
  self.instance.nodes_by_path[node.path] = node
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
    nodes_by_id = shallow_copy(self.instance.nodes_by_id),
    nodes_by_path = shallow_copy(self.instance.nodes_by_path),
    child_metadata = child_metadata,
  }
end

function Tree:restore_directory(parent, snapshot)
  for key in pairs(self.instance.nodes_by_id) do self.instance.nodes_by_id[key] = nil end
  for key, value in pairs(snapshot.nodes_by_id) do self.instance.nodes_by_id[key] = value end
  for key in pairs(self.instance.nodes_by_path) do self.instance.nodes_by_path[key] = nil end
  for key, value in pairs(snapshot.nodes_by_path) do self.instance.nodes_by_path[key] = value end
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

function Tree:reconcile(parent, entries, comparator)
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

  table.sort(ordered, comparator)

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
    if self.instance.nodes_by_id[node.id] == nil then self:_register(node) end
  end

  parent.children_by_name = by_name
  parent.children_order = ordered
  parent.load_state = "loaded"
  parent.loaded = true
  parent.children_cached = true
  return ordered
end

function Tree:find_child(parent, name)
  local direct = parent.children_by_name and parent.children_by_name[name]
  if direct then return direct end
  if path.is_windows(self.instance.root) then
    for child_name, child in pairs(parent.children_by_name or {}) do
      if child_name:lower() == name:lower() then return child end
    end
  end
  return nil
end

function Tree:project(include_node)
  local nodes = {}
  local ranges = {}
  for _, node in pairs(self.instance.nodes_by_id) do
    node.visible_size = 0
    node.visible_start = nil
    node.visible_end = nil
    node.visible_range = nil
  end

  local function visit(node)
    if include_node and not include_node(node) then return end
    local first = #nodes + 1
    nodes[first] = node
    if node.kind == "directory" and node.expanded and node.loaded then
      for _, child in ipairs(node.children_order or {}) do visit(child) end
    end
    local last = #nodes
    node.visible_start = first
    node.visible_end = last
    node.visible_size = last - first + 1
    node.visible_range = { start_row = first, end_row = last }
    ranges[node.id] = {
      start_row = first,
      end_row = last,
      size = node.visible_size,
    }
  end

  for _, child in ipairs(self.root.children_order or {}) do visit(child) end
  self.root.visible_size = #nodes
  if #nodes > 0 then
    self.root.visible_start = 1
    self.root.visible_end = #nodes
    self.root.visible_range = { start_row = 1, end_row = #nodes }
  end
  ranges[self.root.id] = {
    start_row = self.root.visible_start,
    end_row = self.root.visible_end,
    size = self.root.visible_size,
  }
  return { nodes = nodes, ranges = ranges, size = #nodes }
end

return Tree
