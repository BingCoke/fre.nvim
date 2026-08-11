# fre.nvim

`fre.nvim` 是一个以可编辑 Neovim buffer 表示本地文件系统的文件管理器。

目录以相对于实例根目录的完整路径显示，并可在同一个 buffer 中展开：

```text
../
src/
src/a.lua
src/lib/
src/lib/b.lua
tests/
```

成功加载后，第一行始终是导航行：普通目录显示 `../`，文件系统根目录显示 `/`。Windows drive root 和 UNC share root 也只在界面中显示 `/`，内部路径保持平台原值。

你可以像编辑普通文本一样重命名、移动、复制、创建或删除这些行，然后执行 `:write`。Fre 会先生成操作计划并请求确认，再串行修改文件系统，最后按文件系统真实状态刷新 buffer。

## 要求

- 支持 `vim.uv` 和现代 Lua API 的 Neovim。
- 当前开发和完整测试环境为 Neovim `0.12.4`；项目尚未声明更早版本的最低兼容范围。
- 仅支持本地文件系统。
- 运行时没有强制 Lua 依赖；推荐安装 `nvim-web-devicons` 并使用 Nerd Font，以获得文件类型图标和颜色。依赖缺失时 icon 列回退为 `d/f/l`；Plenary 只用于测试。

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim) 的完整最小配置：

```lua
require("lazy").setup({
  {
    "BingCoke/fre.nvim",
    lazy = false,
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("fre").setup({})
    end,
  },
})
```

已有 `require("lazy").setup()` 配置时，只需把上面的内层 plugin spec 加入现有列表。

不使用插件管理器时，将仓库加入 `runtimepath`：

```lua
vim.opt.runtimepath:prepend("/absolute/path/to/fre.nvim")
require("fre").setup({})
```

## 快速开始

### 替代默认目录浏览器

最小配置：

```lua
require("fre").setup({})
```

`default_file_explorer` 默认为 `true`。配置加载后，使用以下任一方式进入目录：

```vim
:edit .
:edit /absolute/path/to/project
```

也可以直接执行 `nvim .`。Fre 会接管本地目录 buffer，并禁用当前 Neovim 进程中的 netrw 目录浏览器。

`default_file_explorer` 只由第一次通过验证并提交配置的 `setup()` 决定，之后不能在同一个 Neovim 进程中切换。若启用 takeover 后在立即检查当前目录 buffer 时出错，该决策也已经提交，需要重启 Neovim 才能重新选择。若要保留 netrw 或其他目录浏览器，第一次调用时必须显式关闭：

```lua
require("fre").setup({
  default_file_explorer = false,
})
```

### 手动创建实例

```lua
local fre = require("fre")

fre.setup({
  default_file_explorer = false,
})

vim.keymap.set("n", "<leader>e", function()
  local explorer = fre.new({
    root = vim.fn.getcwd(),
  })
  explorer:open()
end, { desc = "Open Fre" })
```

`fre.new()` 是默认的 **managed** 创建路径：它通过默认 Manager 创建核心 Instance、登记 public lookup，并把 `gc` 选项交给 Manager 拥有的 GC。它会立即返回实例和隐藏 buffer，目录扫描在后台完成。立即调用 `open()` 时，加载完成前 buffer 保持空白，完成后一次显示目录内容。

只需要单个核心文件系统编辑器、或要接入自定义管理层时，可以直接构造 standalone Instance：

```lua
local Instance = require("fre.instance")

local instance = Instance.new({
  root = vim.fn.getcwd(),
  id = "workspace:main", -- 可省略；省略时自动生成 UUID
})
instance:open()
```

standalone Instance 不需要 `require("fre").setup()`，仍支持加载、窗口展示、展开、编辑、写入、刷新、watcher 和销毁；它不参加默认 Manager 的 lookup、GC group/TTL/capacity、`fre.set_group` 或默认目录 takeover。默认 takeover 始终位于插件集成层：只调用 managed `fre.new()`，并只把默认 Manager 已登记的 buffer 视为 Fre 所有。standalone 默认只能解释自己的 marker；需要跨 Instance 复制时，创建者必须显式提供 `resolve_instance(instance_id)`，并自行限定 peer domain。

## 编辑文件系统

Fre 行包含真实的元数据列、隐藏的稳定身份标记和固定在末尾的可编辑路径。首次显示、进入父目录和 `reveal()` 会把光标放在路径起点；之后普通、可视和插入模式可以进入 permissions、size、mtime 及可导航的自定义元数据，但不能进入隐藏身份或行首 icon。新增未标记行仍可从第 0 列编辑。快速创建会立即插入带有当前 visible columns、目标 icon 和 metadata 占位值的草稿，把光标放到预填目录前缀末尾并进入 insert mode，等待直接补全文件名；它仍只是未写入的 buffer 文本。元数据可以选择、yank 和暂时修改，但语义只读。

