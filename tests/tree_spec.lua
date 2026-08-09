local Tree = require("fre.instance.tree")

describe("fre Tree interface", function()
  local function comparator(_, left, right)
    return left.name < right.name
  end

  it("owns lookup sorting expansion and directory load transitions", function()
    local tree = Tree.new("/root", "tree-one", comparator)
    local root = tree:root_node()
    local ordered = tree:reconcile(root, {
      { name = "z.txt", kind = "file" },
      { name = "dir", kind = "directory" },
    })

    assert.are.same({ "dir", "z.txt" }, { ordered[1].name, ordered[2].name })
    assert.are.equal(root, tree:node_by_path("/root"))
    assert.are.equal(ordered[1], tree:node_by_id(ordered[1].id))
    assert.are.equal("dir", tree:entry(ordered[1]).relative_path)
    assert.is_true(tree:contains(ordered[1]))

    local directory = ordered[1]
    tree:set_expanded(directory, true)
    assert.are.same({ "/root/dir" }, tree:active_expanded_paths())
    local generation = tree:begin_load(directory)
    assert.is_true(tree:is_current_load(directory, generation, "loading"))
    tree:mark_unloaded(directory)
    assert.are.equal("unloaded", directory.load_state)
    tree:mark_loaded(directory)
    assert.are.equal("loaded", directory.load_state)
    assert.is_true(tree:collapse_all())
    assert.is_false(directory.expanded)
    assert.are.equal(3, tree:latest_node_id())

    local peer = Tree.new("/peer", "tree-two", comparator)
    local peer_node = peer:reconcile(peer:root_node(), {
      { name = "same-id.txt", kind = "file" },
    })[1]
    assert.are.equal(2, peer_node.id)
    assert.are.equal(2, ordered[2].id)
  end)

  it("restores topology without reusing IDs and adopts candidates with stable identity", function()
    local tree = Tree.new("/root", "tree-restore", comparator)
    local root = tree:root_node()
    local directory = tree:reconcile(root, {
      { name = "dir", kind = "directory" },
    })[1]
    tree:reconcile(directory, {
      { name = "kept.txt", kind = "file" },
    })
    local checkpoint = tree:snapshot_directory(directory)
    local before_discard = tree:latest_node_id()
    tree:reconcile(directory, {
      { name = "discarded.txt", kind = "file" },
    })
    tree:restore_directory(directory, checkpoint)

    assert.is_nil(tree:node_by_path("/root/dir/discarded.txt"))
    assert.is_not_nil(tree:node_by_path("/root/dir/kept.txt"))
    assert.is_true(tree:latest_node_id() > before_discard)

    local identity = tree
    local candidate = Tree.clone(tree)
    candidate:reconcile(candidate:root_node(), {
      { name = "dir", kind = "directory" },
      { name = "added.txt", kind = "file" },
    })
    local added = candidate:node_by_path("/root/added.txt")
    tree:adopt(candidate)

    assert.are.equal(identity, tree)
    assert.are.equal(added, tree:node_by_path("/root/added.txt"))
    assert.is_true(added.id > before_discard)
  end)
  it("summarizes detached topology order and normalized metadata changes", function()
    local function entry(name, kind, mode, size, sec, nsec)
      return {
        name = name, kind = kind,
        stat = { mode = mode, size = size, mtime = { sec = sec, nsec = nsec } },
      }
    end
    local tree = Tree.new("/root", "tree-summary", comparator)
    local root = tree:root_node()
    tree:reconcile(root, {
      entry("dir", "directory", 493, 0, 1, 0),
      entry("kept.txt", "file", 420, 1, 2, 0),
    })
    local directory = tree:node_by_path("/root/dir")
    tree:reconcile(directory, {
      entry("nested.txt", "file", 420, 2, 3, 0),
    })
    local kept = tree:node_by_path("/root/kept.txt")
    local nested = tree:node_by_path("/root/dir/nested.txt")

    local _, change = tree:reconcile(root, {
      entry("added.txt", "file", 420, 5, 4, 0),
      entry("kept.txt", "file", 420, 9, 2, 7),
    })
    local added = tree:node_by_path("/root/added.txt")
    assert.are.equal(kept, tree:node_by_path("/root/kept.txt"))
    assert.is_nil(tree:node_by_path("/root/dir"))
    assert.is_true(change.changed)
    assert.is_true(change.order_changed)
    assert.are.same({ [added.id] = true }, change.created)
    assert.are.same({ [directory.id] = true, [nested.id] = true }, change.deleted)
    assert.are.same({ [kept.id] = { size = true, mtime = true } }, change.metadata)

    local _, unchanged = tree:reconcile(root, {
      entry("added.txt", "file", 420, 5, 4, 0),
      entry("kept.txt", "file", 420, 9, 2, 7),
    })
    assert.is_false(unchanged.changed)
    assert.is_false(unchanged.order_changed)
    assert.are.same({}, unchanged.created)
    assert.are.same({}, unchanged.deleted)
    assert.are.same({}, unchanged.metadata)
  end)

end)
