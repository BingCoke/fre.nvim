## instance不应该感知任何的registry
包括他的子模块
然后没必要instanceid要对齐, 只需要保证node id对齐即可, 这个只需要instance自己去处理就可以了
FreRegistryMarkerWidthsChanged 这个event事件是否可以直接不要了 列宽的columns变大变小 不需要让registry感知, 然后没必要instanceid对齐, 那么registry所有关于列宽的代码完全不需要


然后跨instance的文件处理, 可以提供callback 拿到一个获得instance的callback接口然后拿到instance的句柄去处理

不要搞得太复杂, 这个没办法, 这个必须要暴露调用者上层的instance管理机制, newInstace 接受没有传入这个callback, 但是如果传入没有callback 但是用了跨instance的机制就报错

## columns 隐藏action  , instance 暴露出这个接口, toggle/hidden/show


## instance 接口太多, 
有的是一类生命周期管理, 比如 hidden_file的处理, 上面我们需要的columns显示管理, expand管理
我希望instance暴露出一个handler之类的其他的, 这个handler去做, 而不是全部堆在instance这个对象中
你觉得怎么样, 当前的instance其实还好, 还是说要做拆分,  我需要中立的回答, 不需要你因为我的想法左右
最好是开启suabgent 把两个想法说出来 子subagent裁决,


## 顶层的view.lua 是否可以删掉了 

## watch.lua 的作用是什么





话说gc的时候, 直接调用destory, 然后manager通过event去处理的引用关系吗, 还是说gc调用manager?