| 目标 | Buffer 操作 |
| --- | --- |
| 新建空文件 | 新增未标记行，例如 `notes.txt`；`src/a.cpp` 会同时计划缺失的 `src/` |
| 新建目录 | 新增以 `/` 结尾的未标记行，例如 `docs/`；缺失的祖先目录会加入同一计划 |
| 快速在光标语义目录创建 | 按 `]n`，立即插入预填语义目录前缀的草稿；目录行以该目录为基准，文件和 symlink 行以 parent 为基准 |
| 快速在 Instance root 创建 | 按 `]N`，立即插入空 root-relative path 草稿；草稿位于当前行下一行 |
| 重命名 | 修改已有行的路径，例如 `old.lua` 改为 `new.lua` |
| 移动 | 修改为根目录内的另一相对路径，例如 `a.lua` 改为 `archive/a.lua` |
| 复制 | `yy`/`p` 复制已有行，再修改复制行的目标路径 |
| 删除 | 用 `dd` 等普通编辑操作删除已有行 |
| 跨实例复制 | 从一个仍存活的 Fre buffer yank 行，粘贴到另一个 Fre buffer，再修改目标路径 |

**警告：删除不经过回收站且无法撤销。删除目录行会递归删除磁盘上的全部子项，包括隐藏、折叠或未投影内容；目录复制和移动同样作用于整个子树。确认前请仔细检查计划。**

路径必须是实例根目录内的相对路径。空路径、绝对路径、逃逸根目录的 `..`、重复目标和只读元数据修改都会在写入准备阶段报错；元数据错误会指出 buffer 行号和列 ID。

完成编辑后执行：

```vim
:write
```

默认写入流程：

1. 解析当前 buffer，并生成有序的 create/copy/move/delete 计划。
2. 在浮窗中逐行显示计划。
3. 按 `<CR>` 或 `y` 确认；按 `q` 或 `<Esc>` 取消。
4. 执行期间可按 `q`、`<Esc>` 或关闭进度浮窗请求取消。
5. 执行一旦开始，无论最终成功、失败还是取消，Fre 都会尝试按文件系统真实状态重新同步。

在确认浮窗中取消时，不会执行或 reconcile，原始修改草稿会保留。执行期间的取消是尽力而为的；计划一旦开始，已完成的文件系统操作不会回滚，失败或取消可能留下部分结果。普通用户应优先使用 buffer 编辑加 `:write`，而不是直接调用低层 `execute()`。

## 默认按键

默认按键均为 Fre buffer 内的普通模式局部映射：

| 按键 | 行为 |
| --- | --- |
| `<CR>` | 打开文件或 symlink；进入目录或选择 `../` 时以 source 的完整 effective appearance 创建独立 peer Instance；在根 `/` 上无操作 |
| `]n` | 在光标语义目录下创建草稿；输入 basename 或子路径，文件/symlink 使用其 parent，根 `/` 使用 Instance root，`../` 无操作 |
| `]N` | 在 Instance root 下创建草稿，并插入当前行下一行 |
| `zv` | 展开光标所在目录；非目录行无操作 |
| `zc` | 折叠光标所在目录；非目录行无操作 |
| `za` | 切换目录展开状态；非目录行无操作 |
| `zM` | 折叠实例中全部目录；与光标所在行无关 |
| `q` | 隐藏当前 tab 中的 Fre 视图，但保留实例和 buffer |
| `g.` | 显示或隐藏点文件 |
| `gC` | 切换除 `icon` 外的全部 configured columns；再次按下恢复 |
| `R` | 立即刷新；buffer 已修改时直接丢弃草稿 |

Fre 不提供默认 `h`/`l` 映射，也没有默认插入模式或可视模式映射。

## 常用配置

```lua
local fre = require("fre")
local actions = require("fre.actions")
local columns = require("fre.columns")

fre.setup({
  -- 第一次 setup 后不可更改。
  default_file_explorer = true,

  hidden_file = false,
  skip_confirm_for_simple_edits = false,
  auto_expand_single_directory = false,

  columns = {
    columns.icon(),
    columns.permissions(),
    columns.size(),
    columns.mtime({
      format = "%Y-%m-%d %H:%M",
      align = "right",
    }),
  },
  hidden_columns = {},

  layout = {
    position = "left",
    size = 0.3,
  },

  gc = {
    ttl_ms = 60_000,
    include_modified = false,
    default_group = "default",
    groups = {
      default = 10,
      project = 5,
    },
  },

  use_mapping_default = true,
  mapping = {
    n = {
      ["<C-t>"] = actions.tab_select,
      ["<C-v>"] = function(ctx)
        local inspected = ctx.view
        local anchor = ctx.winid
        if inspected.layout.position == "float" then
          anchor = inspected.origin_winid
          if not anchor or not vim.api.nvim_win_is_valid(anchor) then
            error("fre: float origin is no longer valid")
          end
        end
        actions.split_select(ctx, {
          layout = { position = "right", size = 0.5 },
          anchor_winid = anchor,
        })
      end,
    },
  },

  buffer = {
    variables = {
      project_kind = "local",
    },
  },

  window = {
    options = {
      cursorline = true,
    },
  },
})
```

