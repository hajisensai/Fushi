# hibiki_voice_hook —— galgame 引擎级 voice hook（C 阶段，独立可选组件）

本仓库是主 app [`hajisensai/hibiki`](https://github.com/hajisensai/hibiki) 的 native 采集组件（独立可选，单独分发）。galgame 一键制卡（[docs/specs/galgame-mining](https://github.com/hajisensai/hibiki/blob/develop/docs/specs/galgame-mining/design.md)）C 阶段：从游戏引擎在**混音之前**截取角色语音的干净音轨，回传 Hibiki 做一键制卡。

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

## 引擎支持矩阵

机器可读的唯一真相源是 [`engine-support.yaml`](engine-support.yaml)，可读版本是自动生成的
[`docs/engine-support.md`](docs/engine-support.md)。更新真实样本证据后运行：

```sh
python tools/generate_engine_support.py
python tools/generate_engine_support.py --check
python tests/engine_support_manifest_test.py
```

清单采用 YAML 1.2 兼容的 JSON 语法，因此生成器只依赖 Python 标准库。识别签名不得仅从外部引擎资料库
照抄；每个非空签名组都必须记录真实样本或运行时观察证据。

## 引擎开发流水线

统一入口 `tool/galhook.ps1` 提供证据、诊断与适配工作流：

```powershell
./tool/galhook.ps1 evidence init engine_id
./tool/galhook.ps1 verify-evidence .galhook-evidence/engine_id-hook-evidence.json
./tool/galhook.ps1 explain-diag --hookdiag 0x0 --hookio 0x0 --lunadiag 0x0
./tool/galhook.ps1 check --dry-run --native
./tool/galhook.ps1 probe C:\game\game.exe --output probe.zip
./tool/galhook.ps1 new engine_id --hibiki-root C:\src\hibiki
./tool/galhook.ps1 replay tests/fixtures/workflow_replay.json
```

- `evidence init` 创建单引擎、逐阶段的证据台账；`verify-evidence` 阻止跳阶段、Loopback
  冒充引擎音频，以及缺真实身份/哈希/同会话制卡证据的支持升级，并输出台账 SHA-256。
  默认任务台账位于已忽略的 `.galhook-evidence/`，避免把未脱敏现场记录误提交。
  `timeline[].event` 使用固定名称：
  `process_start`、`attach`/`injection`、`target_module_loaded`、`helper_loaded`、
  `hook_installed`、`helper_ready`、`ipc_ready`、`first_text`、`text_thread_selected`、
  `first_resource`/`first_pcm`/`first_loopback`、`paired`、`screenshot`、`card_written`。
  新增或升级 manifest 的 `partial` / `verified` 状态或能力时，必须将通过的台账保存到
  `evidence/*.json`，并在该引擎的 `support_evidence` 列表中按会话填写 `file`、`sha256`
  和 `capability_refs`。不同 resource/PCM 会话可累积为多个记录；每条 refs 必须与对应
  哈希台账的 `release.proved_capabilities` 完全一致，并绑定正确 proof boundary。新增
  `verified_games` 还必须填写该行 canonical SHA-256 的 `verified_game_ref`，生成器会核对
  游戏名、版本、架构、exe hash 与日期。进程策略等 engine-level 语义变化还要用
  `engine_claim_refs` 精确匹配台账内带 value hash 的 `release.proved_engine_claims`；
  无关音频证据不能为策略变化洗白。跨引擎、哈希漂移、错音频层或仅 Loopback 的证据均会被拒绝。
- `explain-diag` 直接解析 `include/voice_hook_ipc.h` 中的常量并输出未知位，避免人工误拆
  `hookdiag` / `hookio` / `lunadiag`。
- `check --dry-run` 无副作用地列出检查；显式加 `--native` 才把 x86/x64 构建与 CTest
  纳入计划。不加 `--dry-run` 时逐项执行并在首个失败处停止。
- `probe` 只打包路径脱敏的元数据、PE imports、哈希和可选 trace 摘要；默认不复制 exe、脚本、图片、语音。
- `new` 生成未验证 profile、独立 adapter、native/Dart 测试和 fixture，并写入编译与 registry 生命周期接缝。
- `replay` 离线验证线程过滤、去重、资源晚到、文本-音频配对、fallback 顺序与会话清理。

Ren'Py/FFmpeg 路径会识别任意带 major 的 `avformat-*.dll` / `libavformat-*.dll`，把本地
OGG/WAV/Opus/FLAC 资源作为固定容量事件交给 worker 验签和复制；只有旧 major 54 继续使用专属
PCM 结构兼容层。检测到 Ren'Py 目录签名时，injector 会自动等待并按 python/FFmpeg 运行时模块
选择真实游戏子进程；其它启动器可显式传 `--follow-child-processes`。

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
hibiki_voice_injector.exe --pid <目标游戏PID> [--dll <hook.dll>] [--wait-ms 5000] [--hold] [--luna-pchooks]
hibiki_voice_injector.exe --launch <游戏exe> [--workdir <目录>] [--arg <参数>]... [--japanese-locale] [--dll <hook.dll>] [--wait-ms 5000] [--hold] [--luna-pchooks]
```

`--launch` 对普通游戏使用挂起创建、注入后放行；Steam 库内游戏会先通过
`steam://run/<AppID>` 交给客户端启动，再以 15ms 间隔按完整 exe 路径自动识别并注入真实游戏进程。
若同一路径的游戏已经运行，则直接复用该进程，不再请求 Steam 启动第二实例。

- `--pid`：附着模式的目标进程 ID；与 `--launch` 二选一。
- `--launch`：由 injector 启动游戏并注入；普通引擎用 CREATE_SUSPENDED 早注入，Steam 游戏由客户端启动后自动识别真实进程，`SiglusEngine.exe` 会自动改为 Enigma-safe 延迟附着。
- `--japanese-locale`：x86 helper 使用同目录随包提供的 Locale Emulator 2.5.0.1 运行库，以日语 CP932 创建同一个挂起游戏进程，再完成早注入；不修改 Windows 全局区域设置。Siglus/子进程启动器会先恢复主线程再做延迟发现；Steam 协议启动无法保留该创建边界，会明确告警并沿用 Steam 原始启动。
- `--dll`：hook DLL 路径（默认取同目录 arch 匹配的 `hibiki_voice_hook.dll`）。
- `--wait-ms`：等「就绪」事件超时（默认 5000）。
- `--hold`：注入确认后常驻（host 模式，维持共享内存存活供消费）；缺省=probe 模式，确认后退出。
- `--luna-pchooks`：LunaHook 连接后补装通用 PC hooks。Unity/Mono/IL2CPP 自绘文本常需要；`manosaba.exe` 与带 `UnityPlayer.dll` + `GameAssembly.dll` / `*_Data/il2cpp_data` / Mono 目录的目标在 `--launch` 和 `--pid` attach 下都会自动启用。

x86 release 包额外包含 Locale Emulator 的 `LoaderDll.dll`、`LocaleEmulator.dll` 与 LGPL-3.0
许可文本；二进制从官方 v2.5.0.1 release 以固定 SHA-256 下载，未修改，也不会运行其安装器。

成功输出：`OK hooked pid=<..> ring=<..> sr=<..> ch=<..> ...`。

## Unity / IL2CPP / manosaba 支持

`D:\steam\steamapps\common\manosaba_game\manosaba.exe` 实机目录含 `UnityPlayer.dll`、`GameAssembly.dll`
和 `manosaba_Data/il2cpp_data/Metadata/global-metadata.dat`，判定为 64 位 Unity IL2CPP（不是 Mono 运行时）。
Hibiki 的 launch 与已运行窗口 attach 路径都会为这类目标自动打开 Luna PC hooks，使自绘文本进入同一
共享内存文本环；音频侧若没有可读引擎 PCM，会保留文本 helper，并与系统 Loopback 组成混合捕获，不能
因为音频降级而关掉正确文本。

## 分阶段（本组件的实现进度）

- **C.1（已落）**：注入管线 + IPC 契约 proof-of-life。injector 注入 DLL、建共享内存/就绪事件，DLL 注入后标记 `hooked=1` 并 `SetEvent`；位数校验、marker 文件。**编译验证 + 对无害进程真实注入验证**。
- **C.2（已验证）**：XAudio2/DirectSound vtable hook 已落地，并在真实 32 位 KiriKiriZ 与 SiglusEngine 游戏验证非静音 PCM 可由共享内存读取。Siglus 的 DirectSound COM 创建路径也已覆盖。
- **C.3（部分完成）**：SiglusEngine `koe/*.ovk` 已支持逐句提取完整 Ogg/Vorbis；其它引擎继续回退 A 阶段 loopback。KiriKiriZ 的 DirectSound 输出仍是软件混音后的 BGM+语音，不能视为干净语音。
- **接 Hibiki**：`EngineHookGalAudioSource` 实现 `GalAudioSource`（Dart 侧），复用 A 阶段同一波形选区 + 制卡出口。

## SiglusEngine 支持

正式版 `SiglusEngine.exe` 使用 x86 injector。`--launch` 会识别该文件名，先让 Enigma 保护壳正常初始化，等游戏窗口出现后再自动附着（对其它引擎仍是 CREATE_SUSPENDED 早注入）；也可对用户已打开的游戏使用 `--pid`。hook 跟踪引擎之后读取的 `koe/*.ovk`，按归档头中的 16-byte 索引精确取出当前条目的完整 Ogg，并写到：

```text
%TEMP%\hibiki_gal_voice\<tick>_<archive>.ovk_<voice-id>.ogg
```

导出前会同时检查索引边界、条目上限、Ogg 页序列号和 EOS；文件 IO 与 Ogg 校验在工作线程执行，`ReadFile` detour 只复制固定大小任务。晚附着可能没有 DirectSound PCM 格式，Hibiki 会用 `rawVoiceReady` 保持引擎源，并优先把本会话的新 Ogg 转为 Anki 音频；无文本时间戳时只选本会话最新条目，绝不拿上一局残留。受保护的 Siglus 进程若令 Toolhelp 线程快照失败，vendored MinHook 会通过 `NtGetNextThread` 安全枚举并冻结其它线程后再启用 hook。
