# Galgame 引擎适配体系 —— 实现计划（engine adapter plan）

> **用途语境（先读）**：Hibiki 是一款日语沉浸学习软件（词典 / Anki 制卡 / 阅读器 / 有声书 / 视频字幕）。
> 本计划面向其中"galgame 一键制卡"能力：从用户本地已购买的视觉小说里，**提取当前对话的文本、对应逐句
> 配音、以及游戏画面截图，组装成 Anki 记忆卡片**，供学习者复习。这与 Textractor / Yomitan / ASBPlayer
> 等成熟的沉浸学习工具同类，属正常语言学习用途。本文只讨论如何把"新增一个游戏引擎的适配成本"降下来。
>
> 面向接手的 AI/开发者，**自包含**。总设计见 [design.md](design.md)，已完成进度与真机证据见 [handoff.md](handoff.md)。
> 一句话目标：在 **hibiki-hook**（native 采集组件）与 **hibiki**（Dart 消费端）两仓之间，建立
> 数据驱动 + 模块化 + 可诊断 + 可离线验证的引擎适配体系，把"新增一个引擎"从"改 2666 行巨型
> `dll_main.cpp` / 从零调查"降到"加 profile + 独立 adapter + fixture"，并完成至少一批高复用适配
> （RealLive / VisualArt's）作为验证。**核心不是承诺"支持所有引擎"，而是显著降低新增成本并落一批验证。**

---

## 阶段一览（先扫这张表 + 依赖图，再读细节）

| 阶段 | 一句话目标 | 主要产出 | 落在哪个仓 | 验证门 |
|---|---|---|---|---|
| **P0** | 建机器可读真相源 | `engine-support.yaml` + yaml→md 生成器 | voice-hook | 生成器可跑、矩阵与 §1 基线一致 |
| **P1** | 无行为变化拆 `dll_main.cpp` | adapter 契约 + registry，各引擎逻辑搬进 adapter | voice-hook | CTest 全绿、零行为变化 |
| **P2** | 收敛 LunaHook 集成 | 版本化稳定 IPC + ABI 桥接层/守卫 + Hook Code 数据驱动 | voice-hook→hibiki | ABI 契约测试、导出守卫、回放测试 |
| **P3** | probe/new/replay 流水线 | 统一 `tool/galhook.ps1` + `docs/agent/galgame-hooking.md` | voice-hook + hibiki | 三条命令可跑 + 自动化测试 |
| **P4** | 按共享层优先扩音频 | 泛化 FFmpeg / 子进程跟随 / 通用资源事件 | voice-hook | 真实样本验证、回调零阻塞 |
| **P5** | 首批引擎验证 | RealLive/VisualArt's 等 profile+adapter+fixture | 两仓 | fixture + 真实游戏真机验证留证据 |

**铁律**：每阶段独立可审查提交；**先无行为变化重构（P1），再扩能力（P3+），两者绝不混进同一提交**。

**依赖顺序**（横向可并行，纵向有依赖）：

```
P0 (真相源) ──► P1 (拆 adapter) ──┬─► P3 (probe/new/replay 流水线) ──► P5 (首批引擎验证)
                                  └─► P4 (共享层音频扩展) ──────────────┘
              P2 (LunaHook 收敛) ──► P3   （P2 与 P1 可并行，都为 P3 提供稳定接缝）
```

- P0 是所有阶段的事实底座，**必须最先落**。
- P1 与 P2 可并行（一个管音频 adapter 拆分，一个管文本 IPC），都在为 P3 铺稳定接缝。
- P3 是「降低新增成本」的核心交付；P4/P5 依赖 P1+P3 的 adapter 骨架。

## 执行进度（2026-07-22）

- **P0 已完成**（hibiki-hook `77c6cf8`）：新增 `engine-support.yaml` 单一真相源、依赖-free
  生成器、自动生成的 `docs/engine-support.md`、真实样本证据守卫和 CI 漂移检查。矩阵覆盖 Siglus、
  KiriKiriZ、通用 XAudio2/DirectSound、Ren'Py/FFmpeg 54、Unity IL2CPP；已实现但缺真机命中的路径明确
  标成 `implemented_unverified`，没有扩大兼容宣称。Hibiki 侧只读同步副本见
  [engine-support.md](engine-support.md)。
