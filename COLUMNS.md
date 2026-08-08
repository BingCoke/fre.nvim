# Columns

Fre 的 column descriptor 控制 path 之前的有界字段。filesystem path 是固定在每行末尾的专用字段，不属于 column 模型，也不能通过 column 配置隐藏。

## 状态模型

每个 Instance 在构建时得到一份独立的 descriptor 快照，并由其 Buffer 持有以下状态：

| 状态 | 含义 |
| --- | --- |
| configured | `columns` 中按配置顺序排列的全部 descriptor |
| enabled | configured 中构建期 `enable` 结果为 `true` 的有序子序列 |
| hidden | `hidden_columns` 中实际 enabled 的 ID，按 configured 顺序排列 |
| visible | enabled 减去 hidden 后的有序序列 |

`visible = enabled - hidden`，顺序始终来自 configured。enabled 在 Instance 生命周期内固定；hidden 是 Instance 自己的状态，不会与其他 Instance 共享。

字符串 `path` 没有保留的 column 含义。只有配置了 `id = "path"` 的 custom descriptor 时，它才表示一个普通 column；隐藏该 descriptor 不会隐藏末尾的 filesystem path 字段。

## Built-in Columns

默认 configured 顺序是 `icon`、`permissions`、`size`、`mtime`：

```lua
local columns = require("fre.columns")

columns.icon() -- 默认 provider = "auto"
columns.icon({ provider = "ascii", align = "left" })
columns.permissions({ align = "left" })
columns.size({ align = "right" })
columns.mtime({ format = "%Y-%m-%d", align = "right" })
```

`columns.icon()` 会尝试使用 `nvim-web-devicons`，不可用时回退为 ASCII `d/f/l`。显式 `provider = "nvim-web-devicons"` 时，依赖不可用会报错；`provider = false` 或 `"ascii"` 强制使用 ASCII。自定义 provider 接收当前 Entry 与 callback context，并返回 `icon, highlight`；返回 `nil` 时使用 ASCII fallback。

`size` 使用 `lstat.size` 和十进制单位；`mtime` 使用 descriptor 的 `format`。permissions、size、mtime 和可导航 custom column 在 buffer 中可以选择和临时编辑，但写入准备阶段会重新解析并验证其语义只读值。

## Custom Descriptors

```lua
local kind_name = columns.custom({
  id = "kind_name",
  align = "left",
  navigable = true,
  enable = function()
    return vim.g.fre_kind_column ~= false
  end,
  metadata = { "kind" },
  render = function(entry)
    return entry.kind, "Comment"
  end,
  parse = function(suffix)
    local value, rest = suffix:match("^%s*(%S+)%s+(.*)$")
    if not value then error("malformed kind_name column") end
    return value, rest
  end,
  equals = function(entry, value)
    return entry.kind == value
  end,
})
```

Descriptor 字段：

- `id` 是唯一、非空且不含空白或控制字符的 string。
- `align` 是 `left`、`center` 或 `right`；custom 默认 `left`。
- `navigable` 是 boolean；custom 默认 `true`。
- `enable` 是 boolean 或零参数 predicate，默认 `true`。
- `metadata` 是无重复的 `kind`、`mode`、`size`、`mtime` 数组；`requires` 是会被规范化为 `metadata` 的 legacy alias。
- `render(entry, ctx)` 返回无控制字符的有效 UTF-8 文本和可选 highlight group。
- `parse(suffix, ctx)` 返回当前字段值和未消费 suffix。
- `equals(entry, value, ctx)` 验证解析值是否仍匹配 metadata。

Callback context 的 `column_index` 与 `is_last` 相对 Instance 构建时固定的 enabled 顺序计算，不随 runtime hidden state 改变。这样同一个 entry-column 结果可以在 hide/show 之间复用；物理行中的 visible 顺序仍始终是 enabled 减去 hidden。

导航行使用相同的 visible column 顺序和投影宽度。其 callback context 包含 `synthetic = true` 和 `navigation_kind = "parent" | "root"`，并提供 callback-only directory Entry；`instance:get_entry(1)` 仍返回 `nil`。

## 构建期配置

`columns` 与 `hidden_columns` 都可在 `fre.setup()` 和 `fre.new()` 中配置：

