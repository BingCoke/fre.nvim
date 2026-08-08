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