- **P1 已完成**（hibiki-hook `f4242b9`）：`dll_main.cpp` 从约 3940 行降到 521 行；新增
  `EngineAdapter` 契约、中心 registry、工作线程模块观察接缝，并把 Unity、Windows 通用音频、Siglus、
  KiriKiri、Ren'Py、文本渲染、Loopback 原样拆到 `hook/adapters/`。HookWorker 只保留 IPC、共享状态、
  registry 生命周期和 MinHook 收尾。
- 验证：x64/x86 均成功 configure/build；两个架构各 10 个 CTest 全绿；清单生成/漂移检查、3 个清单
  契约测试、3 个 adapter 结构守卫全绿。P1 没有新增引擎能力；本轮未重复跑商业游戏真机路径，因此
  真机支持范围仍严格沿用 §1 的既有证据。
- **P2 已完成**（hibiki-hook `7c4beaa`；hibiki `ff1e0197f`）：LunaHost 回调布局、函数类型和导出表收进
  `luna_bridge.h`，稳定 IPC 升至 v11 并显式携带 IPC/bridge/vendored Luna 三个版本；新增四 DLL
  SHA-256 版本清单、同步/差异工具、导出 CTest 与 ABI 静态契约测试。Hook Code 的唯一内置表改为 TSV，
  由 exe SHA-256 或 module name + SHA-256 匹配，移除了安装目录判断；Hibiki 可保存当前线程 Hook Code，
  并导入/导出同 schema 的用户表。自动/手动线程选择逻辑提取成纯 selector，以 8 行 trace fixture 回放。
- P2 验证：hibiki-hook x64/x86 均成功构建且各 13 个 CTest 全绿；清单/生成器/同步守卫全绿。Hibiki
  新增 profile 单测 4 项，连同音频/会话/线程目录定向测试共 75 项全绿，MD3 + game page 65 项全绿，
  Windows debug 构建成功；相关 Dart 文件 `dart analyze` 无问题。全量 `flutter analyze` 在本机 Flutter
  3.44 的 analysis server 读取 LSP JSON 时自身崩溃，未产出代码诊断，故全阶段总闸暂不勾选。本轮未
  重跑商业游戏；9-nine 内置配置只把既有真机 Hook Code 改由已读取的真实 exe SHA-256 匹配。
- **P3 已完成**（hibiki-hook `195b76d`；hibiki `a42df794e`）：新增统一
  `tool/galhook.ps1` 入口。`probe` 产出仅含脱敏元数据/PE imports/能力摘要的诊断 ZIP，默认不复制游戏
  载荷；`new` 自动生成并注册 profile、独立 adapter、native/Dart 测试与 fixture，且没有跳过结构守卫的
  开关；`replay` 离线覆盖线程过滤、文本去重、resource/PCM/loopback 配对优先级、资源晚到和会话清理。
  registry 新增受管生成接缝，普通 adapter 不再需要修改 worker 主干。开发 SOP 已写入
  [galgame-hooking.md](../../agent/galgame-hooking.md) 并由根 `CLAUDE.md` 索引。
- P3 验证：工作流测试 4 项、adapter 结构守卫 4 项、清单契约 3 项全绿；x64/x86 均成功增量构建且
  各 13 个 CTest 全绿。对 9-nine Episode 1 的真实 exe 运行默认静态 probe，ZIP 仅有
  `diagnostic.json` / `README.txt`，隐私检查通过；这只是工具隐私路径验证，没有重跑游戏内采集，故不
  扩大该游戏的兼容宣称。
- **P4 实现已落、真机门未完成**（hibiki-hook `552e75a`；hibiki `c0af9b31a`）：FFmpeg 模块识别
  泛化为任意带 major 的 `avformat` / `avcodec`；本地 OGG/WAV/Opus/FLAC 由固定容量事件交给 worker
  验签、去重和复制，只有 major 54 继续走旧结构 PCM 兼容层。legacy decode 回调改为
  `TryEnterCriticalSection` + 8×256 KiB 有界帧槽，只做上限 memcpy，分配/转换/写盘均移到 worker。
  injector 能按 Ren'Py 目录签名自动启用子进程跟随，并按 python 名称与已加载 FFmpeg 模块评分；也可
  显式传 `--follow-child-processes`。Hibiki host 已同步资源就绪诊断位。
