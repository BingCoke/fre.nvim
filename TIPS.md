# Fre 配置技巧

本文示例只使用公开 API。mapping callback 中的 `ctx` 和 `fre.view.inspect()` 结果都只适合同步使用；不要缓存后延迟执行。

## Oil-style 动态 `<CR>`

下面的 `<CR>` 在普通 View 中沿用默认选择行为。在 float View 中，目录和 `../` 继续替换当前 float 内的 Instance；file 或 symlink 则安装到该 float 记录的精确 origin，成功提交后隐藏 source float。

```lua
local fre = require("fre")
local actions = require("fre.actions")

local function active_view(ctx)
  local inspected = fre.view.inspect(ctx.instance, ctx.tabpage)
  if not inspected then error("fre: source View is no longer active") end
  return inspected
end

local function oil_style_select(ctx)
  local inspected = active_view(ctx)
  local entry = ctx.entry
  if inspected.layout.position == "float" and entry
      and (entry.kind == "file" or entry.kind == "symlink") then
    if not inspected.origin_winid
        or not vim.api.nvim_win_is_valid(inspected.origin_winid) then
      error("fre: float origin is no longer valid")
    end
    return actions.select(ctx, {
      target_winid = inspected.origin_winid,
      hide_source = true,
    })
  end
  return actions.select(ctx)
end

fre.setup({
  mapping = {
    n = {
      ["<CR>"] = oil_style_select,
    },
  },
})
```

Instance-specific `mapping.n` 会与 setup/default mappings 合并。覆盖同一个 LHS（如 `<CR>`）即可替换该键，无需复制其他默认映射，也无需扩展 ActionContext。

## 固定 source 与 origin 的独立快捷键

一个快捷键始终选择到 captured source window；另一个始终同步查询 active View，并选择到它记录的 exact origin。origin 缺失或失效属于错误，不从当前焦点或其他窗口推断目标。

```lua
local fre = require("fre")
local actions = require("fre.actions")

fre.setup({
  mapping = {
    n = {
      ["<C-s>"] = function(ctx)
        return actions.select(ctx, { target_winid = ctx.winid })
      end,
      ["<C-o>"] = function(ctx)
        local inspected = fre.view.inspect(ctx.instance, ctx.tabpage)
        if not inspected then error("fre: source View is no longer active") end
        if not inspected.origin_winid
            or not vim.api.nvim_win_is_valid(inspected.origin_winid) then
          error("fre: View origin is no longer valid")
        end
        return actions.select(ctx, {
          target_winid = inspected.origin_winid,
          hide_source = true,
        })
      end,
    },
  },
})
```

## 从 float 创建 split

`split_select` 从 float source 调用时必须显式传入同 tab 的 ordinary `anchor_winid`。使用当前 active View 的 origin，不从焦点、窗口编号或窗口列表做 fallback。

```lua
local fre = require("fre")
local actions = require("fre.actions")

fre.setup({
  mapping = {
    n = {
      ["<C-v>"] = function(ctx)
        local inspected = fre.view.inspect(ctx.instance, ctx.tabpage)
        if not inspected then error("fre: source View is no longer active") end
        local anchor = inspected.origin_winid
        if not anchor or not vim.api.nvim_win_is_valid(anchor) then
          error("fre: View origin is no longer valid")
        end
        return actions.split_select(ctx, {
          layout = { position = "right", size = 0.5 },
          anchor_winid = anchor,
        })
      end,
    },
  },
})
```

`fre.view.inspect()` 返回的是当次调用的 copied snapshot。它返回 `nil` 表示该 Instance 在请求 tab 中没有有效 active View；此时应直接返回或报错，不应使用旧 snapshot。上面的错误检查只负责给 mapping 提供更明确的信息，window/anchor 的最终有效性仍由 action preflight 校验。
