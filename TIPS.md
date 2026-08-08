# Fre 配置技巧

本文示例只使用公开 API。mapping callback 中的 `ctx`、`ctx.view` 和 `fre.view.inspect()` 结果都只适合同步使用；不要缓存后延迟执行。

## Buffer 身份与状态栏

Fre buffer 不是普通文件 buffer。第三方状态栏或 tabline 应通过 `filetype` 和 `vim.b.fre` 识别它，不要把 buffer name 当成目录路径。

| 项目 | 值 | 用途 |
| --- | --- | --- |
| `buftype` | `acwrite` | buffer 没有对应磁盘文件，`:write` 由 Fre 的 `BufWriteCmd` 处理 |
| `filetype` / `syntax` | `fre` | filetype 检测、语法和插件集成 |
| buffer name | `fre://<instance-id>` | Instance 身份 URI，不是文件系统路径 |
| `bufhidden` | `hide` | 窗口离开后允许保留隐藏 buffer |
| `buflisted` / `swapfile` | `false` / `false` | 不进入普通 buffer 列表，也不创建 swapfile |

每个存活的 Fre buffer 都只提供核心身份元数据：

```lua
vim.b.fre == {
  version = 1,
  instance_id = instance.id,
  root = instance.root,       -- 规范化后的绝对路径
}
```

`root` 才是浏览目录。需要默认-managed Instance API 时使用 `require("fre").get_instance(bufnr)`，不要解析 `fre://<instance-id>`。standalone 或自定义 Manager 的 Instance 不会被默认 lookup 认领；调用方应保留自己的 identity-keyed 记录。GC group、TTL、capacity 和 Manager affinity 不属于 buffer metadata；默认-managed group migration 使用 `require("fre").set_group(instance, group)`，不存在 `instance:setGroup()`。

### lualine：全局 cwd 内显示相对路径，否则显示绝对路径

lualine 内置 `filename` 组件从 buffer name 派生显示值；视 `path` 配置，它可能只显示 Instance ID，也可能显示 `fre://<instance-id>`，但都不是浏览 root。下面的自定义组件改读 `vim.b.fre.root`：root 位于 Neovim **全局 cwd** 内时显示相对路径，否则显示 Fre 保存的绝对路径。`getcwd(-1, -1)` 明确读取全局 cwd，不受 `:lcd` 或 `:tcd` 影响。

```lua
local function fre_metadata(bufnr)
  if vim.bo[bufnr].filetype ~= "fre" then return nil end
  local metadata = vim.b[bufnr].fre
  return type(metadata) == "table" and metadata or nil
end

local function is_fre_buffer()
  return fre_metadata(vim.api.nvim_get_current_buf()) ~= nil
end

local function fre_lualine_path()
  local metadata = fre_metadata(vim.api.nvim_get_current_buf())
  if not metadata then return "" end

  local global_cwd = vim.fs.normalize(vim.fn.getcwd(-1, -1))
  local relative = vim.fs.relpath(global_cwd, metadata.root)
  local display = relative or metadata.root
  display = display:gsub("%%", "%%%%")
  return display .. (vim.bo.modified and " [+]" or "")
end

require("lualine").setup({
  sections = {
    lualine_c = {
      { fre_lualine_path, cond = is_fre_buffer },
      {
        "filename",
        path = 1,
        cond = function() return not is_fre_buffer() end,
      },
    },
  },
})
```

当 root 等于全局 cwd 时显示 `.`；位于其下时显示如 `src`；不在其下或位于其他 Windows drive 时显示完整绝对路径。把这两个 component 合并到已有的 `lualine_c` 即可；需要 inactive statusline 时也可放入 `inactive_sections.lualine_c`。

### tabby：Fre buffer 只显示 `Fre`

Tabby 的 `buf_name.override` 会同时影响 `win.buf_name()` 和 `buf.name()`。返回 `nil` 会继续使用 Tabby 原来的命名逻辑：

```lua
require("tabby").setup({
  preset = "active_wins_at_tail",
  option = {
    buf_name = {
      override = function(bufnr)
        if vim.bo[bufnr].filetype == "fre"
            and type(vim.b[bufnr].fre) == "table" then
          return "Fre"
        end
      end,
    },
  },
})
```

若已有自定义 `line`，只需把同一个 `option.buf_name.override` 合并到现有 `setup()`，不需要更改 `win.buf_name()` 的调用点。

## 事件与 cwd 联动

### Fre 发出的全部 User event