- P4 自动化验证：x64/x86 均成功构建且各 15 个 CTest 全绿；新增 FFmpeg module/资源魔数、子进程
  选择、回调零阻塞结构守卫和 host IPC 契约测试。本机已只读检查常用 galgame/Steam 目录，没有找到
  可运行的 Ren'Py/FFmpeg 样本；既有 Sakura Swim Club 记录也只证明 loopback，因此矩阵继续标
  `implemented_unverified`，**P4 完成框保持未勾选**。
- **P5 实现已落、RealLive 真机门未完成**（hibiki-hook `30fac24`；hibiki `aeb5acf12`）：新增
  `reallive` profile、独立 adapter、离线 replay fixture、native 测试和 Hibiki 生产配对链测试。旧
  VisualArt's 路径只复用经过严格边界检查的 OVK 索引/Ogg EOS 读取层；共享文件 hook 在首次实际打开
  `.ovk` 后才发布资源音频就绪，避免普通游戏误入资源等待。观察到 OVK 不会让 RealLive profile 匹配，
  在取得真实样本 hash 前不产生引擎身份宣称。`galhook new` 同时补上全局 profile include 生成接缝，
  新骨架可直接汇总编译。
- P5 自动化验证：x64/x86 DLL 均成功构建且各 16 个 CTest 全绿；清单/生成器/adapter 结构/工作流守卫
  全绿；RealLive replay 选择晚到 OVK resource、保持 PCM/loopback 兜底并完成会话清理；Hibiki 定向
  Flutter 测试 17 项全绿，三个变更 Dart 测试逐文件 analyze 无问题。本机只读搜索了常用游戏目录，
  找到的是既有 `anemoi` Siglus/OVK 样本，没有 `RealLive.exe`、`Gameexe.ini` 或 NWK/KOE/NWA 样本；
  Siglus 证据不能替代 RealLive 真机证据，因此矩阵保持 `implemented_unverified`，**P5 完成框保持未勾选**。
- **Steam 启动链路补强**（hibiki-hook `7709bf3`，[[BUG-1012]]）：Steam 库游戏不再靠 AppID
  环境变量直接 `CreateProcessW`，而是由 `steam://run/<AppID>` 正常启动，再以 15ms 间隔按完整镜像路径
  自动发现并注入真实游戏进程；已有同路径实例则直接复用，避免客户端二次拉起和单实例冲突。Manosaba
  已从无进程状态按原始「启动并捕获」路径真机复测：只有一个游戏窗口、无 `Another instance`，helper
  返回 `OK hooked`，Luna/TMP 文本、Unity 音频事件和 44.1kHz 双声道 loopback 均有数据。角色逐句资源
  事件等待游戏内实际播放一句语音后补记。
- 下一步：P4 需要可运行的 Ren'Py/FFmpeg 原始样本；P5 需要可运行的 RealLive/旧 VisualArt's 原始样本，
  再补 executable/module hash、Luna 对话线程回放、OVK 字节一致性与原始路径制卡证据。

---

## 0. 开工前必读 & 纪律（指针，不重复）
- hibiki 侧：读根 `CLAUDE.md` + `hibiki/CLAUDE.md` + 本目录 `design.md` / `handoff.md` + `docs/agent/build.md`。
  native 侧：读 hibiki-hook 仓的 README + CMake。
- 两仓都用**独立 worktree/分支**；hibiki 侧新建 worktree 后先跑 `tool/setup_worktree.ps1`，并在
  `.worktrees/coordination/claims/` 登记 ownership。不覆盖用户或其它 agent 的未提交改动。
- **根因修复**，不做延迟/重试/吞异常/硬编码/特例分支式绕过；只有外部/平台限制才允许临时兼容层并说明清理条件。
- 每阶段独立可审查提交；真机验证留证据；缺样本的能力**显式标注"未真机验证"**。
- 真 bug 走 `docs/bugs` 一 bug 一文件（① 根因修复 ② 最强层加自动化测试），用 `dart run tool/bug.dart new`。
- 新增 Dart helper 要有明确类型签名；i18n key 改动走 `hibiki/tool/i18n_sync.dart` 再 `dart run slang`。

---

## 1. 当前真相（已核实 @ 2026-07-21，origin/develop；接手前提，先信这些再动手）

