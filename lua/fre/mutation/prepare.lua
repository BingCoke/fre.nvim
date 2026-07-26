local buffer = require("fre.buffer")
local path = require("fre.path")
local move_graph = require("fre.mutation.move_graph")

local M = {}
local supported_kinds = { file = true, directory = true, symlink = true }

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function fail_row(row, message, level)
  fail("row " .. tostring(row) .. ": " .. message, level or 4)
end

local function validate_kind(kind, row)
  if supported_kinds[kind] then return end
  local message = "unsupported snapshot kind " .. tostring(kind)
  if row then fail_row(row, message) else fail(message) end
end

local function sorted_node_ids(nodes_by_id)
  local ids = {}
  for id in pairs(nodes_by_id or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function baseline_order(instance)
  local baseline = assert(instance.view and instance.view.baseline)
  local ordered, seen = {}, {}
  for _, node in ipairs(instance.view.visible_nodes or {}) do
    if baseline[node.id] ~= nil and not seen[node.id] then
      ordered[#ordered + 1] = node.id
      seen[node.id] = true
    end
  end
  local remaining = {}
  for id in pairs(baseline) do
    if not seen[id] then remaining[#remaining + 1] = id end
  end
  table.sort(remaining)
  for _, id in ipairs(remaining) do ordered[#ordered + 1] = id end
  return ordered
end

local function target_for_row(instance, row, decoded)
  if decoded.proposed_path == "" then fail_row(row, "path is empty") end
  local ok, absolute, relative = pcall(path.edit_target, instance.root, decoded.proposed_path)
  if not ok then
    fail_row(row, "invalid path " .. string.format("%q", decoded.proposed_path)
      .. ": " .. tostring(absolute))
  end
  return absolute, relative
end

local function display_path(relative, kind)
  if kind == "directory" then return relative .. "/" end
  return relative
end

local function operation_display(action)
  if action.type == "create_file" then
    return "CREATE FILE  " .. display_path(action.to_relative, "file")
  end
  if action.type == "create_directory" then
    return "CREATE DIRECTORY  " .. display_path(action.to_relative, "directory")
  end
  if action.type == "copy" or action.type == "move" then
    return action.type:upper() .. "  " .. display_path(action.from_relative, action.kind)
      .. " -> " .. display_path(action.to_relative, action.kind)
  end
  return "DELETE  " .. display_path(action.from_relative, action.kind)
end

local function public_operation(action)
  if action.type == "create_file" or action.type == "create_directory" then
    return { type = action.type, path = action.to }
  end
  if action.type == "copy" or action.type == "move" then
    return { type = action.type, from = action.from, to = action.to, kind = action.kind }
  end
  return { type = "delete", path = action.from, kind = action.kind }
end

local function action_label(action)
  if action.type == "copy" or action.type == "move" then
    return display_path(action.from_relative, action.kind) .. " -> "
      .. display_path(action.to_relative, action.kind)
  end
  if action.type == "delete" then return display_path(action.from_relative, action.kind) end
  return display_path(action.to_relative,
    action.type == "create_directory" and "directory" or "file")
end

local function node_depth(node)
  local depth, current = 0, node and node.parent
  while current do
    depth = depth + 1
    current = current.parent
  end
  return depth
end

local function sorted_occurrences(found, windows)
  local result = vim.list_slice(found or {})
  table.sort(result, function(left, right)
    local left_key = windows and left.target:lower() or left.target
    local right_key = windows and right.target:lower() or right.target
    if left_key ~= right_key then return left_key < right_key end
    if left.target ~= right.target then return left.target < right.target end
    return left.row < right.row
  end)
  return result
end

local function derived_target(root, source, target)
  local suffix = assert(path.relative(source, target))
  return suffix == "" and root or path.resolve(root, suffix)
end

function M.prepare(instance)
  if instance.state ~= "ready-hidden" and instance.state ~= "ready-visible" then
    fail("instance is not ready", 3)
  end
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then
    fail("instance buffer is not valid", 3)
  end
  if not instance.view or type(instance.view.baseline) ~= "table" then
    fail("instance has no successful projection baseline", 3)
  end

  local baseline = instance.view.baseline
  local ordered_baseline = baseline_order(instance)
  local windows = path.is_windows(instance.root)
  local occurrences, rows = {}, {}
  local line_count = vim.api.nvim_buf_line_count(instance.bufnr)

  for row = 1, line_count do
    local decoded = buffer.decode(instance, row)
    if decoded.marked then
      validate_kind(decoded.entry.kind, row)
      local absolute, relative = target_for_row(instance, row, decoded)
      local occurrence = {
        row = row, node_id = decoded.node_id, kind = decoded.entry.kind,
        target = absolute, target_relative = relative,
      }
      if decoded.foreign then
        occurrence.foreign = true
        occurrence.source = decoded.entry.absolute_path
        occurrence.source_node = decoded.source_node
      else
        if baseline[decoded.node_id] == nil then
          fail_row(row, "local marker is not part of the projected baseline for path "
            .. display_path(relative, decoded.entry.kind))
        end
        occurrences[decoded.node_id] = occurrences[decoded.node_id] or {}
        occurrences[decoded.node_id][#occurrences[decoded.node_id] + 1] = occurrence
      end
      rows[#rows + 1] = occurrence
    elseif decoded.line ~= "" then
      local absolute, relative = target_for_row(instance, row, decoded)
      local kind = decoded.proposed_path:sub(-1) == "/" and "directory" or "file"
      rows[#rows + 1] = {
        row = row, kind = kind, target = absolute, target_relative = relative, new = true,
      }
    end
  end

  for index, current in ipairs(rows) do
    for previous_index = 1, index - 1 do
      local previous = rows[previous_index]
      if path.equal(previous.target, current.target, { windows = windows }) then
        fail_row(current.row, "duplicate target "
          .. display_path(current.target_relative, current.kind)
          .. " also appears on row " .. tostring(previous.row))
      end
    end
  end

  local baseline_index = {}
  for index, id in ipairs(ordered_baseline) do baseline_index[id] = index end
  local classification_order = vim.list_slice(ordered_baseline)
  table.sort(classification_order, function(left, right)
    local left_node, right_node = instance.nodes_by_id[left], instance.nodes_by_id[right]
    local left_depth, right_depth = node_depth(left_node), node_depth(right_node)
    if left_depth ~= right_depth then return left_depth < right_depth end
    return baseline_index[left] < baseline_index[right]
  end)

  local actions, intents = {}, {}
  local action_counter = 0
  local function add_action(action, rank, tie)
    action_counter = action_counter + 1
    action.dependencies = {}
    action.occupancy_dependencies = {}
    action.non_occupancy_dependencies = {}
    action.rank = rank
    action.tie = tie or ""
    action.creation_index = action_counter
    actions[#actions + 1] = action
    return action
  end

  local function add_dependency(action, dependency, reason)
    action.dependencies[dependency] = true
    if reason == "occupancy" then
      action.occupancy_dependencies[dependency] = true
    else
      action.non_occupancy_dependencies[dependency] = true
    end
  end

  for _, item in ipairs(rows) do
    if item.new then
      item.action = add_action({
        type = item.kind == "directory" and "create_directory" or "create_file",
        to = item.target, to_relative = item.target_relative, kind = item.kind, row = item.row,
      }, item.row, item.target)
    elseif item.foreign then
      if path.equal(item.source, item.target) then
        fail_row(item.row, "copy source must differ from target "
          .. display_path(item.target_relative, item.kind))
      end
      if item.kind == "directory" and path.contains(item.source, item.target) then
        fail_row(item.row, "directory target " .. display_path(item.target_relative, item.kind)
          .. " must not be inside its own source subtree " .. item.source .. "/")
      end

      local source_entries = {}
      local function capture_source(node)
        source_entries[#source_entries + 1] = { path = node.path, kind = node.kind }
        if node.kind == "directory" and node.children_cached then
          for _, child in ipairs(node.children_order or {}) do capture_source(child) end
        end
      end
      capture_source(item.source_node)
      item.action = add_action({
        type = "copy", from = item.source, from_relative = item.source,
        to = item.target, to_relative = item.target_relative, kind = item.kind,
        row = item.row, foreign = true, source_entries = source_entries,
      }, item.row, item.target)
    end
  end

  local function nearest_directory_intent(node)
    local parent = node and node.parent
    while parent do
      if intents[parent.id] then return intents[parent.id] end
      parent = parent.parent
    end
    return nil
  end

  local function contradictory(row, target_relative, kind, detail)
    fail_row(row, "contradictory ancestor/descendant outcome for "
      .. display_path(target_relative, kind) .. ": " .. detail)
  end

  for _, id in ipairs(classification_order) do
    local node = instance.nodes_by_id[id]
    if node == nil then fail("projected baseline references missing local node " .. tostring(id), 3) end
    validate_kind(node.kind)
    local source = path.normalize(baseline[id], { windows = windows })
    local source_relative = assert(path.relative(instance.root, source))
    local found = sorted_occurrences(occurrences[id], windows)
    local parent_intent = nearest_directory_intent(node)
    local expected = {}
    if parent_intent then
      for _, root in ipairs(parent_intent.final_roots) do
        expected[#expected + 1] = derived_target(root, parent_intent.source, source)
      end
    end

    local carried, external = {}, {}
    for _, occurrence in ipairs(found) do
      local satisfied = occurrence.target == source
      if not satisfied then
        for _, target in ipairs(expected) do
          if path.equal(occurrence.target, target, { windows = windows }) then
            satisfied = true
            break
          end
        end
      end
      if satisfied then
        carried[#carried + 1] = occurrence
      else
        external[#external + 1] = occurrence
      end
    end

    local intent = {
      id = id, node = node, source = source, source_relative = source_relative,
      final_roots = {}, actions = {}, parent = parent_intent,
    }
    intents[id] = intent

    local function validate_external(occurrence)
      if node.kind == "directory" then
        local equal_source = path.equal(source, occurrence.target, { windows = windows })
        if equal_source and source == occurrence.target then
          fail_row(occurrence.row, "directory target "
            .. display_path(occurrence.target_relative, node.kind)
            .. " must differ from its source " .. display_path(source_relative, node.kind))
        end
        if not equal_source and path.contains(source, occurrence.target) then
          fail_row(occurrence.row, "directory target "
            .. display_path(occurrence.target_relative, node.kind)
            .. " must not be inside its own source subtree "
            .. display_path(source_relative, node.kind))
        end
      end
      local ancestor = parent_intent
      while ancestor do
        if #ancestor.final_roots == 0 and path.contains(ancestor.source, occurrence.target) then
          contradictory(occurrence.row, occurrence.target_relative, node.kind,
            "target remains inside deleted ancestor "
              .. display_path(ancestor.source_relative, "directory"))
        end
        ancestor = ancestor.parent
      end
    end
    for _, occurrence in ipairs(external) do validate_external(occurrence) end

    local primary
    if #carried == 0 and #external > 0 then primary = external[1] end
    local copies = {}
    for _, occurrence in ipairs(external) do
      if occurrence ~= primary then copies[#copies + 1] = occurrence end
    end

    for _, occurrence in ipairs(copies) do
      local action = add_action({
        type = "copy", from = source, from_relative = source_relative,
        to = occurrence.target, to_relative = occurrence.target_relative,
        kind = node.kind, node_id = id, node = node, row = occurrence.row,
      }, occurrence.row, occurrence.target)
      occurrence.action = action
      intent.actions[#intent.actions + 1] = action
    end

    if primary then
      local action = add_action({
        type = "move", from = source, from_relative = source_relative,
        to = primary.target, to_relative = primary.target_relative,
        kind = node.kind, node_id = id, node = node, row = primary.row,
      }, primary.row, primary.target)
      primary.action = action
      intent.actions[#intent.actions + 1] = action
      intent.vacancy = action
      for _, copy_occurrence in ipairs(copies) do
        add_dependency(action, copy_occurrence.action, "source-read")
      end
    elseif #found == 0 then
      if not parent_intent or #parent_intent.final_roots > 0 then
        local action = add_action({
          type = "delete", from = source, from_relative = source_relative,
          kind = node.kind, node_id = id, node = node,
        }, line_count + baseline_index[id], source)
        intent.actions[#intent.actions + 1] = action
        intent.vacancy = action
      else
        intent.vacancy = parent_intent.vacancy
      end
    end

    if node.kind == "directory" then
      if #carried > 0 then
        if parent_intent then
          for _, target in ipairs(expected) do intent.final_roots[#intent.final_roots + 1] = target end
        else
          intent.final_roots[1] = source
        end
      end
      for _, occurrence in ipairs(external) do
        if parent_intent and path.contains(parent_intent.source, occurrence.target) then
          for _, root in ipairs(parent_intent.final_roots) do
            intent.final_roots[#intent.final_roots + 1] =
              derived_target(root, parent_intent.source, occurrence.target)
          end
        else
          intent.final_roots[#intent.final_roots + 1] = occurrence.target
        end
      end
    end
  end

  -- Targets inside a source subtree must be established before a whole-entry
  -- copy/move carries them. Targets inside a produced directory run afterwards.
  for _, action in ipairs(actions) do
    if action.to then
      local has_target_container = false
      for _, producer in ipairs(actions) do
        if producer ~= action
            and producer.kind == "directory"
            and (producer.type == "copy" or producer.type == "move")
            and path.contains(producer.to, action.to) then
          has_target_container = true
          break
        end
      end
      for _, id in ipairs(classification_order) do
        local intent = intents[id]
        if intent.node.kind == "directory" then
          if path.contains(intent.source, action.to) then
            if #intent.final_roots == 0 then
              contradictory(action.row, action.to_relative, action.kind,
                "target remains inside deleted ancestor "
                  .. display_path(intent.source_relative, "directory"))
            end
            if not path.equal(intent.source, action.to, { windows = windows })
                and not has_target_container then
              for _, ancestor_action in ipairs(intent.actions) do
                if ancestor_action ~= action then
                  add_dependency(ancestor_action, action, "ancestor-source")
                end
              end
            end
          end
          for _, ancestor_action in ipairs(intent.actions) do
            if ancestor_action ~= action
                and ancestor_action.kind == "directory"
                and (ancestor_action.type == "copy" or ancestor_action.type == "move")
                and path.contains(ancestor_action.to, action.to) then
              add_dependency(action, ancestor_action, "target-container")
            end
          end
        end
      end
    end
  end

  -- A foreign directory target is a target-side container just like a local
  -- directory copy target, but its source never participates in local ownership.
  for _, producer in ipairs(actions) do
    if producer.foreign and producer.kind == "directory" then
      for _, action in ipairs(actions) do
        if action ~= producer and action.to and path.contains(producer.to, action.to) then
          add_dependency(action, producer, "target-container")
        end
      end
    end
  end

  -- Overlapping instance roots can make a foreign snapshot path locally owned as
  -- well. Preserve copy semantics by reading it before a local move/delete removes it.
  for _, foreign in ipairs(actions) do
    if foreign.foreign then
      for _, action in ipairs(actions) do
        if action ~= foreign and (action.type == "move" or action.type == "delete") then
          local removes_source = action.kind == "directory"
            and path.contains(action.from, foreign.from)
            or path.equal(action.from, foreign.from, { windows = windows })
          if removes_source then add_dependency(action, foreign, "source-read") end
        end
      end
    end
  end

  -- Source-removing descendant edits precede a directory copy so it reflects the
  -- extraction. Every descendant action precedes an ancestor move/delete that removes it.
  for _, action in ipairs(actions) do
    if action.node then
      local parent = action.node.parent
      while parent do
        local ancestor = intents[parent.id]
        if ancestor then
          for _, ancestor_action in ipairs(ancestor.actions) do
            local ancestor_removes_source = ancestor_action.type == "move"
              or ancestor_action.type == "delete"
            local descendant_removes_source = action.type == "move" or action.type == "delete"
            if ancestor_removes_source or descendant_removes_source then
              add_dependency(ancestor_action, action, "ancestor-source")
            end
          end
        end
        parent = parent.parent
      end
    end
  end

  local function vacancy_for(node)
    local current = node
    while current do
      local intent = intents[current.id]
      if intent and intent.vacancy then return intent.vacancy end
      current = current.parent
    end
    return nil
  end

  local snapshot = {}
  for _, id in ipairs(sorted_node_ids(instance.nodes_by_id)) do
    local node = instance.nodes_by_id[id]
    if node ~= instance.root_node then
      snapshot[#snapshot + 1] = {
        id = id, node = node, path = path.normalize(node.path, { windows = windows }), kind = node.kind,
      }
    end
  end

  for _, action in ipairs(actions) do
    if action.to ~= nil then
      for _, occupied in ipairs(snapshot) do
        if path.equal(action.to, occupied.path, { windows = windows }) then
          local vacancy = vacancy_for(occupied.node)
          if vacancy == nil then
            fail((action.row and "row " .. tostring(action.row) .. ": " or "")
              .. "target " .. display_path(action.to_relative,
                action.type == "create_directory" and "directory" or action.kind)
              .. " is occupied by snapshot path "
              .. display_path(assert(path.relative(instance.root, occupied.path)), occupied.kind))
          end
          add_dependency(action, vacancy, "occupancy")
        end
      end
    end
  end

  table.sort(actions, function(left, right)
    if left.rank ~= right.rank then return left.rank < right.rank end
    if left.tie ~= right.tie then return left.tie < right.tie end
    return left.creation_index < right.creation_index
  end)
  for sequence, action in ipairs(actions) do action.sequence = sequence end

  local reserved_paths = { instance.root }
  for _, absolute in pairs(baseline) do reserved_paths[#reserved_paths + 1] = absolute end
  for _, occupied in ipairs(snapshot) do reserved_paths[#reserved_paths + 1] = occupied.path end
  for _, action in ipairs(actions) do
    if action.from then reserved_paths[#reserved_paths + 1] = action.from end
    if action.to then reserved_paths[#reserved_paths + 1] = action.to end
    for _, entry in ipairs(action.source_entries or {}) do
      reserved_paths[#reserved_paths + 1] = entry.path
    end
  end

  local ordered, display_order = move_graph.order_and_lower(actions, {
    windows = windows,
    reserved_paths = reserved_paths,
    describe = action_label,
  })

  local function virtual_key(value)
    local normalized = path.normalize(value, { windows = windows })
    return windows and normalized:lower() or normalized
  end

  local virtual = {}
  for _, occupied in ipairs(snapshot) do
    virtual[virtual_key(occupied.path)] = {
      path = occupied.path, kind = occupied.kind, node_id = occupied.id,
    }
  end

  local function selected_entries(action)
    local selected = {}
    for key, entry in pairs(virtual) do
      local matches = action.kind == "directory"
        and path.contains(action.from, entry.path)
        or path.equal(action.from, entry.path, { windows = windows })
      if matches then selected[#selected + 1] = { key = key, entry = entry } end
    end
    table.sort(selected, function(left, right)
      local left_key, right_key = virtual_key(left.entry.path), virtual_key(right.entry.path)
      if left_key ~= right_key then return left_key < right_key end
      return left.entry.path < right.entry.path
    end)
    return selected
  end

  local function add_virtual(action, target, entry)
    local key = virtual_key(target)
    local occupied = virtual[key]
    if occupied then
      fail((action.row and "row " .. tostring(action.row) .. ": " or "")
        .. "target collision at "
        .. display_path(assert(path.relative(instance.root, target)), entry.kind)
        .. " with planned "
        .. display_path(assert(path.relative(instance.root, occupied.path)), occupied.kind))
    end
    virtual[key] = { path = target, kind = entry.kind, node_id = entry.node_id }
  end

  for _, action in ipairs(ordered) do
    if action.type == "delete" then
      for _, selected in ipairs(selected_entries(action)) do virtual[selected.key] = nil end
    elseif action.type == "move" or action.type == "copy" then
      if action.foreign then
        for _, entry in ipairs(action.source_entries) do
          add_virtual(action, derived_target(action.to, action.from, entry.path), entry)
        end
      else
        local selected = selected_entries(action)
        if action.type == "move" then
          for _, item in ipairs(selected) do virtual[item.key] = nil end
        end
        for _, item in ipairs(selected) do
          add_virtual(action, derived_target(action.to, action.from, item.entry.path), item.entry)
        end
      end
    elseif action.type == "create_file" or action.type == "create_directory" then
      add_virtual(action, action.to, { kind = action.kind })
    end
  end

  local operations, display = {}, {}
  for index, action in ipairs(ordered) do operations[index] = public_operation(action) end
  for index, action in ipairs(display_order) do display[index] = operation_display(action) end
  return { operations = operations, display = display }
end

return M