核心 Instance 精确发出以下六个公共 `User` event：

| Event | 触发时机 | `args.data` |
| --- | --- | --- |
| `User FreInstanceCreated` | 核心组合和 initial load 启动后，构造返回前 | `{ instance_id, bufnr }` |
| `User FreReady` | 每次 initial-load attempt 提交 ready/load-failed，且 `when_ready()` observer 已运行后 | `{ instance_id, bufnr, error, result }` |
| `User FreInstancePresentationChanged` | 实际 View 数量跨越 0 的边界 | `{ instance_id, bufnr, visible }` |
| `User FreInstanceActivityChanged` | `refresh`、`write` 或 `execution` 活动边界改变 | `{ instance_id, bufnr, activity, active }` |
| `User FreInstanceDestroying` | lifecycle 提交 destroying 后、局部清理前 | `{ instance_id, bufnr }` |
| `User FreInstanceDestroyed` | 核心 lifecycle、局部资源和 buffer 都进入终态后 | `{ instance_id, bufnr }` |

`FreInstanceDestroyed` 发出前，上表所列核心状态均已进入终态。默认 Manager 在消费该事件时才删除 managed lookup 和 GC records；在默认 Manager observer 之前运行的任意 observer 在事件 dispatch 期间仍可能通过 `fre.get_instance*()` 解析到已销毁的 Instance。默认 Manager 消费后以及事件分发完成后，managed lookup 不再存在。

`FreReady` 成功时 `error == nil`，`result` 的形状如下；失败时 `error` 非空且 `result == nil`：

```lua
{
  root = instance.root,
  children = {
    { id = 2, name = "src", path = "/project/src", kind = "directory" },
    -- id 是 opaque node identity，不要依赖示例值或推断分配顺序。
    -- ...
  },
}
```

监听示例：

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "FreReady",
  callback = function(args)
    local data = args.data
    local instance = require("fre").get_instance_by_id(data.instance_id)

    if data.error then
      vim.notify(tostring(data.error), vim.log.levels.ERROR)
    elseif instance then
      vim.notify("Fre ready: " .. data.result.root)
    end
  end,
})
```


Fre 没有 `FreOpen`、`FreHide`、`FreDestroy` 或其他兼容别名，也不发布普通 refresh 完成事件。`BufUnload`、`BufWipeout`、`BufWriteCmd`、`BufWinEnter` 等是 Fre 使用或响应的 Neovim 原生事件，不是 Fre 对外发出的 `User` event；不要把内部 autocmd 当成稳定插件协议。

### 进入 Fre buffer 时自动 `:lcd` 到 root

目录切换属于用户策略，Fre 本身不会自动执行 `:cd`、`:lcd` 或 `:tcd`。要让每个显示 Fre 的窗口拥有自己的 cwd，可监听 Neovim 原生 `BufEnter`：

```lua
local group = vim.api.nvim_create_augroup("FreAutoLcd", { clear = true })

vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(args)
    local metadata = vim.b[args.buf].fre
    if type(metadata) ~= "table" or type(metadata.root) ~= "string" then
      return
    end
    vim.api.nvim_cmd({ cmd = "lcd", args = { metadata.root } }, {})
  end,
})
```

需要 tab-local cwd 时把 `lcd` 改成 `tcd`。需要全局 cwd 时应明确使用 `vim.api.nvim_set_current_dir(metadata.root)`；不要用无参数 `getcwd()` 猜测当前使用的是哪一级 cwd。

## Actions 与推荐映射

`require("fre.actions")` 当前公开以下入口。除表中列出的字段外，selection/open 类 options 出现未知字段会报错。

| Action | Options / 参数 | 说明 |
| --- | --- | --- |
| `context()` | 无 | 在当前 Fre window 同步生成 ActionContext |
| `jump_to_path(ctx)` | 无 | 把 entry/navigation 行光标移到 path 字段起点 |
| `expand(ctx)` | 无 | 展开当前目录 |
| `collapse(ctx)` | 无 | 折叠当前目录 |
| `toggle_expand(ctx)` | 无 | 切换当前目录展开状态 |
| `collapse_all(ctx)` | 无 | 折叠 Instance 中全部目录 |
| `reveal(ctx)` | 无 | 对当前 entry 调用 `instance:reveal()` |
| `open(ctx, opts)` | `{ layout? }` | 打开或聚焦当前 Instance |
| `hidden(ctx)` | 无 | 隐藏该 Instance 在当前 tab 中的全部 View |
| `toggle(ctx, opts)` | `{ layout? }` | 当前 tab 内严格切换显示/隐藏 |
| `set_hidden_file(ctx, opts)` | `{ hidden_file = boolean }` | 明确设置点文件显示状态 |
| `toggle_hidden_file(ctx)` | 无 | 切换点文件显示状态 |
| `hide_columns(ctx, ids)` | string 数组 | 隐藏当前 Instance 的 column group |
| `show_columns(ctx, ids)` | string 数组 | 显示当前 Instance 的 column group |
| `toggle_columns(ctx, ids)` | string 数组 | 在 compact/detailed group 状态间切换 |
| `is_column_visible(ctx, id)` | string ID | 查询当前 column 可见性 |
| `refresh(ctx)` | 无 | 刷新；buffer modified 时会强制丢弃草稿 |
| `select(ctx, opts)` | `{ target_winid?, hide_source?, instance? }` | 在精确目标 window 选择 |
| `tab_select(ctx, opts)` | `{ hide_source?, instance? }` | 在新 tab 选择；API 名不是 `select_tab` |
| `split_select(ctx, opts)` | `{ layout, anchor_winid?, hide_source?, instance? }` | 相对精确 anchor 创建 split 后选择 |
| `destroy(ctx)` | 无 | 销毁整个 Instance、全部 Views 和 buffer |
| `confirm(ctx, display, callback)` | 文本数组、回调 | 低层确认 UI |
| `write(ctx)` | 无 | 完整 prepare/confirm/execute/reconcile 写入流程 |

`opts.instance` 只会传给 directory destination。目标以 source 的完整 effective appearance 与当前 hidden 状态为基线，再按普通 Instance merge 规则应用显式覆盖；action 最后用所选目标拥有的 `root` 和 `expanded` 覆盖调用方值。source 创建后的 setup 变化不会泄漏到该 baseline，GC 则继续使用显式目标 policy 或当前 Manager 默认值。source 与 destination 是构建后互不同步的 independent peers。file/symlink selection 传入 `opts.instance` 会报错。`hide_source` 默认为 `false`，只在选择成功提交后隐藏 source 所在 tab 中该 Instance 的全部 View。

内置默认映射只有 `<CR>`、`zv`、`zc`、`za`、`zM`、`q`、`g.` 和 `R`。下面关闭默认映射并显式配置一套日常使用所需的 actions，也展示 `tab_select` 和 float-safe `split_select`：

```lua
local fre = require("fre")
local actions = require("fre.actions")

local function split_right(ctx)
  local inspected = ctx.view

  local anchor = ctx.winid
  if inspected.layout.position == "float" then
    anchor = inspected.origin_winid
    if not anchor or not vim.api.nvim_win_is_valid(anchor) then
      error("fre: float origin is no longer valid")
    end
  end

  return actions.split_select(ctx, {
    layout = { position = "right", size = 0.5 },
    anchor_winid = anchor,
  })
end

fre.setup({
  use_mapping_default = false,
  mapping = {
    n = {
      ["<CR>"] = actions.select,
      ["<C-t>"] = function(ctx)
        return actions.tab_select(ctx, { hide_source = false })
      end,
      ["<C-v>"] = split_right,

      ["zv"] = actions.expand,
      ["zc"] = actions.collapse,
      ["za"] = actions.toggle_expand,
      ["zM"] = actions.collapse_all,

      ["g0"] = actions.jump_to_path,
      ["g."] = actions.toggle_hidden_file,
      ["gh"] = function(ctx)
        return actions.set_hidden_file(ctx, { hidden_file = false })
      end,
      ["gH"] = function(ctx)
        return actions.set_hidden_file(ctx, { hidden_file = true })
      end,

      ["R"] = actions.refresh,
      ["q"] = actions.hidden,
      ["Q"] = actions.destroy,
    },
  },
})
```

`context()` 用于 Fre mapping 系统之外的同步 action 调用；`open()`/`toggle()` 更适合全局快捷键；对当前可见行映射 `reveal()` 通常是冗余的；`:write` 已调用 `write()`；`confirm()` 只用于自定义写入 UI。因此推荐映射没有为这些低层或全局入口强行占键。`R` 和 `Q` 都可能丢弃未保存草稿。

## 全局 cwd 的单实例 float

下面是一份独立的完整示例。全局 `-` 根据 Neovim global cwd 切换 float 文件管理器：

- 缓存一个用户侧的 `global_instance`。
- 每次打开前比较 `global_instance.root` 与当前 global cwd。
- root 不同就销毁旧 Instance，再为新 root 创建 Instance。
- global Instance 内按 `q` 直接销毁；普通 Fre Instance 的 `q` 仍只隐藏。
- `<leader>cd` 执行 global `:cd` 到当前 Fre root，并把当前 Instance 接管为 `global_instance`。

```lua
local fre = require("fre")
local actions = require("fre.actions")

