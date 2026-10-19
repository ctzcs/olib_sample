# 热重载：最小示例

窗口和图形设备一直开着，游戏代码放在 DLL 里；保存源码后后台自动编译，成功就替换游戏，
方块的位置和拖尾保留。只有三个文件：

```text
src/hotreload/
  main.odin             宿主：窗口和输入，热重载只有 hot_init / hot_update / hot_render / hot_dispose
  contract/contract.odin  宿主和游戏共用的类型（输入、App 指针）
  game/game.odin        游戏：State（含拖尾数组和 Render2D 与材质库）和一张 Game_Hooks 回调表
```

## 运行

在 olib_sample 根目录：

```bat
run.bat hotreload
```

终端先输出 `Compiling the first version...`，几秒后出现 `LIVE version 1`，窗口里出现方块；
WASD 或方向键移动，Esc 退出。

## 试一次热重载

1. 移动方块到某个位置。
2. 打开 [`game/game.odin`](game/game.odin)，修改并保存：

   ```odin
   SPEED :: f32(480)                          // 默认 240
   SIZE :: f32(96)                            // 默认 64
   COLOR :: foster.Color{255, 147, 135, 255}  // 默认青绿色
   ```

3. 终端输出 `LIVE version 2`，方块立刻变快、变大、变色，**位置没有跳回起点**。
4. 故意写错一处语法再保存：终端打印编译器错误，游戏继续用上一版运行；改对后保存即自动恢复。

## 它是怎么工作的

**宿主**（`main.odin`）只管窗口和输入，热重载交给库里的 `Hot`，四个调用：

| 调用 | 位置 | 作用 |
| --- | --- | --- |
| `reload.hot_init` | Startup | 给出游戏包目录、`-collection` 和宿主服务，库在后台编译并监听源码 |
| `reload.hot_update` | 每帧 Update 开头 | 检查编译结果；新版本编好就（先等 GPU 空闲）替换，失败则保留旧版；再转发游戏的 `update` |
| `reload.hot_render` | Render | 转发游戏的 `render` |
| `reload.hot_dispose` | Shutdown | 卸载游戏并等待编译任务结束 |

**游戏**（`game/game.odin`）写一个 `State` 和一张回调表 `Game_Hooks`，库负责导出和交接：

| 回调 | 何时调用 |
| --- | --- |
| `reset` | 第一次启动时给 `State` 填初值；热重载时不调用，`State` 由旧版本交接 |
| `start` / `stop` | 每次加载 / 卸载一个版本：创建 / 释放这个版本的资源（这里是 `State` 里的 Render2D 与材质库） |
| `drop` | 游戏真正结束时释放 `State` 拥有的堆数据（这里是拖尾数组） |
| `update` / `render` | 每帧调用 |

热重载时 `State` 整体交给新版本：`trail` 数组原样保留（新旧版本共用同一块堆内存），`batcher` 由新版本的
`start` 重新创建，旧版本的 `stop` 释放旧的。所以 `State` 里可以放数组和 Render2D 与材质库，但不要放字符串字面量、
函数指针这类指向 DLL 自己数据的指针。改了 `State` 的字段布局会被拒绝（提高 `state_version` 后重开）；
需要跨字段变化保留局面、自定义编译命令或迁移策略时，改用完整接口
（`reload.init` / `watch_init` / `API`），见 [core/hotreload/README.md](../../../olib/core/hotreload/README.md)。

## 边界

- 宿主、`contract/` 和 olib 的改动不会热重载：改了之后退出并重新运行。改 `contract` 还要把 `HOST_VERSION` 加一。
- 宿主和 DLL 必须用同一版本的 Odin 和相同的编译选项。
- 这是开发期桌面机制，发布版本不包含它。接入已有项目的细节见
  [core/hotreload/README.md](../../../olib/core/hotreload/README.md)；新项目直接用 `tools/new-game` 生成的模板，
  它已经把宿主、模块、状态快照和失败提示都接好了。