主要字段：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `default_file_explorer` | `true` | 第一次 `setup()` 是否接管本地目录 buffer；仅 setup 可用 |
| `hidden_file` | `false` | 是否投影 basename 以 `.` 开头的条目 |
| `skip_confirm_for_simple_edits` | `false` | 是否跳过简单文件系统编辑的写入确认 |
| `auto_expand_single_directory` | `false` | 展开目录并完成新扫描后，仅当扫描结果只有一个直接子项且它是当前可见的真实目录时才自动继续展开 |
| `sort` | 目录优先、ASCII 不区分大小写名称排序 | 每个父目录独立调用的比较函数 |
| `columns` | icon、permissions、size、mtime | 完整替换列描述符序列；path 始终是最后的专用字段 |
| `hidden_columns` | `{}` | 完整替换初始 hidden column ID 数组 |
| `gc.ttl_ms` | `60000` | 隐藏实例的回收延迟；`0` 禁用 TTL 回收 |
| `gc.include_modified` | `false` | 是否允许 GC 销毁带未保存修改的隐藏实例 |
| `gc.default_group` | `"default"` | 新实例默认 GC 组；仅 setup 可用 |
| `gc.groups` | `{ default = 10, project = 5 }` | 每组容量；容量 `0` 表示禁用容量限制 |
| `layout` | `{ position = "left", size = 40 }` | 默认窗口布局 |
| `use_mapping_default` | `true` | 是否安装内置映射 |
| `mapping` | `{}` | 按 mode/LHS 合并的函数映射 |
| `buffer.options` | Fre 必需的 buffer 选项 | 额外 buffer 选项 |
| `buffer.variables` | `{}` | 复制到 `vim.b` 的可序列化变量；名称 `fre` 保留 |
| `window.options` | 无换行、无行号、conceal 等 | 以 window-local scope 应用于每个 Fre 窗口，不改变之后打开的普通 buffer |

注意：

- 每次 `setup()` 都从内置默认值重新计算，不是基于上一次调用做增量 patch。通常应只调用一次。
- `mapping` 的值必须是函数，不能使用 action 名字符串或 `{ action = ... }` 描述符。
- 不支持用 `false` 单独删除某个内置映射。若要完全控制按键，设置 `use_mapping_default = false`，再声明所有需要的映射。
- `gc.include_modified = true` 允许 GC 强制丢弃隐藏 buffer 中未保存的文件系统草稿，请谨慎启用。
- `skip_confirm_for_simple_edits = true` 时，无删除、创建不超过 5 个、move 不超过 1 个且 copy 不超过 1 个的 `:write` 会直接执行。删除、超过阈值和未知操作仍需确认。`R` 是显式丢弃动作，无论该选项为何值都不会确认。

## 实例配置

`fre.new()` 接受：

```lua
local instance = require("fre").new({
  root = "/absolute/path/to/project", -- 必填
  hidden_file = true,
  skip_confirm_for_simple_edits = true,
  auto_expand_single_directory = true,
  sort = custom_sort,
  expanded = { "src", "src/x" }, -- 相对于 root 的初始展开目录
  columns = custom_columns,
  hidden_columns = { "size", "mtime" },
  gc = {
    group = "project",
    ttl_ms = 30_000,
    include_modified = false,
  },
  layout = { position = "right", size = 50 },
  use_mapping_default = true,
  mapping = {},
  buffer = {},
  window = {},
})
```

实例选项覆盖 setup 默认值。每个实例完全由本次传入的值选项决定；`expanded` 是 root-relative 目录列表，会按 root 的平台路径语义规范化，并在 root 加载后通过普通展开流程逐项应用。`auto_expand_single_directory = true` 时，每次新展开都会等待该目录的新扫描完成；仅当整个扫描结果恰好只有一个直接子项、该子项是真实目录且符合当前 `hidden_file` 设置时，才展开它并重复。任何文件、symlink 或隐藏兄弟项都会使子项总数不再为一，即使该项不会投影；唯一子项是文件或 symlink 时也不会继续，且不会跟随 symlink。唯一子项是隐藏目录时，仅在 `hidden_file = true` 时继续。遇到其他情况、扫描错误或手动折叠时停止。全部初始展开及其自动后缀完成后实例才 ready；路径缺失、不是目录或加载失败都会使本次初始化失败。`fre.new()` 不接受来源实例或实例引用，也不会在实例之间建立状态关系。`default_file_explorer`、`gc.groups` 和 `gc.default_group` 是 setup-only 配置，不能传给 `fre.new()`。

`columns` 和 `hidden_columns` 都使用完整替换语义；Instance 显式传入空 `hidden_columns = {}` 会清除 setup 默认值。descriptor `enable`、hidden ID 校验和可见性状态详见 [COLUMNS.md](COLUMNS.md)。

## 窗口布局

```lua
instance:open({ position = "current" })
instance:open({ position = "left", size = 40 })
instance:open({ position = "right", size = 0.4 })
instance:open({ position = "top", size = 12 })
instance:open({ position = "bottom", size = 0.3 })
instance:open({
  position = "float",
  width = 0.8,
  height = 0.8,
  -- row/col 省略时居中。
  border = "rounded",
})
```

