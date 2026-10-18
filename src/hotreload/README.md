# Collector：整个游戏模块的热重载

窗口和图形设备保持打开，修改 Odin 的 UI 或游戏逻辑并保存，后台编译成功后直接切换到新版本。
保留角色位置、当前分数、已收集节点、时间、暂停状态，以及动态数组里的移动轨迹。
新旧模块使用 JSON 值快照交换世界，不共享旧 DLL 的内存、UI/Clay 或回调。

## 启动和操作

在 olib_sample 根目录运行：

```bat
run.bat hotreload
run.bat hotreload vulkan
run.bat hotreload d3d12
```

需要 `odin` 在 PATH 中、同级 olib（含 `core/hotreload`）和 SDL3 运行依赖。
启动脚本先编译常驻宿主，宿主打开窗口后自动编译第一版游戏 DLL。顶部状态条显示
等待、编译中、LIVE 或错误，以及成功加载的版本号。编译时旧游戏继续运行，失败日志也输出到终端。
保存到显示变化需要源码检测、防抖、编译和状态恢复时间，不是逐键解释执行。

| 操作 | 功能 |
| --- | --- |
| WASD / 方向键 | 移动角色，靠近黄色能量点自动收集 |
| Space 或 Pause / Resume 按钮 | 暂停或继续，暂停时也会检测并应用代码修改 |
| New run | 明确重置这一局 |
| Tab / Shift+Tab、Enter | 聚焦并激活 UI 按钮 |
| F5 | 重新尝试编译当前源码 |
| Esc / 关闭窗口 | 释放模块资源并退出 |

## 实际演示一次 UI 修改

1. 运行 `run.bat hotreload`，向右移动，收集第一个节点，分数变成 10。
2. 点击 **Pause**，便于观察位置、分数和轨迹没有变化。
3. 打开 [`view/ui.odin`](view/ui.odin)，例如修改：

   ```odin
   PANEL_WIDTH :: f32(350) // 默认 300；窄窗口会自适应限制侧栏宽度
   ACCENT :: foster.Color{125, 173, 255, 255}
   TITLE :: "COLLECTOR / REMIX"
   ```

4. 保存。顶部短暂显示 BUILDING，随后版本号增加；标题、侧栏和角色颜色更新，暂停状态与 10 分仍在。

可以直接修改 UI 声明、按钮排布或场景绘制，不限于上述常量。字体借用宿主的共享离线 MSDF 图集；新增图集外文字需要更新字体资产并重启宿主。

## 实际演示一次玩法修改

在 [`logic/rules.odin`](logic/rules.odin) 修改并保存：

```odin
MOVE_SPEED :: f32(440)   // 默认 220
PICKUP_SCORE :: i64(25)  // 默认 10
```

点击 **Resume**，移动速度变为原来的两倍，右侧 LIVE RULES 同步显示新值。
继续向右收集第二个节点：分数应从 **10 变成 35**，第一个节点仍为已收集状态。
这证明改动的是新版本玩法代码，而已有状态没有重新计算或重置。

再故意写一处语法错误并保存，游戏仍使用上一版逻辑；顶部显示红色诊断。修复并保存后自动恢复重载。
不兼容的模块或状态恢复失败也保留上一版；本示例没有静默重开当前局面的回退。

## 结构和边界

```text
src/hotreload/
  main.odin           常驻 App、输入、GPU 同步、字体、编译状态
  contract/           EXE/DLL 共享的宿主服务；改动须重启
  def/                纯数据常量、命令、规则显示值
  data/               World 与 JSON 快照、动态轨迹的所有权
  logic/rules.odin    纯玩法、移动、拾取、暂停与重开
  view/ui.odin        kit/ui 声明、输入命令与场景绘制
  game/module.odin    DLL 导出、世界恢复、游戏与表现组装
```

监听 `game / def / data / logic / view` 中的 Odin 文件。宿主、`contract`、olib 和共享字体不在热重载边界内；
改它们后退出并重新执行启动命令。不要在同一个运行宿主中交替使用不同编译器或不同版本的共享库。
`contract.HOST_VERSION` 对应宿主接口；`game` 导出的 `state_version` 对应 JSON 快照格式。
模块内部结构可改变，但必须兼容已有快照，或显式实现迁移。当前仅接受格式版本 1。

模块的 `load` 只建立候选世界与私有 UI。帧开始等待 GPU idle，再通过
`watch_apply` 完成替换，保留已序列化的游戏状态。
字体和图形设备由宿主持有，UI/Clay、Batcher、世界和轨迹由每版 DLL 创建并在卸载前释放。
输入捕获、鼠标悬停、焦点等瞬时 UI 状态不保存；不把指向旧 DLL 的函数或文字地址留在宿主中。

这是桌面开发示例，不包含 Web/静态发布入口、跨进程存档、联网同步或任意字段的自动迁移。
关闭程序后这一局不持久化；保留状态指同一次宿主运行中的模块替换。

## 显示与单元测试

`scaled` 使用 125% UI 尺寸，`narrow` 使用窄窗口。UI 和 MSDF 按最终像素绘制，
不随低分辨率场景一起放大；窄窗口采用紧凑布局，侧栏可滚动。

无窗口测试：

```bat
odin test src/hotreload -collection:olib=../olib -vet
```

它验证快照恢复的数值与独立内存所有权、暂停、单次拾取、重开和非法世界拒绝。
olib 的 `odin run tools/check` 自动编译宿主与实际 DLL，并运行这些单元测试。
