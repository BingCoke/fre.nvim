local Lifecycle = require("fre.lifecycle")

describe("fre Lifecycle", function()
  local scheduled
  local events
  local function new_lifecycle()
    scheduled = {}
    events = {}
    return Lifecycle.new({
      schedule = function(callback) scheduled[#scheduled + 1] = callback end,
      emit_ready = function(err, result)
        events[#events + 1] = { kind = "event", error = err, result = result }
      end,
    })
  end
  local function drain()
    while #scheduled > 0 do
      local callback = table.remove(scheduled, 1)
      callback()
    end
  end

  it("resolves queued observers before the readiness event and supports retry", function()
    local lifecycle = new_lifecycle()
    local order = {}
    lifecycle:observe(function(err)
      assert.is_nil(err)
      order[#order + 1] = "observer"
    end)
    lifecycle:begin_load()
    assert.is_true(lifecycle:complete_load(nil, { value = 1 }, function()
      order[#order + 1] = "effects"
    end))
    assert.are.same({ "effects", "observer" }, order)
    assert.are.equal("ready", lifecycle:status())
    assert.are.same({ value = 1 }, events[1].result)
    assert.are.equal("event", events[1].kind)
    assert.is_false(lifecycle:complete_load(nil, { value = 2 }))

    local late = 0
    lifecycle:observe(function() late = late + 1 end)
    assert.are.equal(0, late)
    drain()
    assert.are.equal(1, late)

    lifecycle:begin_load()
    assert.is_true(lifecycle:complete_load("broken"))
    assert.are.equal("load-failed", lifecycle:status())
    assert.are.equal("broken", lifecycle:failure())
    assert.is_nil(events[#events].result)
  end)

  it("completes pending observers on destruction and supports silent discard", function()
    local lifecycle = new_lifecycle()
    local callback_error
    lifecycle:observe(function(err) callback_error = err end)
    assert.is_true(lifecycle:begin_destroy())
    assert.are.equal("destroying", lifecycle:status())
    drain()
    assert.are.equal("instance was destroyed before becoming ready", callback_error)
    lifecycle:finish_destroy()
    assert.is_true(lifecycle:is_destroyed())
    assert.is_false(lifecycle:begin_destroy())

    local constructor = new_lifecycle()
    local called = false
    constructor:observe(function() called = true end)
    constructor:discard()
    drain()
    assert.is_false(called)
    assert.is_true(constructor:is_destroyed())
  end)
end)