分屏 `size`、浮窗 `width`/`height` 和 `row`/`col` 支持绝对 cell 数；小于 `1` 的正数表示比例。浮窗支持 `none`、`single`、`double`、`rounded`、`solid`、`shadow` 及 Neovim 八段 border 数组。

任何有效窗口只要正在显示一个已注册且未销毁的 Fre buffer，就是该 Instance 的一个 View。同一 Instance 在同一 tab 或不同 tab 都可以有多个 View；原生 `<C-w>v`、`<C-w>s`、`:split`、`:vsplit` 和 `:sbuffer` duplicate 都受支持。它们共享 tree、buffer 和展开状态，但各自保留 cursor、scroll 和 viewport。共享投影变化时，Fre 会按 Entry path 为全部实际 View 尽力恢复语义 cursor 和相对 viewport。

`instance:open()` 在当前窗口本身是 View 时选择当前窗口；否则复用当前 tab 的唯一 View；存在多个非当前候选时显示原生 `a/b/...` 选择提示。没有 View 时才按 explicit layout 或 Instance 创建时复制的 immutable default layout 打开。相同 normalized layout 直接复用，显式不同 layout 只 relayout 被选中的一个 View，其他 duplicate 不变。

`instance:hidden(tabpage?)` 隐藏指定 tab（默认当前 tab）中的全部 View；`instance:hide_all()` 隐藏所有 tab。`instance:toggle(layout)` 是严格二元操作：当前 tab 只要有任意 View 就全部隐藏，否则打开。`position = "current"` 的 Fre-established View 隐藏时恢复它替换前的 buffer；Fre 创建的 split、float 和 tab destination 隐藏时关闭对应窗口。没有 Fre window policy 的原生 duplicate 采用保守 current-position 语义，恢复有效 alternate buffer 或安全空 buffer。

## 自定义映射与 actions

映射函数每次调用都会收到新的 context：

```lua
{
  instance = instance,
  bufnr = bufnr,
  winid = winid,
  tabpage = tabpage,
  view = { winid = winid, origin_winid = origin_winid, layout = normalized_layout },
  mode = mode,
  row = row,             -- 1-based
  col = col,             -- 0-based UTF-8 byte offset
  row_kind = "entry" | "new" | "navigation",
  navigation_kind = "parent" | "root" | nil,
  source_instance_id = instance_id_or_nil,
  entry = entry_or_nil,
  path_range = { start_byte = 0, end_byte = 4 } | nil,
  range = visual_range_or_nil,
}
```

ActionContext 是 mapping 当次同步调用的 source snapshot。`ctx.view` 是 exact `ctx.winid` 的只读 View snapshot，mapping 可直接读取 `layout` 和 `origin_winid`；不会携带 visibility、generation/token 或 reconciliation 状态。调用方缓存 context 并延迟执行不受支持。`create_child` / `create_root` 同步验证 source 并插入草稿，不保留传入 context。非 mapping 场景可同步调用 `fre.view.inspect()`。更多完整示例见 [TIPS.md](TIPS.md)。

可视范围形状为：

```lua
{
  start = { row = 1, col = 0 },
  finish = { row = 3, col = 8 },
}
```

常用 actions：

```lua
local actions = require("fre.actions")

-- 当前编辑器状态的 ActionContext。
local ctx = actions.context()

actions.expand(ctx)
actions.collapse(ctx)
actions.toggle_expand(ctx)
actions.collapse_all(ctx)
actions.toggle_hidden_file(ctx)
actions.hide_columns(ctx, ids)
actions.show_columns(ctx, ids)
actions.toggle_columns(ctx, ids)
actions.is_column_visible(ctx, id)
actions.refresh(ctx)
actions.jump_to_path(ctx) -- 当前 entry/navigation 行的 path 字段起点
actions.create_child(ctx) -- 插入预填光标语义目录前缀的草稿并进入 insert mode
actions.create_root(ctx)  -- 插入空 root-relative path 草稿并进入 insert mode

actions.select(ctx, {
  target_winid = ctx.winid,
  hide_source = false,
  instance = { gc = { group = "project" } }, -- 仅 directory destination
})
actions.tab_select(ctx, {
  hide_source = false,
  instance = { gc = { group = "project" } }, -- 仅 directory destination
})
actions.split_select(ctx, {
  layout = { position = "right", size = 0.5 }, -- 必填 split layout
  anchor_winid = ctx.winid,
  hide_source = false,
  instance = { gc = { group = "project" } }, -- 仅 directory destination
})
```