local global_instance
local float_layout = {
  position = "float",
  width = 0.8,
  height = 0.8,
  border = "rounded",
}

local function is_alive(instance)
  return instance ~= nil
    and fre.get_instance_by_id(instance.id) == instance
end

local function global_cwd()
  return vim.fs.normalize(vim.fn.getcwd(-1, -1))
end

local function close_or_destroy(ctx)
  if global_instance ~= ctx.instance then
    return actions.hidden(ctx)
  end

  local instance = ctx.instance
  local result = actions.destroy(ctx)
  if global_instance == instance then global_instance = nil end
  return result
end

local function cd_and_adopt(ctx)
  local previous = global_instance
  vim.api.nvim_set_current_dir(ctx.instance.root)

  if is_alive(previous) and previous ~= ctx.instance then
    previous:destroy()
  end

  global_instance = ctx.instance
  return ctx.instance
end

-- 合并到你的唯一一次 fre.setup() 调用中。
fre.setup({
  mapping = {
    n = {
      ["q"] = close_or_destroy,
      ["<leader>cd"] = cd_and_adopt,
    },
  },
})

local function ensure_global_instance()
  local root = global_cwd()

  if not is_alive(global_instance) then
    global_instance = nil
  elseif global_instance.root ~= root then
    global_instance:destroy()
    global_instance = nil
  end

  if not global_instance then
    global_instance = fre.new({
      root = root,
      layout = float_layout,
    })
  end

  return global_instance
end

vim.keymap.set("n", "-", function()
  ensure_global_instance():toggle(float_layout)
end, { desc = "Toggle Fre for global cwd" })
```

示例把文中的 `<cd>` 具体配置为 `<leader>cd`，可以替换成自己的 LHS。`vim.fn.getcwd(-1, -1)` 始终读取 global cwd；若改用无参数 `getcwd()`，window-local 或 tab-local cwd 会改变这个单例的 root 选择。

`destroy()` 会关闭该 Instance 在全部 tab 中的 Views，并删除 buffer；它不会像默认 `q = actions.hidden` 那样保留未写草稿。root 变化和接管其他 Instance 时，上例也会销毁旧 global Instance。若需要保留草稿，应先 `:write`，或把策略改为 `hidden()`。隐藏期间 Instance 被 GC 销毁时，`is_alive()` 会在下次按 `-` 时自动创建新的 Instance。

一个 Instance 可以在同一 tab 或多个 tab 中存在多个 View，因此这里的“单实例”不等于“单窗口”；`toggle(float_layout)` 在当前 tab 有任意 View 时会全部隐藏，否则打开一个。


## Oil-style 动态 `<CR>`

下面的 `<CR>` 在普通 View 中沿用默认选择行为。在 float View 中，目录和 `../` 继续替换当前 float 内的 Instance；file 或 symlink 则安装到该 float 记录的精确 origin，成功提交后隐藏 source float。

```lua
local fre = require("fre")
local actions = require("fre.actions")


local function oil_style_select(ctx)
  local inspected = ctx.view
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

一个快捷键始终选择到 captured source window；另一个使用 exact `ctx.view`，并选择到它记录的 origin。origin 缺失或失效属于错误，不从当前焦点或其他窗口推断目标。

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
        local inspected = ctx.view
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

`split_select` 从 float source 调用时必须显式传入同 tab 的 ordinary `anchor_winid`。使用 exact `ctx.view` 的 origin，不从焦点、窗口编号或窗口列表做 fallback。

```lua
local fre = require("fre")
local actions = require("fre.actions")

fre.setup({
  mapping = {
    n = {
      ["<C-v>"] = function(ctx)
        local inspected = ctx.view
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

`ctx.view` 是 mapping exact source window 的 copied snapshot。`fre.view.inspect()` 适合非 mapping 场景：当前 exact View 优先，否则返回请求 tab 的唯一候选；多个非当前候选会报错，应改传 `{ winid = ... }`。任何 snapshot 都不应缓存延迟使用，window/anchor 的最终有效性仍由 action preflight 校验。
