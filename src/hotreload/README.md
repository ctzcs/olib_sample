# 热重载：最小示例

窗口和图形设备一直开着，游戏代码放在 DLL 里；保存源码后后台自动编译，成功就替换游戏，
方块的位置保留。只有三个文件：

```text
src/hotreload/
  main.odin             宿主：窗口和输入，热重载只有 hot_init / hot_update / hot_render / hot_dispose
  contract/contract.odin  宿主和游戏共用的类型（输入、App 指针）
  game/game.odin        游戏：State 和 reset / start / stop / update / render 五个函数
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

**游戏**（`game/game.odin`）写一个纯数据的 `State` 和五个函数，库负责导出、保存和恢复：

| 函数 | 何时调用 |
| --- | --- |
| `reset` | 第一次启动时给 `State` 填初值；热重载时不调用，状态由库恢复 |
| `start` / `stop` | 每次加载 / 卸载新版本：创建 / 释放不属于状态的资源（这里是 Batcher，放在包级变量里） |
| `update` / `render` | 每帧调用 |

`State` 只放可以按字节复制的数据，保存/恢复就是一次字节复制，格式变化时提高 `state_version`。
状态里有动态数组、字符串、指针，或需要自定义编译命令、迁移策略时，改用完整接口
（`reload.init` / `watch_init` / `API`），见 [core/hotreload/README.md](../../../olib/core/hotreload/README.md)。

## 边界

- 宿主、`contract/` 和 olib 的改动不会热重载：改了之后退出并重新运行。改 `contract` 还要把 `HOST_VERSION` 加一。
- 宿主和 DLL 必须用同一版本的 Odin 和相同的编译选项。
- 这是开发期桌面机制，发布版本不包含它。接入已有项目的细节见
  [core/hotreload/README.md](../../../olib/core/hotreload/README.md)；新项目直接用 `tools/new-game` 生成的模板，
  它已经把宿主、模块、状态快照和失败提示都接好了。
