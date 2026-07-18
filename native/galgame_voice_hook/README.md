# hibiki_voice_hook —— galgame 引擎级 voice hook（C 阶段，独立可选组件）

galgame 一键制卡（[docs/specs/galgame-mining](../../docs/specs/galgame-mining/design.md)）C 阶段：从游戏引擎在**混音之前**截取角色语音的干净音轨，回传 Hibiki 做一键制卡。

## ⚠️ 部署红线：与 hibiki.exe 物理隔离

注入用的 `CreateRemoteThread` / `WriteProcessMemory` 是杀软启发式的「代码注入」特征，**必然报毒**。因此这套组件：

- **单独构建、单独分发**（按需下载的可选组件），**绝不编进 `hibiki.exe` 本体**——否则整个 app 分发口碑受污染。本目录的 CMake **不被 `hibiki/windows` 引用**。
- Hibiki 主进程把 `hibiki_voice_injector.exe` 当**子进程**拉起，通过共享内存（[`include/voice_hook_ipc.h`](include/voice_hook_ipc.h)）消费干净语音——被标记的注入代码只待在这个隔离二进制里。
- 许可：Hibiki 与本组件均 **GPLv3**（与 LunaTranslator/LunaHook 同）。
- 缓解报毒：代码签名改善声誉分（挡不住启发式）；引导用户加杀软白名单（galgame texthook 用户对此有预期）。

## 组成

| 产物 | 作用 |
|---|---|
| `hibiki_voice_hook.dll` | 注入进游戏进程的 hook DLL：混音前截语音写共享内存环形缓冲 |
| `hibiki_voice_injector.exe` | 注入器：把 DLL 注入目标游戏，建共享内存 + 就绪事件，读回语音格式 |

## 构建（32/64 位分开——DLL 位数必须匹配目标进程）

galgame 多为 32 位，须各出一份，injector 与 DLL 同目录并放：

```sh
# x64
cmake -S . -B build/x64 -A x64   && cmake --build build/x64 --config Release
# x86（32 位游戏）
cmake -S . -B build/x86 -A Win32 && cmake --build build/x86 --config Release
```

## 用法

```sh
hibiki_voice_injector.exe --pid <目标游戏PID> [--dll <hook.dll>] [--wait-ms 5000] [--hold]
```

- `--pid`：目标进程 ID（必填）。
- `--dll`：hook DLL 路径（默认取同目录 arch 匹配的 `hibiki_voice_hook.dll`）。
- `--wait-ms`：等「就绪」事件超时（默认 5000）。
- `--hold`：注入确认后常驻（host 模式，维持共享内存存活供消费）；缺省=probe 模式，确认后退出。

成功输出：`OK hooked pid=<..> ring=<..> sr=<..> ch=<..> ...`。

## 分阶段（本组件的实现进度）

- **C.1（已落）**：注入管线 + IPC 契约 proof-of-life。injector 注入 DLL、建共享内存/就绪事件，DLL 注入后标记 `hooked=1` 并 `SetEvent`；位数校验、marker 文件。**编译验证 + 对无害进程真实注入验证**。
- **C.2（待真实 galgame）**：在 `dll_main.cpp` 的标注处安装 XAudio2/DirectSound vtable hook（经 MinHook 之类），混音前把语音 memcpy 进环形缓冲（回调零阻塞，爆音红线），首帧填格式；校准模式识别角色语音 voice callsite（`game.exe SHA + RVA`）。
- **C.3**：逐引擎覆盖（KiriKiri / Artemis / Unity …），其余自动回退 A 阶段 loopback。
- **接 Hibiki**：`EngineHookGalAudioSource` 实现 `GalAudioSource`（Dart 侧），复用 A 阶段同一波形选区 + 制卡出口。
