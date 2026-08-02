local Tree = require("fre.instance.tree")

describe("fre Tree interface", function()
  local function comparator(_, left, right)
    return left.name < right.name
  end

  it("owns lookup sorting expansion and directory load transitions", function()
    local observed = {}
    local tree = Tree.new("/root", 42, comparator, function(id)
      observed[#observed + 1] = id
    end)
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
    assert.are.same({ 1, 2, 3 }, observed)
  end)

  it("restores topology without reusing IDs and adopts candidates with stable identity", function()
    local tree = Tree.new("/root", 7, comparator)
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
end)
