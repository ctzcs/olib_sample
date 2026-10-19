# 热重载：最小示例

窗口和图形设备一直开着，游戏代码放在 DLL 里；保存源码后后台自动编译，成功就替换游戏，
方块的位置保留。只有三个文件：

```text
src/hotreload/
  main.odin             宿主：窗口、编译监听、每帧替换检查、转发输入
  contract/contract.odin  宿主和游戏共用的类型（输入、App 指针）
  game/game.odin        游戏：状态、更新、绘制、保存/恢复状态
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

**宿主**（`main.odin`）常驻，创建 `Session`（管理当前 DLL）和 `Watch`（监听源码并后台编译）：

- `reload.init` / `reload.watch_init`：启动时各调用一次，`Watch` 的参数就是一条 `odin build ... -build-mode:dll` 命令。
- `update` 里 `reload.watch_update`，状态变成 `.Ready` 就等 GPU 空闲后 `reload.watch_apply` 替换；失败则保留旧版。
- 每帧把输入写进 `Services`，调用 `reload.update` / `reload.render`，它们转发到当前 DLL 的同名函数。
- 退出时先 `reload.dispose`（卸载游戏），再 `reload.watch_dispose`。

**游戏**（`game/game.odin`）导出一个 `olib_game_api`，提供六个回调：

| 回调 | 作用 |
| --- | --- |
| `load` | 创建私有对象；`snapshot.version == 0` 是第一次启动，否则从快照恢复上一版的状态 |
| `unload` | 释放私有对象（这里是 Batcher） |
| `snapshot_size` / `save` | 把状态按字节交给宿主，下一版 `load` 时恢复 |
| `update` / `render` | 每帧更新和绘制 |

状态 `State` 只放可以按字节复制的数据，所以保存/恢复就是一次 `mem.copy`。以后状态里有动态数组、字符串时，
改成 JSON 或自己的编码，并在格式变化时提高 `state_version`。

## 边界

- 宿主、`contract/` 和 olib 的改动不会热重载：改了之后退出并重新运行。改 `contract` 还要把 `HOST_VERSION` 加一。
- 宿主和 DLL 必须用同一版本的 Odin 和相同的编译选项。
- 这是开发期桌面机制，发布版本不包含它。接入已有项目的细节见
  [core/hotreload/README.md](../../../olib/core/hotreload/README.md)；新项目直接用 `tools/new-game` 生成的模板，
  它已经把宿主、模块、状态快照和失败提示都接好了。
