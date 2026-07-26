local uv = vim.uv

local M = {}

local function error_message(action, subject, err)
  return string.format("%s %s: %s", action, subject, err or "unknown error")
end

local function canceled_error(err)
  local text = tostring(err or ""):lower()
  return text:find("ecanceled", 1, true) ~= nil
    or text:find("ecancelled", 1, true) ~= nil
    or text:find("operation canceled", 1, true) ~= nil
    or text:find("operation cancelled", 1, true) ~= nil
end

local function new_controller(uv_api, done, report)
  local state = {
    current = nil,
    current_token = 0,
    cancel_requested = false,
    effect = false,
    finished = false,
    detail = nil,
  }

  local function publish(detail)
    state.detail = detail
    if report then report(detail) end
  end

  local function finish(err, partial_current, canceled)
    if state.finished then return end
    state.finished = true
    state.current = nil
    done(err, state.detail, partial_current, canceled == true)
  end

  local function start_request(start, callback, allow_after_cancel)
    if state.finished then return end
    if state.cancel_requested and not allow_after_cancel then
      finish(nil, state.effect, true)
      return
    end

    state.current_token = state.current_token + 1
    local token = state.current_token
    local called = false
    local ok, request_or_err = pcall(start, function(...)
      called = true
      if state.current_token == token then state.current = nil end
      callback(...)
    end)
    if not ok then
      callback(request_or_err)
      return
    end
    if not called and state.current_token == token then
      state.current = request_or_err
    end
  end

  local function stop_for_cancel(err, partial_current)
    if not state.cancel_requested or err == nil or not canceled_error(err) then return false end
    local partial = partial_current
    if partial == nil then partial = state.effect end
    finish(nil, partial, true)
    return true
  end

  local request = {}
  function request:cancel()
    if state.finished or state.cancel_requested then return false end
    state.cancel_requested = true
    if state.current == nil then return false end
    local ok, accepted = pcall(uv_api.cancel, state.current)
    return ok and accepted ~= false
  end

  return state, request, start_request, stop_for_cancel, finish, publish
end

local function simple_request(uv_api, action, subject, start, done, report, error_partial)
  local state, request, start_request, stop_for_cancel, finish, publish =
    new_controller(uv_api, done, report)
  publish({ action = action, path = subject })
  start_request(start, function(err)
    if stop_for_cancel(err, err == nil and false or error_partial) then return end
    if err ~= nil then
      finish(error_message(action, subject, err), error_partial, false)
      return
    end
    state.effect = true
    finish(nil, nil, false)
  end)
  return request
end