### 【两仓架构 —— 最重要】
- native 采集组件已在 commit `d53e1238d`「voice hook helper 完全迁移到独立仓库 hibiki-hook」
  **从 hibiki 单仓整体迁出到独立仓 `hajisensai/hibiki-hook`**，理由有二：
  1. 该组件随游戏进程加载做文本/音频采集，部分杀软对这类"随进程加载的采集模块"存在误报，物理隔离到独立仓
     可与主 app 分开构建/分发、降低对主 app 的误报牵连；
  2. 独立仓默认分支上的 `voice-hook-helper.yml` 才能正常 `workflow_dispatch` 刷新 release（主仓那份不在
     默认分支无法 dispatch）。
- **因此：原始设想里要拆的"巨型主流程" `native/galgame_voice_hook/hook/dll_main.cpp`（P1 前已增长到
  约 3940 行）现在在 hibiki-hook，不在 hibiki。** hibiki 已无此目录（迁出前最后快照见
  `origin/worktree-galgame-mining`）。P1 后主文件为 521 行，具体逻辑已在 `hook/adapters/`。
- hibiki-hook 现有结构（P0/P1 后）：
  - `CMakeLists.txt`（`-A x64` / `-A Win32` 双架构）
  - `engine-support.yaml` + `tools/generate_engine_support.py` + 自动生成 `docs/engine-support.md`
  - `hook/adapter.h`（`probe/install/capabilities/onModuleLoaded/shutdown/diagnostics` 契约）
  - `hook/adapter_registry.inc`（中心注册/重试预算/统一模块观察）
  - `hook/adapters/`（Unity/Siglus/KiriKiri/Ren'Py/XAudio2/DirectSound/文本渲染/Loopback 独立逻辑）
  - `hook/dll_main.cpp`（**521 行**，共享 IPC/环形缓冲基础设施 + registry 生命周期）
  - `injector/injector_main.cpp`（`--launch <exe>` 随启动加载 / `--pid` 运行中附着 两种模式）
  - `include/voice_hook_ipc.h`（IPC 契约，与 hibiki 侧同名头对齐）
  - `tools/ring_probe.cpp`（`hibiki_voice_ring_probe`，读共享内存做诊断）
  - `tools/luna_symcheck.cpp`（`hibiki_luna_symcheck`，**已是 LunaHost 导出/ABI 守卫**——桥接层从这里长）
  - vendored `third_party/minhook`（含 `NtGetNextThread` 线程枚举兜底，兼容部分游戏令 Toolhelp 快照失败的场景）
- 发布契约：CI `voice-hook-helper.yml` 反复 upsert 同一 prerelease tag `voice-hook-helper`；每架构 zip
  平铺 4 文件 `injector.exe + hook.dll + LunaHook<arch>.dll + LunaHost<arch>.dll` + `.sha256` 侧车；
  x64 另含 `unity_audio_runtime`（net8.0，Unity IL2CPP 音频提取运行时）。app 端 `_extractZip` 只取 basename 平铺。

### 【hibiki 侧（消费端，只在这里）】
- IPC/reader：`hibiki/windows/runner/voice_hook_ipc.h`、`voice_hook_reader.{cpp,h}`、`voice_hook` channel
  （`grabRecent`、`processIsWow64`、`rawVoiceReady`）。
- Dart 制卡/音频：`hibiki/lib/src/mining/galgame_audio_source.dart`（`EngineHookGalAudioSource` /
  `LoopbackGalAudioSource`）、`galgame_audio_encode.dart`、`galgame_library.dart`、
  `galgame_system_ui_filter.dart`、`galgame_waveform*.dart`。
- helper 安装/下载：`hibiki/lib/src/mining/galgame_helper_installer.dart`
  （`kGalgameHelperRepo = 'hajisensai/hibiki-hook'`、tag `voice-hook-helper`、镜像回退纯函数
  `galgameHelperCandidateUrls`、`exeIs32Bit` 读 PE COFF Machine 选 x86/x64 组件）。
- 文本覆盖：`hibiki/lib/src/platform/gal_hook_text_overlay_channel.dart`。
- 现成可复用件（design.md 已核实 file:line）：制卡入口 `ImmersionMiningEngine.mine`
  （`immersion_mining_engine.dart:83`）、外部窗口请求 `buildExternalWindowRequest`
  （`external_window_mining.dart:19`）、抓帧 `WindowCaptureChannel.captureWindow`
  （`window_capture_channel.dart:47`）/ native `hibiki/windows/runner/window_capture.cpp`、
  channel 注册范式 `flutter_window.cpp:1254`。