对目录或本实例的 `../` 导航行执行 `select`/`tab_select`/`split_select` 时，Fre 会统一调用 public `fre.new()` 创建一个由默认 Manager 管理的独立 peer Instance。目标以 source 创建时的完整 effective appearance 和当前 hidden-file/column 状态为基线，包括 comparator、descriptors、layout、mapping controls、Buffer 与 window 选项；之后应用显式 `opts.instance`，最后由 action 覆盖所选 absolute `root` 和保留的 root-relative `expanded`。source 创建后的 setup 变化不会改写该基线；GC policy 不从 source 继承，仍按目标的显式 `gc` 或当前 Manager 默认值解析。source 与 destination 不共享生命周期、Manager affinity 或后续状态。进入目录时，目标目录下当前有效的展开路径会转换成新 root-relative 值，例如 `{ "x", "x/x" }`；选择 `../` 时固定使用空 `expanded`，并在目标 ready 后定位刚离开的目录。根目录的 `/` 和从其他实例粘贴的导航行均无操作。`actions.jump_to_path()` 只把 entry 或 navigation 行的 cursor 移到 path 字段；new、缺少 path range 或不可解析的行会静默忽略。它没有默认映射。

三种 selection action 的 option table 都是 closed schema：`select` 只接受 `target_winid`、`hide_source`、`instance`；`tab_select` 只接受 `hide_source`、`instance`；`split_select` 必须提供 `layout`，此外只接受 `anchor_winid`、`hide_source`、`instance`。任何未列字段（包括 numeric key 和其他 non-string key）都会在 preflight 直接报错。`opts.instance` 仅用于 directory destination；`root` 和 `expanded` 均由 action 持有并覆盖调用方值。

三种 selection action 共享相同的 source、Entry、resource preparation、buffer install commit、window policy、cursor、focus 和 post-commit `hide_source` 语义，只是 destination shape 不同：`select` 使用 exact `target_winid`，省略时是 captured `ctx.winid`；`tab_select` 创建一个 exact 新 tab；`split_select` 相对 exact ordinary anchor 创建目标。ordinary source 省略 `anchor_winid` 时只使用 captured source window；float source 必须显式提供同 tab 的 ordinary anchor，通常直接使用 `ctx.view.origin_winid`。无效 option/source/target/anchor/layout 会在 destination、file buffer 或 destination Instance 创建前报错，不会从当前焦点或其他窗口 fallback。

`hide_source` 必须是 boolean，默认 `false`。它只在 selected buffer 成功安装后，隐藏 captured source tab 中该 source Instance 的全部实际 View；不会影响其他 tab。file/symlink 安装后 destination 是 ordinary file window，原 View 因窗口不再显示 Fre buffer 而自然消失。directory destination buffer 安装后立即成为 exact destination 的 View；窗口原有 policy 会保留，ordinary target 会建立 current-position restore policy，action-created tab/split 使用 close-on-hide policy。原生 back/forward 始终从实际 buffer 状态解析，不做 ownership transfer。destination 的异步 load failure 保留已提交结果，不恢复 source。

## 列

内置构造器是 `columns.icon()`、`columns.permissions()`、`columns.size()` 和 `columns.mtime()`；默认 configured 顺序也是 icon、permissions、size、mtime。filesystem path 始终是最后的专用字段，不属于 column 可见性模型。

Descriptor `enable`、`hidden_columns`、configured/enabled/hidden/visible 状态、custom descriptor 契约和公开查询的完整说明见 [COLUMNS.md](COLUMNS.md)。

## Lua API

顶层模块：

```lua
local fre = require("fre")

fre.setup(opts)
fre.new(opts)
fre.get_instance()          -- 当前 buffer 对应的默认-managed Instance 或 nil
fre.get_instance(bufnr)
fre.get_instance_by_id(id)     -- 仅返回默认 Manager 当前登记的存活 Instance
fre.set_group(instance, group) -- 仅接受默认 Manager 登记的存活 Instance
```

核心 Instance 可直接构造。`id` 是不含控制字符的非空 opaque string；省略时生成 UUID。可选的 `resolve_instance` 由调用方拥有并决定 foreign-marker peer domain：

```lua
local Instance = require("fre.instance")
local peers = {}

local source = Instance.new({ root = "/project", id = "project:source" })
peers[source.id] = source
local target = Instance.new({
  root = "/other",
  id = "project:target",
  resolve_instance = function(id) return peers[id] end,
})
```

`fre.new()` 不接受 caller-selected `id`；默认 Manager 在核心构造前分配 UUID，按 ID 和 buffer 维护 live indexes，并向 Instance 提供只解析同一 Manager domain 的 resolver。standalone 不会出现在 `fre.get_instance*()` 中，也不会自动解析默认 Manager 或其他 standalone/custom Manager 的 Instance。local marker 不需要 resolver；foreign marker 只在 decode/prepare 的使用点解析，未知、终态或缺失 node 会按目标 row 报错。

实例公开字段按只读方式使用：

```lua
instance.id
instance.bufnr
instance.root
```

常用方法：

```lua
instance:when_ready(function(err) end)

local opened, winid = instance:open(layout) -- opened == instance
instance:hidden(tabpage) -- 隐藏该 tab 的全部 View；省略时使用当前 tab
instance:hide_all()
instance:toggle(layout)

instance:expand(path)
instance:collapse(path)
instance:toggle_expand(path)
instance:collapse_all()
instance:reveal(path)

instance:set_sort(compare)
instance:set_hidden_file(boolean)
instance:toggle_hidden_file()

instance:get_columns()
instance:get_hidden_columns()
instance:is_column_visible(id)
instance:hide_columns(ids)
instance:show_columns(ids)
instance:toggle_columns(ids)

require("fre").set_group(instance, group)

instance:get_entry(row)
instance:get_pos(snapshot_path) -- { row, byte_col } 或 nil
instance:set_cursor_to_path(snapshot_path, winid)

instance:refresh()
instance:refresh({ force = true, on_complete = function(err) end })
instance:destroy()
```

