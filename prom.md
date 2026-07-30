- expand 的操作的时候, 如果这个仓库目录的children 有且仅只有一个dir的时候, 那么可以递归继续把这个dir expand, 就比如java的 com/xxx/xx/src 这个时候可以递归直接全部expand就好了, 这个也作为一个opt, 就是说当展开的dir有且只有一个dir的时候是否可以直接递归继续展开
- 还有加一个action ,就是unexpand, 就是把这个目录下root下所有的expand的dir全部合并, zr? 还是什么快捷键, 你配置一下
> 顺带一个一问题, 一个dir展开然后再unexpand之后, 是否还会watch 这个dir?, 就是说优化是否足够, 

- 编写tips文档
    - 编写文档, 怎么在lualine/ tabby 中正确的配置名字还有路径
        - lualine 使用的是当前全局的相对路径, 如果文件路径不在全局的cwd的位置, 那么就配置为 真实的绝对路径, 那么就是使用的是
        - tabby只需要展示一个Fre即可
    - 编写文档, 描述一下buffertype, 还有插件的全部的event, 让用户知道如何更加深入的配置, 比如说根据buffer的root位置自动wlcd
    - 提供文档, 告诉基础的actions 是那些, 推荐的使用配置, 就是说比如说我们select_tab的使用, 所有action都配置上的样子
    - 提供文档, 怎么使用, 比如说使用 "-" 这个map, 用来toggle进行gloabl cmw的toggle 的float 文件管理器, 使用q来进行destory , 然后每次打开的时候检测一下gloabl root是否和当前的instance一致, 如果不一致, 那么就desotry, 然后创建新的实例,
    - 有一个 <cd> 的map, 表示gloabl cd当前的文件管理器root, 并且把当前的实例作为上面说的gloabl实例的instance

- Refresh 的时候 有一个confirm  这个也可以 skip_confirm_for_simple_edits 基于这个opt(有这个就不会弹出这个确认按钮), 而且 跳出的confirm我确认之后refresh 不会关闭这个confirm,, 或者干脆就不用这个确认按钮 我相信按下这个按钮的应该都知道自己在做什么
- 不要加载中的文字, 直接就是空白然后展示就行了, 不然会有一种很怪的闪烁的感觉, 感觉很卡
- gc 看group容量的时候, 我们应该判断所有的instance, 只是说清理instance的时候跳过哪些需要清理的, 不是说有些比如说modify/正在显示...的 instance直接完全被忽略, 这些要计算在容量中, 只是说清理的时候不清理这些, 你觉得呢, 否则比如说我想配置一个只有一个实例的single group , 但我在这个singale group a1 实例<cr>到其他文件夹, 因为继承了吗, 然后a2 实例也有相同的 single group, 但是有一个问题就是说 这个时候a1 其实不会被销毁, 因为不算显示的实例的容量, 这个时候这个容量计算就有当让人迷惑了
- expand 或者折叠的时候, 是否需要把buffer 编辑的history清理掉, 还有:w 之后是否要清理掉, 你看看oil怎么处理这个history的,



- expand 之后导致columns的宽度可能扩大/缩小， 但是没有修复cursor正确的位置, 之前这个功能没问题的, 看看是那个commit导致的这个问题又被破坏了


 vim.uv.fs_lstat() 可能返回这些主要类型：

 ┌────────────┬──────────────────────┬────────────────┐
 │ libuv 类型 │ 含义                 │ fre 内部类型   │
 ├────────────┼──────────────────────┼────────────────┤
 │ file       │ 普通文件             │ file           │
 ├────────────┼──────────────────────┼────────────────┤
 │ directory  │ 目录                 │ directory      │
 ├────────────┼──────────────────────┼────────────────┤
 │ link       │ 符号链接             │ 转换为 symlink │
 ├────────────┼──────────────────────┼────────────────┤
 │ char       │ 字符设备             │ char           │
 ├────────────┼──────────────────────┼────────────────┤
 │ block      │ 块设备，例如磁盘设备 │ block          │
 ├────────────┼──────────────────────┼────────────────┤
 │ fifo       │ FIFO/命名管道        │ fifo           │
 ├────────────┼──────────────────────┼────────────────┤
 │ socket     │ Unix domain socket   │ socket         │
 └────────────┴──────────────────────┴────────────────┘

 默认加载器在 fs.lua 中只规范化前三种：

 ```lua
   directory -> directory
   link      -> symlink
   file      -> file
   其他类型  -> 原样保留
 ```

 所以 char、block、fifo、socket 都可能进入 fre 的 tree。甚至自定义 filesystem adapter 还能返回其他非空 kind，因为 tree 当前没有白名单限制。

 但 mutation prepare 只支持：

 ```lua
   file
   directory
   symlink
 ```

 因此 char 可以被加载和显示，却无法通过 :w 的 snapshot 验证。这正是当前错误的内部不一致。