- 红线（design.md「关键约束」，不可破）：
  1. `providedAudioBytes` 逐字节写盘不重编码（`immersion_mining_engine.dart:173`）；裸 PCM 先包 WAV 再
     `extractAudioSegmentViaFfmpeg` 编码成 AAC/m4a。
  2. C 阶段音频回调**零阻塞**：回调里只 memcpy + 无锁队列 push，写盘/编码/IPC 全移出工作线程；队列满即丢，
     保游戏正常出声。
  3. 32 位游戏内存预算：采集组件 <16MB、共享池 ≤64MB、单句 ≤30s。
  4. 采集组件**绝不编进 `Hibiki.exe` 本体**（延续两仓隔离）。

### 【已真机验证的引擎（handoff 诚实基线，别推倒重来，只在其上扩展）】
- **Siglus 1.1.141.3**：✅ `koe/*.ovk`（= `u32 count + count×16B index`）逐句原始 Ogg 提取，导出与游戏归档
  逐字节一致（证明是原始逐句角色语音，非 BGM 混音）+ DirectSound PCM（须补 `CoCreateInstance`）。对带保护壳
  的正式版采用"正常启动 → 等游戏主窗口出现后再附着"的**兼容/稳定性策略**（随启动加载会触发保护壳报错）。
- **KiriKiriZ（otomeki.exe, 32 位）**：✅ 采集管线通，**但该引擎软件混音成单流 → DirectSound 输出端拿到的
  是混音 ≈ loopback**，逐句干净语音需读取引擎内部 per-channel（= C.3 深度活，未做）。
- **XAudio2 + DirectSound 通用采集**：✅ 真机。**Unity IL2CPP**：AudioClip/TMP/资源配对已在，x64 带
  `unity_audio_runtime`。全链已"真卡进 Anki"（多游戏，2026-07-18）。

### 【近期相关 bug】
- BUG-957 galgame dead session controller 残留；BUG-961 helper release 404（已本地补发 4×2 资产 + 守卫，
  **复发根源未根治**：`voice-hook-helper.yml` 只在 develop 不可 dispatch，需放默认分支——列为后续）；
  BUG-952 texthooker 线程下拉值不匹配。

### 【原始设想里的幽灵引用（写了但仓库没有 → 新建或改指）】
- `engine-support.yaml` 已由 P0 在 hibiki-hook 落地；仍缺 `tool/galhook.ps1` 与
  `docs/agent/galgame-hooking.md`（P3 待建）。
- `native/galgame_voice_hook/hook/dll_main.cpp` 的正确归属是 **hibiki-hook**，非 hibiki。

---

## 2. 仓库边界（推荐方案，可由用户推翻）
- **hibiki-hook（native 采集相关全归这里，延续隔离）**：
  engine-support.yaml 真相源 + 文档生成器、adapter registry、各引擎 adapter、LunaHost 桥接层 + ABI 守卫
  （扩 `tools/luna_symcheck.cpp`）、probe/new/replay 三条 native 流水线（`tool/galhook.ps1` 落这里）、
  CTest + fixture。
- **hibiki（消费端）**：IPC 契约版本/导出守卫、helper installer / 版本匹配（按 exe/module 哈希）、
  Hook Code 用户导入/导出/保存、Dart 侧文本-音频配对/回放测试、以及从 hibiki-hook 同步/生成的
  **支持矩阵文档副本** + `docs/agent/galgame-hooking.md`（SOP，从 `hibiki/CLAUDE.md` 操作流程索引链接）。
- 若真相源或矩阵文档想主放在 hibiki，请在开工前指明；否则按上表。

---

## 3. 分阶段计划（每阶段独立可审查提交；铁律：先无行为变化重构，再扩能力，两者不混在同一提交）

### Phase 0 — 建机器可读真相源（无代码行为变化，✅ `77c6cf8`）
- 新建 `engine-support.yaml`，字段至少：引擎 id/别名/家族关系；识别规则（exe 名/PE 架构/目录文件/PE imports/
  运行时模块/资源扩展名 + 可选哈希）；进程策略（随启动加载 / 运行中附着 / 普通 attach / 跟随子进程）；
  文本能力（Luna 自动识别 / PC Hooks / 专用 Hook Code / codepage / 线程选择提示）；音频能力 + 优先级；
  已验证游戏/版本/哈希/证据/当前状态/已知限制；对应 adapter/fixture/测试路径。