```lua
local configured = {
  columns.icon(),
  columns.permissions(),
  columns.size({ enable = vim.fn.has("unix") == 1 }),
  kind_name,
}

require("fre").setup({
  columns = configured,
  hidden_columns = { "size", "kind_name" },
})

local instance = require("fre").new({
  root = vim.fn.getcwd(),
  hidden_columns = {}, -- 显式清除 setup 默认值
})
```

Instance 省略字段时继承 setup 默认值；显式 `{}` 清空；非空数组完整替换 setup 值，不做合并。`hidden_columns` 必须是无空洞、无重复的 string 数组，每个 ID 都必须存在于最终 configured descriptors。configured 但 disabled 的 ID 合法，不过不会进入运行时 hidden 状态。unknown ID 会使构建失败。

每次 Instance 构建时，Buffer 按 configured 顺序对每个 descriptor 的 `enable` 求值一次。predicate 不接收参数；抛错或返回非 boolean 会使构建失败，并在错误中标识 column ID。构建后不会重新求值。

初始投影只调用 visible descriptor 的 `render`。hidden 和 disabled descriptor 不渲染，也不参与行的 column layout；filesystem path 始终正常投影。

## 查询

```lua
instance:get_columns()          -- configured descriptor 副本
instance:get_hidden_columns()   -- enabled 且 hidden 的 ID 副本
instance:is_column_visible(id)  -- boolean
```

`get_columns()` 保持 configured 顺序，包括 disabled descriptors。`get_hidden_columns()` 保持 configured 顺序，但排除 configured-but-disabled IDs。两个 getter 都返回 defensive copy，修改结果不会改变 Instance。

`is_column_visible(id)` 只接受 string。visible ID 返回 `true`；hidden、disabled 或 unknown ID 返回 `false`。这些查询只读取构建完成的 Buffer column 状态，可以在 Instance 初始目录加载期间调用，不会触发 projection 或 descriptor callback。

## 运行时可见性

```lua
instance:hide_columns({ "permissions", "size" })
instance:show_columns({ "permissions", "size" })
instance:toggle_columns({ "permissions", "size" })
```

三个 mutation 都要求 Instance 已 ready、未销毁，Buffer 未修改，并且没有 write 或完整 refresh 正在占用投影；成功返回 `nil`。参数必须是无空洞的 string 数组。空数组不投影，重复 ID 使用集合语义，unknown 或 disabled ID 被静默忽略，因此同一个 column group 可以安全用于配置不同的 Instances。

`hide_columns()` 隐藏有效目标，`show_columns()` 显示有效目标。`toggle_columns()` 先过滤并去重目标：全部有效目标都 hidden 时显示整组，否则隐藏整组。一次调用只提交最终可见序列，不发布中间布局；没有实际变化时不会增加投影 generation。

同一 Tree snapshot 中，隐藏 column 不调用其 `render`，并保留可复用结果；再次显示已有结果的 column 不重新渲染。构建期 hidden、之前从未渲染的 column 会在首次显示时同步生成缺失结果。render、投影准备、extmark、highlight 或 Buffer 提交失败时，旧文本、highlights、row identity、hidden state 和可复用结果保持不变；失败 callback 在抛错前产生的外部副作用无法由 Fre 撤销。

## Cursor 恢复

Column visibility 提交前，Fre 会为显示该 Instance 的每个 View 记录当前 filesystem entry 与语义字段位置。提交后仍存在且 navigable 的字段保留字段内 display-cell offset；字段内容缩短时，位置会钳制到最后一个有效 UTF-8 character boundary。path 内的 cursor 同样保留 path display offset。

字段的 leading/trailing padding 属于该字段。字段后的 separator 归属于左侧字段；第一个 configurable column 之前没有可独立导航的 separator 区域。padding 和 separator 不会成为单独的 cursor 目标。

原字段变为 hidden、disabled 或 non-navigable 时，Fre 按构建时的 enabled/configured 顺序向右查找第一个 visible 且 navigable 的 column，并移动到其首字符；右侧没有目标时回退到 path 首字符。原 entry 消失时，继续使用最近 surviving ancestor，再回退到第一个 projected Entry。

每个 managed View 独立恢复 entry、cursor 与相对 viewport，不切换当前 tab 或 focused window。Visibility 的文本与 hidden state 一旦提交就不会因 cursor placement 失败而回滚；一个无效 View 或 placement 失败会被跳过，其余 Views 继续恢复。