只读 View 查询：

```lua
local inspected = require("fre").view.inspect(instance, tabpage)
local exact = require("fre").view.inspect(instance, { winid = winid })
-- nil，或：
-- { winid = winid, origin_winid = origin_winid, layout = normalized_layout }
```

每个 Instance 的 private View child 独占 per-tab View records，并在查询/同步时按实际 Neovim window 与 buffer 状态修剪记录；Instance 本身不保存 View map。`tabpage` 省略时使用当前 tab：当前窗口是该 Instance 的 View 时返回 exact current View，否则唯一候选可直接返回；多个非当前候选会明确报错，调用方应传 `{ winid = ... }`。无实际 View 返回 `nil`。返回 table 和 normalized `layout` 都是 copy。Fre-established current/split/float View 带有 exact restore/close policy 与 origin；原生 ordinary duplicate 的 layout 是 `current`、origin 是自身，外部 float 不推断 ordinary origin。

`get_entry(row)` 返回新的普通 Lua table：

```lua
{
  instance_id = "7d9d4cd8-f40f-4b43-8a35-c14502a79170",
  node_id = 7,
  absolute_path = "/project/src/main.lua",
  relative_path = "src/main.lua",
  name = "main.lua",
  kind = "file", -- 非空 adapter kind；file | directory | symlink 支持直接 mutation
}
```

`expand`、`collapse`、`toggle_expand` 和 `reveal` 接受 root 内的 snapshot 相对路径，也可接受 root 内绝对路径；`collapse_all` 与光标和路径无关，会清除缓存树中全部非 root 目录的展开状态，同时保留目录缓存与元数据。`get_pos` 和 `set_cursor_to_path` 接受 snapshot 相对路径。`set_cursor_to_path` 可以在创建期间调用：它等待实例 ready 后，把指定窗口的 cursor 放到目标条目的 path 起点，不展开目录或保存 cursor 状态。会改变投影的操作在 buffer 已修改时会直接报错，以避免覆盖草稿；窗口操作和 lookup 仍可使用。每次成功投影以及成功 `:write` 后的真实状态同步都会建立新的 undo 起点，`u` 不会恢复旧树投影或已经提交的文件系统草稿。

`fre.set_group(instance, group)` 是唯一的默认-managed group migration API；不存在 `instance:setGroup()` 兼容别名。它只接受仍由默认 Manager 登记的存活 Instance，把 GC 拥有的 membership 原子迁移到 `setup()` 中已存在的组，并立即按目标组容量执行回收；迁移 subject 在本次容量约束中受保护。迁移保留 GC-owned policy snapshot、隐藏区间和 TTL timer，不修改 Instance 字段或 buffer metadata。standalone、自定义管理层、已销毁或未登记的 Instance 会被拒绝。

### 异步就绪

```lua
local instance = require("fre").new({ root = vim.fn.getcwd() })

instance:when_ready(function(err)
  if err then
    vim.notify(tostring(err), vim.log.levels.ERROR)
    return
  end
  vim.notify("Fre is ready")
end)
```

配置了 `expanded` 时，root、全部初始展开目录以及 `auto_expand_single_directory` 产生的自动展开后缀完成加载后，才会调用 `when_ready` 并触发 `FreReady`。初始化展开失败时，Instance 进入 `load-failed`，错误同时传给 callback 和事件的 `data.error`。

### User 事件

核心 Instance 只发布以下六个有限、命名的 `User` 事件；payload 只含可序列化身份/状态，不含 Instance、Manager、GC、Buffer、callback 或命令：

| pattern | `args.data` | 时机 |
| --- | --- | --- |
| `FreInstanceCreated` | `{ instance_id, bufnr }` | 核心组合和 initial load 启动后，同步发生在构造返回前 |
| `FreReady` | `{ instance_id, bufnr, error, result }` | 每次 initial-load attempt 提交 ready/load-failed 且 `when_ready` observer 已运行后 |
| `FreInstancePresentationChanged` | `{ instance_id, bufnr, visible }` | 实际 View 从 0 到非 0 或从非 0 到 0；重复同步不发事件 |
| `FreInstanceActivityChanged` | `{ instance_id, bufnr, activity, active }` | `refresh`、`write` 或 `execution` 活动边界改变时 |
| `FreInstanceDestroying` | `{ instance_id, bufnr }` | lifecycle 提交 destroying 后、局部清理前 |
| `FreInstanceDestroyed` | `{ instance_id, bufnr }` | 核心 lifecycle、局部资源和 buffer 都进入终态后 |