- 生成器：yaml → 可读支持矩阵 md。**禁止再手工维护多份互相矛盾的状态表。**
- 识别签名（exe 名/PE imports/资源扩展名/资源哈希）必须来自真实样本实测，不照抄外部资料库。
- 用 §1 真机基线填 Siglus/KiriKiriZ/XAudio2/Unity 真实状态，消除 handoff 与旧设想口径不一致。
- **完成定义**：yaml 单一真相源存在且能自动生成矩阵 md；Siglus/KiriKiriZ/XAudio2/Unity 状态与 §1 基线逐条一致；本阶段零代码行为变化。

### Phase 1 — 无行为变化拆分 `dll_main.cpp`（在 hibiki-hook，✅ `f4242b9`）
- 统一 adapter 契约：`probe`（是否适用）/ `install` / `capabilities`（text, resourceAudio, pcmAudio）/
  `onModuleLoaded`（延迟加载 DLL）/ `shutdown`（安全停止释放）/ `diagnostics`（结构化诊断）。
- 建中心 registry；主 worker 只负责生命周期 + 注册调度。把现有 Unity/Siglus/KiriKiri/Ren'Py/XAudio2/
  DirectSound/文本渲染逻辑逐个搬进 adapter，**先做到零行为变化并过 CTest**，再进 Phase 3+。
- 用模块加载通知 / 统一 LoadLibrary 观察机制替代硬编码重复轮询。
- **完成定义**：adapter 契约 + registry 落地，各引擎逻辑全部搬进独立 adapter，主 worker 只剩生命周期/注册调度；CTest 全绿且行为与拆分前逐项一致（零行为变化，不与 P3+ 能力扩展同提交）。

### Phase 2 — 收敛 LunaHook 集成（在 hibiki-hook，向 hibiki 输出稳定 IPC）
- LunaHook 仍是主文本来源（复用这一开源文本提取工具，不重造上游引擎文本能力）。把对特定 LunaHost ABI 的
  依赖收进独立桥接层，向 hibiki 输出**版本化、稳定的 IPC**。新增：LunaHost/LunaHook 版本 + 导出检查
  （扩 `luna_symcheck`）；上游版本同步 + 差异检查工具；ABI 契约测试；Hook Code 数据驱动配置；用户导入/
  导出/保存 Hook Code；配置**按 exe/module 哈希匹配（禁止仅依赖安装路径）**；文本线程目录/过滤/手动 +
  自动选择的回放测试。
- **完成定义**：LunaHost ABI 收进独立可升级桥接层并有版本 + 导出守卫；Hook Code 数据驱动、按 exe/module 哈希匹配（非安装路径）；ABI 契约测试 + 文本线程选择回放测试通过；向 hibiki 输出的 IPC 已版本化。

### Phase 3 — probe/new/replay 流水线（统一命令 `tool/galhook.ps1`）
- `probe <exe>`：采集脱敏特征（目录/PE imports/进程树/加载模块/Luna 线程目录/Hook Code/资源读取事件/
  音频模块/格式/时间戳/能力状态），**默认不复制 exe/脚本/图片/语音等受版权内容**，产出可交 AI 分析的诊断包。
- `new <engine-id>`：生成 profile + native adapter + CTest + Dart 测试 + fixture 骨架并自动注册，
  **不绕过编译/测试守卫**。
- `replay <trace>`：不启动真实游戏即可回放文本/资源音频/PCM/时间戳，验证线程筛选/文本去重/文本-音频配对/
  资源晚到/降级顺序/会话清理。
- 写 `docs/agent/galgame-hooking.md`（用户报告 → probe → 定位 → 实现 → 离线测试 → 真机验收 → 更新矩阵
  全流程），从 CLAUDE.md 操作索引链接。
- **完成定义**：probe/new/replay 三条命令经 `tool/galhook.ps1` 可实际执行且各有自动化测试；probe 默认不带受版权内容；new 不绕过编译/测试守卫；`docs/agent/galgame-hooking.md` 写好并从 CLAUDE.md 索引链接。