local function adapter_for(uv_api)
  local adapter = {}

  function adapter.create_file(path, done, report)
    local state, request, start_request, stop_for_cancel, finish, publish =
      new_controller(uv_api, done, report)
    publish({ action = "create_file", path = path })
    start_request(function(callback)
      return uv_api.fs_open(path, "wx", 438, callback)
    end, function(open_err, fd)
      if stop_for_cancel(open_err, false) then return end
      if open_err ~= nil or fd == nil then
        finish(error_message("cannot create file", path, open_err), false, false)
        return
      end
      state.effect = true
      local function close_done(close_err)
        if close_err ~= nil then
          if state.cancel_requested and canceled_error(close_err) then
            local close_ok, cleanup_result = pcall(uv_api.fs_close, fd)
            if not close_ok or cleanup_result == false then
              finish(error_message(
                "cannot close created file", path, close_ok and "cleanup failed" or cleanup_result
              ), true, false)
            else
              finish(nil, false, false)
            end
            return
          end
          finish(error_message("cannot close created file", path, close_err), true, false)
          return
        end
        finish(nil, nil, false)
      end
      start_request(function(callback)
        return uv_api.fs_close(fd, callback)
      end, close_done, true)
    end)
    return request
  end

  function adapter.create_directory(path, done, report)
    return simple_request(uv_api, "cannot create directory", path, function(callback)
      return uv_api.fs_mkdir(path, 493, callback)
    end, done, report, false)
  end

  function adapter.move(from, to, done, report)
    local subject = from .. " -> " .. to
    return simple_request(uv_api, "cannot move", subject, function(callback)
      return uv_api.fs_rename(from, to, callback)
    end, done, report, false)
  end

  function adapter.copy(from, to, kind, done, report)
    local state, request, start_request, stop_for_cancel, finish, publish =
      new_controller(uv_api, done, report)

    local copy_entry
    local function fail_copy(err, partial)
      finish(error_message("cannot copy", from .. " -> " .. to, err), partial, false)
    end

    copy_entry = function(source, target, entry_kind, callback)
      if state.cancel_requested then
        finish(nil, state.effect, true)
        return
      end
      publish({ action = "copy", from = source, to = target, kind = entry_kind })

      if entry_kind == "file" then
        start_request(function(done_copy)
          local flags = (uv_api.constants and uv_api.constants.COPYFILE_EXCL) or 1
          return uv_api.fs_copyfile(source, target, flags, done_copy)
        end, function(err)
          if stop_for_cancel(err, err == nil and false or "unknown") then return end
          if err ~= nil then callback(err, "unknown"); return end
          state.effect = true
          callback(nil)
        end)
        return
      end

      if entry_kind == "symlink" then
        start_request(function(done_readlink)
          return uv_api.fs_readlink(source, done_readlink)
        end, function(read_err, link_target)
          if stop_for_cancel(read_err, false) then return end
          if read_err ~= nil or link_target == nil then callback(read_err or "missing link target", false); return end

          local function create_link(flags)
            start_request(function(done_link)
              return uv_api.fs_symlink(link_target, target, flags, done_link)
            end, function(link_err)
              if stop_for_cancel(link_err, false) then return end
              if link_err ~= nil then callback(link_err, false); return end
              state.effect = true
              callback(nil)
            end)
          end

          if package.config:sub(1, 1) ~= "\\" or type(uv_api.fs_stat) ~= "function" then
            create_link(nil)
            return
          end
          start_request(function(done_stat)
            return uv_api.fs_stat(source, done_stat)
          end, function(_, stat)
            if state.cancel_requested then finish(nil, state.effect, true); return end
            create_link(stat and stat.type == "directory" and { dir = true } or nil)
          end)
        end)
        return
      end

      if entry_kind ~= "directory" then
        callback("unsupported entry kind " .. tostring(entry_kind), false)
        return
      end

      start_request(function(done_mkdir)
        return uv_api.fs_mkdir(target, 493, done_mkdir)
      end, function(mkdir_err)
        if stop_for_cancel(mkdir_err, false) then return end
        if mkdir_err ~= nil then callback(mkdir_err, false); return end
        state.effect = true
        start_request(function(done_scan)
          return uv_api.fs_scandir(source, done_scan)
        end, function(scan_err, handle)
          if stop_for_cancel(scan_err, state.effect) then return end
          if scan_err ~= nil or handle == nil then callback(scan_err or "cannot scan source", true); return end
          local names = {}
          while true do
            local name = uv_api.fs_scandir_next(handle)
            if name == nil then break end
            names[#names + 1] = name
          end
          local index = 0
          local function copy_next()
            if state.cancel_requested then finish(nil, state.effect, true); return end
            index = index + 1
            local name = names[index]
            if name == nil then callback(nil); return end
            local child_source = vim.fs.joinpath(source, name)
            local child_target = vim.fs.joinpath(target, name)
            start_request(function(done_lstat)
              return uv_api.fs_lstat(child_source, done_lstat)
            end, function(stat_err, stat)
              if stop_for_cancel(stat_err, state.effect) then return end
              if stat_err ~= nil or stat == nil then callback(stat_err or "cannot stat source entry", true); return end
              local child_kind = stat.type == "link" and "symlink" or stat.type
              copy_entry(child_source, child_target, child_kind, function(child_err, child_partial)
                if child_err ~= nil then callback(child_err, child_partial == false and true or child_partial); return end
                copy_next()
              end)
            end)
          end
          copy_next()
        end)
      end)
    end

    copy_entry(from, to, kind, function(err, partial)
      if err ~= nil then fail_copy(err, partial == nil and state.effect or partial); return end
      if state.cancel_requested then finish(nil, false, false); return end
      finish(nil, nil, false)
    end)
    return request
  end

  function adapter.delete(path, kind, done, report)
    local state, request, start_request, stop_for_cancel, finish, publish =
      new_controller(uv_api, done, report)

    local delete_entry
    delete_entry = function(target, entry_kind, callback)
      if state.cancel_requested then finish(nil, state.effect, true); return end
      publish({ action = "delete", path = target, kind = entry_kind })

      if entry_kind == "file" or entry_kind == "symlink" then
        start_request(function(done_unlink)
          return uv_api.fs_unlink(target, done_unlink)
        end, function(err)
          if stop_for_cancel(err, state.effect) then return end
          if err ~= nil then callback(err); return end
          state.effect = true
          callback(nil)
        end)
        return
      end
      if entry_kind ~= "directory" then
        callback("unsupported entry kind " .. tostring(entry_kind))
        return
      end

      start_request(function(done_scan)
        return uv_api.fs_scandir(target, done_scan)
      end, function(scan_err, handle)
        if stop_for_cancel(scan_err, state.effect) then return end
        if scan_err ~= nil or handle == nil then callback(scan_err or "cannot scan directory"); return end
        local names = {}
        while true do
          local name = uv_api.fs_scandir_next(handle)
          if name == nil then break end
          names[#names + 1] = name
        end
        local index = 0
        local function delete_next()
          if state.cancel_requested then finish(nil, state.effect, true); return end
          index = index + 1
          local name = names[index]
          if name == nil then
            start_request(function(done_rmdir)
              return uv_api.fs_rmdir(target, done_rmdir)
            end, function(rmdir_err)
              if stop_for_cancel(rmdir_err, state.effect) then return end
              if rmdir_err ~= nil then callback(rmdir_err); return end
              state.effect = true
              callback(nil)
            end)
            return
          end
          local child = vim.fs.joinpath(target, name)
          start_request(function(done_lstat)
            return uv_api.fs_lstat(child, done_lstat)
          end, function(stat_err, stat)
            if stop_for_cancel(stat_err, state.effect) then return end
            if stat_err ~= nil or stat == nil then callback(stat_err or "cannot stat directory entry"); return end
            local child_kind = stat.type == "link" and "symlink" or stat.type
            delete_entry(child, child_kind, function(child_err)
              if child_err ~= nil then callback(child_err); return end
              delete_next()
            end)
          end)
        end
        delete_next()
      end)
    end

    delete_entry(path, kind, function(err)
      if err ~= nil then
        finish(error_message("cannot delete", path, err), state.effect, false)
        return
      end
      if state.cancel_requested then finish(nil, false, false); return end
      finish(nil, nil, false)
    end)
    return request
  end

  return adapter
end

M.new = adapter_for
M.default = adapter_for(uv)

return M