每个事件都通过 protected `nvim_exec_autocmds` 分发；observer 错误会异步报告，不会回滚已经提交的核心状态。默认 Manager 只是这些事实的一个消费者。`FreInstanceDestroyed` 发出前，核心 lifecycle、局部资源和 buffer 均已进入终态；默认 Manager 在消费该事件时才删除 managed lookup 和 GC records。因此，在默认 Manager observer 之前运行的任意 observer 在事件 dispatch 期间仍可能通过 `fre.get_instance*()` 解析到已销毁的 Instance；默认 Manager 消费后以及事件分发完成后，managed lookup 不再存在。自定义管理层应按 opaque `instance_id` 维护自己的记录，并从自己的 lookup 解析实例；默认 `fre.get_instance*()` 不会解析 standalone 或其他 Manager 的实例。

监听 ready 的例子：

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "FreReady",
  callback = function(args)
    local data = args.data
    local instance = require("fre").get_instance_by_id(data.instance_id)
    if data.error then
      vim.notify(tostring(data.error), vim.log.levels.ERROR)
    elseif instance then
      -- managed ready instance
    end
  end,
})
```

每个 Fre buffer 名称为 `fre://<instance-id>`，并只提供核心身份元数据；GC group、TTL、capacity、modified policy、Manager affinity 和 GC timer 状态都不复制到 buffer：

```lua
vim.b.fre == {
  version = 1,
  instance_id = instance.id,
  root = instance.root,
}
```

## 低层 mutation API

普通交互请使用 buffer 编辑和 `:write`。需要自定义确认 UI 或执行流程时，可以调用：

```lua
local plan = instance:prepare()
local execution = instance:execute(plan, {
  on_progress = function(progress)
    -- progress 是当前状态的副本。
  end,
  on_complete = function(err, result)
    -- 直接 execute 不会自动 refresh 或 reconcile。
  end,
})

local status = execution:get_status()
execution:cancel()
```

`execute()` 严格按 `plan.operations` 顺序运行，不确认、不锁定 Fre buffer、不刷新，也不验证该 Plan 是否来自 `prepare()`。调用者负责路径、顺序、冲突、展示和后续刷新。

**危险：`execute()` 不是 root sandbox。调用者提供的绝对路径会原样交给文件系统 adapter，因此可修改实例 root 之外的任意位置。操作只在执行到该项时才验证，不做完整 preflight；较后的错误操作可能在较早操作已经完成后才失败。**

移动操作只执行一次 filesystem rename，没有跨文件系统 fallback。任何失败或取消都不回滚已经完成的操作。

## Watcher 与 GC