### Phase 4 — 按共享层优先扩音频（优先实现覆盖多引擎的公共适配，不优先堆游戏专属 RVA）
- 优先级：原始逐句资源 → 解码器/音频中间件 → 引擎托管 API → XAudio2/DirectSound source → 进程 Loopback。
- 泛化 FFmpeg 适配（不再只 avcodec-54/avformat-54）；自动跟随 Ren'Py 等启动器创建的真实游戏子进程；
  Unity Mono 支持对齐现有 IL2CPP AudioClip/TMP/配对；通用 OGG/WAV/Opus/FLAC 资源事件识别 + 安全重组；
  按真实样本评估 FMOD/BASS/SDL_mixer/CRI；所有回调保持零阻塞（固定大小事件或有上限拷贝，IO/解析/转码
  全进工作线程）。
- **完成定义**：FFmpeg 识别与子进程跟随不再只针对单一旧版 Ren'Py；通用资源事件识别按优先级生效；所有音频回调保持零阻塞（固定/上限拷贝，IO/解析/转码全进工作线程），并有真实样本证据。

### Phase 5 — 首批引擎验证（按复用率，不逐个硬写）
1. **RealLive / 旧 VisualArt's**：复用 Siglus OVK 经验；支持并测试 OVK，评估 NWK/KOE/NWA；资源格式参考
   GARbro（MIT，保留署名 + 许可）；**不因格式相似直接宣称兼容，必须 fixture + 真实游戏验证**。
2. **新版 Ren'Py**：多 FFmpeg 版本 + 子进程发现 + 原始/解码器级音频优先、Loopback 兜底。
3. **Unity Mono**：文本/AudioClip/资源路径/配对，与 IL2CPP 共用上层事件协议。
4. **Artemis / CatSystem / YU-RIS**：先 profile + 通用资源层探测，按真实证据再决定是否加 PFS/INT/YPF 专用 adapter。

**完成定义**：至少 RealLive/VisualArt's 一批完成 profile + adapter + fixture + native 测试 + 上层配对测试，并按原始路径真机验证留证据；缺样本的引擎显式标「未真机验证」，不因格式相似宣称兼容。

---

## 4. 许可（硬约束）
- 资源格式实现优先参考 **GARbro（MIT）**，保留必要署名和许可证；文本实现优先复用 **LunaHook（GPLv3）**，
  遵守 Hibiki 现有隔离分发和许可证要求。
- 通用红线（见 §6）：不 vendoring 任何 NonCommercial/受限许可的二进制或数据，不随 Hibiki 分发。

---

## 5. 完成标准（逐条可验，全满足才可标记完成）
- [x] **[P0]** 引擎支持矩阵有唯一机器可读真相源（engine-support.yaml）并可自动生成文档（`77c6cf8`）。
- [x] **[P1]** 现有采集能力已迁入 adapter registry，主 worker 不再直接堆各引擎实现（`f4242b9`）。
- [x] **[P3]** probe/new/replay 三条工作流可实际执行并有自动化测试（hibiki-hook `195b76d`；hibiki `a42df794e`）。
- [x] **[P2]** LunaHost ABI 收进可升级桥接边界，有版本 + 导出守卫（hibiki-hook `7c4beaa`；hibiki `ff1e0197f`）。
- [ ] **[P5]** 至少完成 RealLive/VisualArt's 首批适配 + fixture + native 测试 + 上层配对测试
      （实现与自动化已落；待 RealLive 原始路径真机证据）。
- [ ] **[P4]** FFmpeg 版本识别与子进程跟随不再只针对单一旧版 Ren'Py。
- [x] **[P1+P3]** 新增一个普通引擎的主要工作可限于 profile + 独立 adapter + fixture，不需改主 worker 主干。
- [ ] **[全阶段]** hibiki-hook x86/x64 native 构建 + CTest 通过；hibiki 侧 `dart format` + `flutter analyze`
      + `flutter test` 通过。
- [ ] **[全阶段]** 所有宣称"支持/修好"的真实引擎按仓库规则走原始路径真机验证并留证据；缺样本能力显式标未真机验证。
- [ ] **[全阶段]** 每阶段独立提交；最终报告含各提交哈希、验证命令、真机证据、未验证项、后续候选
      （含 BUG-961 复发根源：把 `voice-hook-helper.yml` 放默认分支或改触发方式）。

---

## 6. 明确不做（scope guard）
- 不承诺"支持所有引擎"；目标是降低新增成本 + 验证一批高复用适配。
- 不把无行为变化重构与新引擎功能扩展混进同一不可审查提交。
- 缺样本时不宣称兼容；不 vendoring 受限数据；不把采集组件编进 Hibiki 本体。
