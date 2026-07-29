local uv = vim.uv
local MAX_CONCURRENT_STATS = 32

local M = {}

local function error_message(action, path, err)
  return string.format("%s %s: %s", action, path, err or "unknown error")
end

local function default_load(root, done)
  uv.fs_realpath(root, function(real_err, real_root)
    if real_err or not real_root then
      done(error_message("cannot resolve root", root, real_err))
      return
    end

    uv.fs_stat(real_root, function(stat_err, stat)
      if stat_err or not stat then
        done(error_message("cannot stat root", root, stat_err))
        return
      end
      if stat.type ~= "directory" then
        done(error_message("root is not a directory", root, stat.type))
        return
      end

      uv.fs_scandir(real_root, function(scan_err, handle)
        if scan_err or not handle then
          done(error_message("cannot scan root", root, scan_err))
          return
        end

        local pending = {}
        while true do
          local name, kind = uv.fs_scandir_next(handle)
          if not name then
            break
          end
          if name:find("[\r\n]") then
            done(error_message("unsupported entry name", name, "contains CR or LF"))
            return
          end
          pending[#pending + 1] = { name = name, kind = kind }
        end

        local children = {}
        local errors = {}
        local total = #pending
        if total == 0 then
          done(nil, children, real_root)
          return
        end

        local initial_count = math.min(MAX_CONCURRENT_STATS, total)
        local next_index = initial_count + 1
        local completed = 0
        local finished = false

        local function finish_if_ready()
          if finished or completed < total then
            return
          end
          finished = true
          for error_index = 1, total do
            if errors[error_index] then
              done(errors[error_index])
              return
            end
          end
          done(nil, children, real_root)
        end

        local load_entry
        load_entry = function(index)
          local entry = pending[index]
          local child_path = vim.fs.joinpath(real_root, entry.name)
          uv.fs_lstat(child_path, function(child_err, child_stat)
            if child_err or not child_stat then
              errors[index] = error_message("cannot stat entry", child_path, child_err)
            else
              local child_kind = child_stat.type
              if child_kind == "directory" then
                entry.kind = "directory"
              elseif child_kind == "link" then
                entry.kind = "symlink"
              elseif child_kind == "file" then
                entry.kind = "file"
              else
                entry.kind = child_kind or entry.kind or "other"
              end
              children[index] = {
                name = entry.name,
                kind = entry.kind,
                real_path = child_path,
                stat = child_stat,
              }
            end

            completed = completed + 1
            if next_index <= total then
              local queued_index = next_index
              next_index = next_index + 1
              load_entry(queued_index)
            end
            finish_if_ready()
          end)
        end

        for index = 1, initial_count do
          load_entry(index)
        end
      end)
    end)
  end)
end

M.default = {
  load = default_load,
}

return M