- Fre 为 root 和当前活动的展开目录建立非递归 `vim.uv` watcher；每个目录独立 trailing debounce。
- 同时 ready 的目录按浅到深顺序在一个 detached transaction 中刷新相关直接子项边界，并最多提交一次最终投影；event filename 不作为扫描目标。
- batch 运行期间新成熟的目录进入后续 targeted batch。buffer 已修改、实例隐藏、write、direct execution 或其他 refresh 占用 presentation 时，准确的 pending directories 会保留，不退化为无范围 full refresh。
- 成功的 public refresh 和 write reconciliation 消费其启动前 pending directories；direct execution 不扫描或消费 pending work，结束后才运行 targeted batch。
- watcher handle 失败会关闭并报告一次；完成一次有界 rescan 后，仅在目录仍 active 时重建。batch 失败保留旧投影与全部 pending directories。
- watcher 行为和可靠性仍受操作系统及 libuv 限制。详细 callback/cache 语义见 [COLUMNS.md](COLUMNS.md#watched-directory-updates)。

GC 是默认 Manager 可选使用的进程级 owner。它按 Instance identity 保存 group membership、容量、每实例 `ttl_ms`/`include_modified` policy snapshot、hidden interval、timer/generation 和 eligibility；GC 可保留 managed Instance 并只调用其 public `destroy()`。核心 Instance 不持有 Manager/GC/group/policy/runtime 状态。`fre.new({ gc = ... })` 的 managed policy 由 GC 解析；standalone constructor 不解释或应用 GC policy。

GC group 的容量由组内全部存活实例占用，包括可见、写入锁定、正在执行 mutation 或带修改的实例。回收时只会选择已隐藏且当前可安全销毁的实例；若没有安全候选，group 会暂时超过容量，直到实例状态变化后再次执行约束。

GC 的可见性以全部实际 View 为准，原生 duplicate 与 Fre 创建的窗口同样阻止 TTL/容量销毁。首个 View 出现会取消隐藏区间，最后一个 View 离开才重新开始计时；销毁前仍会执行最终 `win_findbuf` 检查。

`gc.ttl_ms = 0` 会禁用 TTL 回收。GC 组容量为 `0` 会禁用该组的容量限制，而不是立即回收所有实例。

## 稳定 marker 与特殊文件排查

每个已有条目和导航行在物理 buffer 行首都带有稳定身份 marker。`instance-id` 是按 Lua byte 长度定界的 opaque string，因此 ID 内可以包含 `:`；真实 node ID 为正数，node ID `0` 是唯一导航哨兵：它根据源 Instance root 表示 `../` 或 `/`，不属于 Tree、baseline 或 filesystem mutation。快速创建草稿使用独立且与当前投影 marker 等宽的内部草稿身份，保留 Instance 归属但不占用 Tree node ID；写入并 reconcile 后才由真实 filesystem scan 分配 node ID。

Marker 是隐藏的内部结构文本，不是可配置列。它没有全局宽度、宽度 generation 或宽度变化事件；每行都由长度字段自行定界。已有行、复制行和快速创建草稿中的 marker 字节都会随普通编辑、undo 和 yank 作为真实 buffer 文本保留；成功写入或显式成功刷新后才按 filesystem truth 重新投影。

正式的 `syntax/fre.vim` 在首个带 marker 的投影前提供 conceal；目标窗口也会在显示 Fre 前应用 conceal 等局部选项，并在离开 Fre 时恢复之前的值。Raw buffer API、`:print` 和普通 yank 仍会保留这些真实字节，这是复制身份协议的一部分。

若屏幕上直接出现 `fre:<length>:...`，在对应 Fre 窗口检查：

```vim
:setlocal conceallevel? concealcursor?
:syntax list FreStableMarker
```

正常值是 `conceallevel=3`、`concealcursor=nvic`，并存在带 `conceal` 的 `FreStableMarker` syntax match。可先执行 `:setlocal conceallevel=3 concealcursor=nvic`；如果仍可见，提交上述三项输出和 `:version`。

默认 filesystem adapter 还可能返回 `char`、`block`、`fifo` 或 `socket`，自定义 adapter 也可以返回其他非空 kind。Fre 会加载并显示全部这些条目，它们都参与目标路径占用检查。四种 libuv 原生特殊 kind 支持删除和同文件系统 move：删除对该目录项执行 unlink，move 只执行一次 filesystem rename；它们不支持 copy 或跨实例复制。其他 adapter-defined kind 仍是 opaque occupant，只能以原 marker 保留在原 snapshot 路径。

跨文件系统 move 不会退化为 copy + delete；rename 返回 `EXDEV` 时执行会以 `unsupported cross-device move` 失败并保留原条目。`row N: unsupported snapshot kind char for <path>` 中的 `char` 是 libuv 文件类型 `character device`，不是图标字符；对原生特殊 kind，该错误表示计划试图复制它或复制包含已缓存特殊后代的目录。把光标移到相关行后可检查：

```vim
:lua print(vim.inspect(require("fre").get_instance():get_entry(vim.fn.line("."))))
```

Windows 上常见原因是目录中存在保留名 `nul` 的真实残留条目。不要删除真正的系统设备；确认这是误建普通文件后，可在 PowerShell 中用 Win32 extended path 检查并删除，再在 Fre 中按 `R` 刷新：

```powershell
$p = '\\?\C:\absolute\path\to\nul'
[IO.File]::ReadAllText($p) # 先确认内容
[IO.File]::Delete($p)      # 确认后再删除
```

若当前 Fre buffer 已修改，`R` 会直接丢弃草稿；刷新前先保留需要的路径编辑。


## 限制与安全说明

- 仅支持本地文件系统，不支持 SSH、S3、archive、trash 等后端。
- 不支持文件名中的换行字节。
- character/block device、socket 和 FIFO 支持 unlink 删除及同文件系统 rename，但不支持 copy；`EXDEV` 不会触发 copy fallback。其他 adapter-defined kind 只能加载、显示并原样保留。
- `prepare()` 只能检查已缓存且不支持当前 operation 的后代；copy 未展开目录或删除含未知 adapter-defined kind 的未展开目录时，默认 mutation adapter 仍可能在执行中失败。
- 不会自动执行 `:cd`、`:lcd` 或 `:tcd`。
- 不会对部分执行的计划做事务回滚。
- 外部文件变化不会与未保存草稿做三方合并。
- 跨实例复制要求源实例及源节点在 `prepare()` 时仍然存活。
- symlink 按链接本身复制和删除；选择 symlink 时按文件打开。
- 启用默认目录接管后，当前 Neovim 进程中没有恢复 netrw 的公共 API。
- `refresh({ force = true })` 和默认 `R` action 会直接丢弃未保存的 Fre buffer 草稿。
- 原生 jumplist、buffer navigation 和普通 split duplicate 都按实际窗口支持；外部创建的 float 没有可可靠推断的 ordinary origin，需要相关 action 显式提供 `anchor_winid`。
- ActionContext 只支持 mapping/action 的同步调用；调用方缓存后延迟执行不受支持。内置 quick-create action 会同步验证 source、插入草稿并进入 insert mode，不保留传入 context。

## 开发与测试

PowerShell：

```powershell
.\scripts\test.ps1
.\scripts\test.ps1 tests/path_spec.lua
```

Git Bash 或其他 POSIX shell：

```sh
./scripts/test.sh
./scripts/test.sh tests/path_spec.lua
```

`cmd.exe` 也可以使用 `scripts\test.cmd`。测试入口会把固定版本的 Plenary 自动 bootstrap 到被忽略的 `.deps/` 目录，并在 spec 加载失败或测试失败时返回非零状态。
