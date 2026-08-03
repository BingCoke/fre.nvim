local fre = require("fre")
local mutation_fs = require("fre.mutation.fs")
local fs = require("tests.helpers.fs")

local instances = {}
local fixture
local original_notify

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(2500, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function() return instance:status() ~= "creating" end)
  assert.are.equal("ready", instance:status())
end

local function wait_terminal(execution)
  wait_for(function()
    local state = execution:get_status().state
    return state == "succeeded" or state == "failed" or state == "canceled"
  end)
  return execution:get_status()
end

local function complete_adapter(calls)
  local function record(name, values, done)
    calls[#calls + 1] = { name = name, values = values }
    done(nil)
  end
  return {
    create_file = function(path, done) record("create_file", { path }, done) end,
    create_directory = function(path, done) record("create_directory", { path }, done) end,
    copy = function(from, to, kind, done) record("copy", { from, to, kind }, done) end,
    move = function(from, to, done) record("move", { from, to }, done) end,
    delete = function(path, kind, done) record("delete", { path, kind }, done) end,
  }
end

local function pending_adapter(calls, pending)
  local function record(name, values, done, report)
    calls[#calls + 1] = { name = name, values = values }
    pending[#pending + 1] = { done = done, report = report }
  end
  return {
    create_file = function(path, done, report) record("create_file", { path }, done, report) end,
    create_directory = function(path, done, report) record("create_directory", { path }, done, report) end,
    copy = function(from, to, kind, done, report)
      record("copy", { from, to, kind }, done, report)
    end,
    move = function(from, to, done, report) record("move", { from, to }, done, report) end,
    delete = function(path, kind, done, report)
      record("delete", { path, kind }, done, report)
    end,
  }
end

local function read_file(path)
  local fd = assert(vim.uv.fs_open(path, "r", 438))
  local stat = assert(vim.uv.fs_fstat(fd))
  local contents = assert(vim.uv.fs_read(fd, stat.size, 0))
  assert(vim.uv.fs_close(fd))
  return contents
end

local function lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

describe("fre plan execution", function()
  before_each(function()
    fixture = fs.new()
    original_notify = vim.notify
    instances = {}
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
  end)

  after_each(function()
    vim.notify = original_notify
    fre._reset_mutation_adapter()
    fre._reset_fs_adapter()
    for _, instance in ipairs(instances) do
      if instance:status() ~= "destroyed" then
        local execution = instance.work and instance.work:active_execution()
        if execution then
          local state = execution:get_status().state
          if state == "running" then execution:cancel() end
          vim.wait(500, function()
            local value = execution:get_status().state
            return value == "succeeded" or value == "failed" or value == "canceled"
          end, 10)
        end
        if instance:status() ~= "destroyed" then instance:destroy() end
      end
    end
    fixture:cleanup()
  end)

  it("starts operations strictly in array order and snapshots caller data", function()
    local calls, pending = {}, {}
    local adapter = pending_adapter(calls, pending)
    fre._set_mutation_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    assert.are.equal(adapter, instance.work.mutation_adapter)
    local plan = { operations = {
      { type = "create_file", path = "first" },
      { type = "move", from = "first", to = "second", kind = "file" },
      { type = "delete", path = "second", kind = "file" },
    } }
    local execution = instance:execute(plan)
    plan.operations[1].path = "caller-mutated"
    plan.operations[2].to = "caller-mutated"
    plan.operations[3] = { type = "unknown" }

    wait_for(function() return #calls == 1 end)
    assert.are.same({ { name = "create_file", values = { "first" } } }, calls)
    pending[1].done(nil)
    wait_for(function() return #calls == 2 end)
    assert.are.same({ "first", "second" }, calls[2].values)
    pending[2].done(nil)
    wait_for(function() return #calls == 3 end)
    assert.are.same({ "second", "file" }, calls[3].values)
    pending[3].done(nil)
    local status = wait_terminal(execution)
    assert.are.equal("succeeded", status.state)
    assert.are.equal(3, status.completed)
    assert.are.equal(3, status.total)
  end)

  it("fails a malformed later operation only after preserving prior effects", function()
    local calls = {}
    fre._set_mutation_adapter(complete_adapter(calls))
    local instance = keep(fre.new({ root = fixture.root }))
    local execution = instance:execute({
      display = { "ignored and inconsistent" },
      operations = {
        { type = "create_file", path = fixture:path("outside-instance") },
        { type = "invented", path = "later" },
        { type = "delete", path = "never", kind = "file" },
      },
    })
    local status = wait_terminal(execution)
    assert.are.equal("failed", status.state)
    assert.are.equal(1, status.completed)
    assert.are.equal(3, status.total)
    assert.are.equal("invented", status.current.type)
    assert.is_truthy(status.error:find("operation 2", 1, true))
    assert.is_false(status.partial_current)
    assert.are.same({ "create_file" }, vim.tbl_map(function(call) return call.name end, calls))
  end)

  it("dispatches native special moves and deletes but rejects their copies", function()
    local calls = {}
    fre._set_mutation_adapter(complete_adapter(calls))
    local instance = keep(fre.new({ root = fixture.root }))
    local special_kinds = { "char", "block", "fifo", "socket" }

    for _, kind in ipairs(special_kinds) do
      local status = wait_terminal(instance:execute({ operations = {
        { type = "move", from = "from-" .. kind, to = "to-" .. kind, kind = kind },
        { type = "delete", path = "to-" .. kind, kind = kind },
      } }))
      assert.are.equal("succeeded", status.state)
    end
    assert.are.equal(#special_kinds * 2, #calls)
    for index, kind in ipairs(special_kinds) do
      assert.are.same({
        name = "move", values = { "from-" .. kind, "to-" .. kind },
      }, calls[index * 2 - 1])
      assert.are.same({
        name = "delete", values = { "to-" .. kind, kind },
      }, calls[index * 2])
    end

    local function reject(operation, fragment)
      local call_count = #calls
      local status = wait_terminal(instance:execute({ operations = { operation } }))
      assert.are.equal("failed", status.state)
      assert.is_truthy(tostring(status.error):find(fragment, 1, true), tostring(status.error))
      assert.are.equal(call_count, #calls)
    end
    for _, kind in ipairs(special_kinds) do
      reject({ type = "copy", from = "from", to = "to", kind = kind },
        ".kind " .. kind .. " does not support copy")
    end
    reject({ type = "move", from = "from", to = "to", kind = "other" },
      ".kind other does not support move")
    reject({ type = "delete", path = "path", kind = "other" },
      ".kind other does not support delete")
    reject({ type = "copy", from = "from", to = "to", kind = "other" },
      ".kind other does not support copy")
  end)

  it("rejects a second execution and destroy while the first is nonterminal", function()
    local calls, pending = {}, {}
    fre._set_mutation_adapter(pending_adapter(calls, pending))
    local instance = keep(fre.new({ root = fixture.root }))
    local first = instance:execute({ operations = {
      { type = "create_file", path = "held" },
    } })
    assert.has_error(function()
      instance:execute({ operations = {} })
    end)
    assert.has_error(function() instance:destroy() end)
    wait_for(function() return pending[1] ~= nil end)
    pending[1].done(nil)
    assert.are.equal("succeeded", wait_terminal(first).state)
    local empty = instance:execute({ operations = {} })
    assert.are.equal("running", empty:get_status().state)
    local empty_status = wait_terminal(empty)
    assert.are.same({
      state = "succeeded", completed = 0, total = 0, partial_current = false,
    }, empty_status)
  end)

  it("stops on an adapter failure and retains partial whole-entry detail", function()
    local calls, pending = {}, {}
    fre._set_mutation_adapter(pending_adapter(calls, pending))
    local instance = keep(fre.new({ root = fixture.root }))
    local execution = instance:execute({ operations = {
      { type = "create_file", path = "done" },
      { type = "copy", from = "source", to = "partial", kind = "directory" },
      { type = "delete", path = "never", kind = "file" },
    } })
    wait_for(function() return pending[1] ~= nil end)
    pending[1].done(nil)
    wait_for(function() return pending[2] ~= nil end)
    local detail = { phase = { entry = "child.txt" } }
    pending[2].report(detail)
    detail.phase.entry = "caller-mutated"
    pending[2].done("copy exploded", { phase = { entry = "child.txt" } }, true)
    local status = wait_terminal(execution)
    assert.are.equal("failed", status.state)
    assert.are.equal(1, status.completed)
    assert.are.equal(3, status.total)
    assert.are.equal("copy", status.current.type)
    assert.are.same({ phase = { entry = "child.txt" } }, status.detail)
    assert.are.equal("copy exploded", status.error)
    assert.is_true(status.partial_current)
    assert.are.equal(2, #calls)
  end)

  it("terminalizes when canceled from progress before filesystem dispatch", function()
    local calls = {}
    fre._set_mutation_adapter(complete_adapter(calls))
    local instance = keep(fre.new({ root = fixture.root }))
    local execution
    local accepted
    execution = instance:execute({ operations = {
      { type = "create_file", path = "never-dispatched" },
    } }, {
      on_progress = function(status)
        if status.state == "running" and status.current ~= nil then
          accepted = execution:cancel()
        end
      end,
    })
    local status = wait_terminal(execution)
    assert.is_true(accepted)
    assert.are.equal("canceled", status.state)
    assert.are.equal(0, status.completed)
    assert.is_false(status.partial_current)
    assert.are.equal(0, #calls)
  end)


  it("best-effort cancels a cancelable current request and never dispatches next", function()
    local calls, cancel_count = {}, 0
    local adapter = complete_adapter(calls)
    adapter.create_file = function(path, done, report)
      calls[#calls + 1] = { name = "create_file", values = { path } }
      report({ phase = "active" })
      return {
        cancel = function()
          cancel_count = cancel_count + 1
          done(nil, { phase = "canceled" }, true, true)
          return true
        end,
      }
    end
    fre._set_mutation_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    local execution = instance:execute({ operations = {
      { type = "create_file", path = "current" },
      { type = "create_file", path = "never" },
    } })
    wait_for(function() return #calls == 1 end)
    assert.is_true(execution:cancel())
    assert.is_false(execution:cancel())
    local status = wait_terminal(execution)
    assert.are.equal("canceled", status.state)
    assert.are.equal(0, status.completed)
    assert.are.equal(2, status.total)
    assert.is_true(status.partial_current)
    assert.are.equal(1, cancel_count)
    assert.are.equal(1, #calls)
    assert.is_false(execution:cancel())
  end)

  it("waits for a noncancelable request to finish, then cancels without advancing", function()
    local calls, current_done = {}, nil
    local adapter = complete_adapter(calls)
    adapter.create_file = function(path, done)
      calls[#calls + 1] = { name = "create_file", values = { path } }
      current_done = done
      return nil
    end
    fre._set_mutation_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    local execution = instance:execute({ operations = {
      { type = "create_file", path = "current" },
      { type = "create_file", path = "never" },
    } })
    wait_for(function() return current_done ~= nil end)
    assert.is_true(execution:cancel())
    assert.are.equal("canceling", execution:get_status().state)
    current_done(nil, { phase = "finished" })
    local status = wait_terminal(execution)
    assert.are.equal("canceled", status.state)
    assert.are.equal(1, status.completed)
    assert.is_false(status.partial_current)
    assert.are.equal(1, #calls)
  end)

  it("ignores duplicate adapter callbacks and protects throwing handlers", function()
    local calls, completion_count, completion_on_main = {}, 0, false
    local notifications = {}
    vim.notify = function(message) notifications[#notifications + 1] = message end
    local adapter = complete_adapter(calls)
    adapter.create_file = function(path, done)
      calls[#calls + 1] = { name = "create_file", values = { path } }
      done(nil)
      done("duplicate failure", { duplicate = true }, true)
    end
    fre._set_mutation_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    local execution = instance:execute({ operations = {
      { type = "create_file", path = "once" },
    } }, {
      on_progress = function() error("progress handler exploded") end,
      on_complete = function(err, result)
        completion_count = completion_count + 1
        completion_on_main = not vim.in_fast_event()
        assert.is_nil(err)
        assert.are.equal("succeeded", result.status)
        error("completion handler exploded")
      end,
    })
    assert.are.equal("succeeded", wait_terminal(execution).state)
    vim.wait(50, function() return false end, 10)
    assert.are.equal(1, completion_count)
    assert.is_true(completion_on_main)
    assert.are.equal(1, #calls)
    assert.are.equal(4, #notifications)
    for _, message in ipairs(notifications) do
      assert.is_truthy(message:find("handler exploded", 1, true))
    end
  end)

  it("returns defensive progress, completion, and status copies with only two methods", function()
    local done_current
    local completion_error
    local completion_result
    local progress_seen
    local adapter = complete_adapter({})
    adapter.copy = function(_, _, _, done, report)
      done_current = done
      report({ nested = { value = "internal" } })
    end
    fre._set_mutation_adapter(adapter)
    local instance = keep(fre.new({ root = fixture.root }))
    local execution = instance:execute({ operations = {
      { type = "copy", from = "a", to = "b", kind = "directory" },
    } }, {
      on_progress = function(status)
        progress_seen = status
        if status.current then status.current.from = "handler-mutated" end
        if status.detail then status.detail.nested.value = "handler-mutated" end
      end,
      on_complete = function(err, result)
        completion_error = err
        completion_result = result
        err.nested.value = "completion-mutated"
        result.current.to = "completion-mutated"
        result.detail.nested.value = "completion-mutated"
      end,
    })
    wait_for(function() return done_current ~= nil and progress_seen ~= nil end)
    local running = execution:get_status()
    assert.are.equal("a", running.current.from)
    assert.are.same({ nested = { value = "internal" } }, running.detail)
    running.current.from = "caller-mutated"
    running.detail.nested.value = "caller-mutated"
    assert.are.equal("a", execution:get_status().current.from)
    assert.are.equal("internal", execution:get_status().detail.nested.value)

    local adapter_error = { nested = { value = "adapter" } }
    done_current(adapter_error, { nested = { value = "failure" } }, true)
    adapter_error.nested.value = "adapter-mutated"
    local failed = wait_terminal(execution)
    assert.are.equal("adapter", failed.error.nested.value)
    assert.are.equal("b", failed.current.to)
    assert.are.equal("failure", failed.detail.nested.value)
    assert.are.equal("completion-mutated", completion_error.nested.value)
    assert.are.equal("completion-mutated", completion_result.current.to)
    assert.are.equal("adapter", execution:get_status().error.nested.value)
    assert.are.equal("b", execution:get_status().current.to)
    assert.are.equal("failure", execution:get_status().detail.nested.value)
    assert.are.equal("function", type(execution.cancel))
    assert.are.equal("function", type(execution.get_status))
    assert.is_nil(execution.state)
    assert.is_nil(next(execution))
  end)

  it("validates only documented handlers before dispatch", function()
    local calls = {}
    fre._set_mutation_adapter(complete_adapter(calls))
    local instance = keep(fre.new({ root = fixture.root }))
    assert.has_error(function()
      instance:execute({ operations = { { type = "create_file", path = "x" } } }, {
        on_progress = function() end,
        extra = true,
      })
    end)
    assert.has_error(function()
      instance:execute({ operations = {} }, { on_complete = true })
    end)
    vim.wait(30, function() return false end, 10)
    assert.are.equal(0, #calls)
  end)

  it("executes directly while creating and load-failed", function()
    local load_callbacks, calls = {}, {}
    fre._set_fs_adapter({
      load = function(_, done) load_callbacks[#load_callbacks + 1] = done end,
    })
    fre._set_mutation_adapter(complete_adapter(calls))
    local creating = keep(fre.new({ root = fixture.root }))
    assert.are.equal("creating", creating:status())
    assert.are.equal("succeeded", wait_terminal(creating:execute({ operations = {
      { type = "create_file", path = "creating-direct" },
    } })).state)
    assert.are.equal("creating", creating:status())
    load_callbacks[1](nil, {}, fixture.root)
    wait_ready(creating)

    local failed = keep(fre.new({ root = fixture.root }))
    load_callbacks[2]("load failed")
    wait_for(function() return failed:status() == "load-failed" end)
    assert.are.equal("succeeded", wait_terminal(failed:execute({ operations = {
      { type = "create_directory", path = "failed-direct" },
    } })).state)
    assert.are.equal("load-failed", failed:status())
  end)

  it("does not alter Fre tree, buffer, refresh, lock, or UI state", function()
    fixture:write("root/existing.txt", "x")
    local root = fixture:path("root")
    local instance = keep(fre.new({ root = root }))
    wait_ready(instance)
    local outside = fixture:path("trusted-outside.txt")
    local before = {
      state = instance:status(),
      lines = lines(instance.bufnr),
      tree = instance.tree,
      root_node = instance.tree.root,
      result = vim.deepcopy(instance:result_value()),
      needs_refresh = instance.sync:is_dirty(),
      modified = vim.bo[instance.bufnr].modified,
      modifiable = vim.bo[instance.bufnr].modifiable,
      current_buf = vim.api.nvim_get_current_buf(),
      write_active = instance.work:is_write_active(),
    }
    assert.are.equal("succeeded", wait_terminal(instance:execute({
      display = { "not inspected" },
      operations = { { type = "create_file", path = outside } },
    })).state)
    assert.is_not_nil(vim.uv.fs_lstat(outside))
    assert.are.equal(before.state, instance:status())
    assert.are.same(before.lines, lines(instance.bufnr))
    assert.are.equal(before.tree, instance.tree)
    assert.are.equal(before.root_node, instance.tree.root)
    assert.are.same(before.result, instance:result_value())
    assert.are.equal(before.needs_refresh, instance.sync:is_dirty())
    assert.are.equal(before.modified, vim.bo[instance.bufnr].modified)
    assert.are.equal(before.modifiable, vim.bo[instance.bufnr].modifiable)
    assert.are.equal(before.current_buf, vim.api.nvim_get_current_buf())
    assert.are.equal(before.write_active, instance.work:is_write_active())
  end)

  it("performs ordinary real file and directory whole-entry mutations", function()
    fixture:write("source.txt", "source contents")
    fixture:write("source-dir/nested/deep.txt", "deep contents")
    local instance = keep(fre.new({ root = fixture.root }))
    wait_ready(instance)

    local made_file = fixture:path("made.txt")
    local made_dir = fixture:path("made-dir")
    local copied_file = fixture:path("copied.txt")
    local copied_dir = fixture:path("copied-dir")
    local moved_file = fixture:path("moved.txt")
    local moved_dir = fixture:path("moved-dir")
    local create_and_copy = instance:execute({ operations = {
      { type = "create_file", path = made_file },
      { type = "create_directory", path = made_dir },
      { type = "copy", from = fixture:path("source.txt"), to = copied_file, kind = "file" },
      { type = "copy", from = fixture:path("source-dir"), to = copied_dir, kind = "directory" },
    } })
    assert.are.equal("succeeded", wait_terminal(create_and_copy).state)
    assert.are.equal("", read_file(made_file))
    assert.are.equal("directory", assert(vim.uv.fs_lstat(made_dir)).type)
    assert.are.equal("source contents", read_file(copied_file))
    assert.are.equal("deep contents", read_file(vim.fs.joinpath(copied_dir, "nested", "deep.txt")))

    local move = instance:execute({ operations = {
      { type = "move", from = copied_file, to = moved_file, kind = "file" },
      { type = "move", from = copied_dir, to = moved_dir, kind = "directory" },
    } })
    assert.are.equal("succeeded", wait_terminal(move).state)
    assert.is_nil(vim.uv.fs_lstat(copied_file))
    assert.is_nil(vim.uv.fs_lstat(copied_dir))
    assert.are.equal("source contents", read_file(moved_file))
    assert.are.equal("deep contents", read_file(vim.fs.joinpath(moved_dir, "nested", "deep.txt")))

    local delete = instance:execute({ operations = {
      { type = "delete", path = moved_file, kind = "file" },
      { type = "delete", path = moved_dir, kind = "directory" },
    } })
    assert.are.equal("succeeded", wait_terminal(delete).state)
    assert.is_nil(vim.uv.fs_lstat(moved_file))
    assert.is_nil(vim.uv.fs_lstat(moved_dir))
    assert.are.equal("source contents", read_file(fixture:path("source.txt")))
    assert.are.equal("deep contents", read_file(fixture:path("source-dir/nested/deep.txt")))
  end)

  it("copies, moves, and deletes symlinks without following them when supported", function()
    local target = fixture:write("target.txt", "target")
    local source_link, link_err = fixture:symlink(target, "source-link")
    if source_link == nil then
      assert.is_truthy(link_err)
      return
    end
    local instance = keep(fre.new({ root = fixture.root }))
    wait_ready(instance)
    local copied = fixture:path("copied-link")
    local moved = fixture:path("moved-link")
    local expected_target = assert(vim.uv.fs_readlink(source_link))

    assert.are.equal("succeeded", wait_terminal(instance:execute({ operations = {
      { type = "copy", from = source_link, to = copied, kind = "symlink" },
    } })).state)
    assert.are.equal("link", assert(vim.uv.fs_lstat(copied)).type)
    assert.are.equal(expected_target, assert(vim.uv.fs_readlink(copied)))

    assert.are.equal("succeeded", wait_terminal(instance:execute({ operations = {
      { type = "move", from = copied, to = moved, kind = "symlink" },
    } })).state)
    assert.is_nil(vim.uv.fs_lstat(copied))
    assert.are.equal("link", assert(vim.uv.fs_lstat(moved)).type)
    assert.are.equal(expected_target, assert(vim.uv.fs_readlink(moved)))

    assert.are.equal("succeeded", wait_terminal(instance:execute({ operations = {
      { type = "delete", path = moved, kind = "symlink" },
    } })).state)
    assert.is_nil(vim.uv.fs_lstat(moved))
    assert.are.equal("target", read_file(target))
  end)

  it("unlinks native special kinds directly and during recursive deletion", function()
    local special_kinds = { "char", "block", "fifo", "socket" }
    local unlinked, rmdir_count = {}, 0
    local fake_uv = {
      cancel = function() return false end,
      fs_unlink = function(target, done)
        unlinked[#unlinked + 1] = target
        done(nil)
        return { request = "unlink" }
      end,
      fs_scandir = function(target, done)
        assert.are.equal("root", target)
        done(nil, { index = 0 })
        return { request = "scandir" }
      end,
      fs_scandir_next = function(handle)
        handle.index = handle.index + 1
        return special_kinds[handle.index]
      end,
      fs_lstat = function(target, done)
        done(nil, { type = vim.fs.basename(target) })
        return { request = "lstat" }
      end,
      fs_rmdir = function(target, done)
        assert.are.equal("root", target)
        rmdir_count = rmdir_count + 1
        done(nil)
        return { request = "rmdir" }
      end,
    }
    local adapter = mutation_fs.new(fake_uv)

    for _, kind in ipairs(special_kinds) do
      local callback_error
      adapter.delete("direct-" .. kind, kind, function(err) callback_error = err end)
      assert.is_nil(callback_error)
    end
    local recursive_error
    adapter.delete("root", "directory", function(err) recursive_error = err end)
    assert.is_nil(recursive_error)
    assert.are.equal(1, rmdir_count)

    local unsupported_error, unsupported_partial
    adapter.delete("custom", "other", function(err, _, partial)
      unsupported_error, unsupported_partial = err, partial
    end)
    assert.is_truthy(unsupported_error:find("unsupported entry kind other", 1, true))
    assert.is_false(unsupported_partial)

    local expected = {}
    for _, kind in ipairs(special_kinds) do
      expected[#expected + 1] = "direct-" .. kind
      expected[#expected + 1] = vim.fs.joinpath("root", kind)
    end
    table.sort(expected)
    table.sort(unlinked)
    assert.are.same(expected, unlinked)
  end)

  it("closes a created file even when cancellation races a successful open", function()
    local open_done, close_done
    local cancel_count, close_count, completion_count = 0, 0, 0
    local completion = {}
    local fake_uv = {
      cancel = function() cancel_count = cancel_count + 1; return true end,
      fs_open = function(_, _, _, done)
        open_done = done
        return { operation = "open" }
      end,
      fs_close = function(fd, done)
        assert.are.equal(42, fd)
        close_count = close_count + 1
        close_done = done
        return { operation = "close" }
      end,
    }
    local adapter = mutation_fs.new(fake_uv)
    local request = adapter.create_file("created", function(err, detail, partial, canceled)
      completion_count = completion_count + 1
      completion = { err = err, detail = detail, partial = partial, canceled = canceled }
    end)
    assert.is_true(request:cancel())
    open_done(nil, 42)
    assert.are.equal(1, close_count)
    close_done(nil)
    assert.are.equal(1, cancel_count)
    assert.are.equal(1, completion_count)
    assert.is_nil(completion.err)
    assert.is_nil(completion.partial)
    assert.is_false(completion.canceled)
  end)


  it("uses exactly one rename request and no fallback after EXDEV", function()
    local rename_count = 0
    local fake_uv = {
      cancel = function() return false end,
      fs_rename = function(from, to, done)
        rename_count = rename_count + 1
        assert.are.equal("from", from)
        assert.are.equal("to", to)
        done("EXDEV: cross-device link not permitted")
        return { request = true }
      end,
    }
    local adapter = mutation_fs.new(fake_uv)
    local callback_count, callback_error = 0, nil
    adapter.move("from", "to", function(err)
      callback_count = callback_count + 1
      callback_error = err
    end)
    assert.are.equal(1, rename_count)
    assert.are.equal(1, callback_count)
    assert.is_truthy(callback_error:find("unsupported cross-device move", 1, true))
    assert.is_truthy(callback_error:find("EXDEV", 1, true))
    assert.is_nil(fake_uv.fs_copyfile)
    assert.is_nil(fake_uv.fs_unlink)
  end)
end)
