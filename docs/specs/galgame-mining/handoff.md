# galgame 一键制卡 —— 后续实现交接（handoff）

> 面向接手的另一个 AI/开发者，**自包含**。总设计见 [design.md](design.md)。
> 已完成 A 阶段 Dart 基座 + native loopback + 波形桥 + C.1 注入组件（PR #212）。本文档给出**剩余任务**的落地路径：文件、接缝、gotcha、验证门。

## 落地进度（本轮已完成，编译/单测已验；真机门未过）

> 下列 A5/A6/C.2/C.4 的**代码已落地并本地验证**（Dart 全量 `flutter analyze` 0 issue、`flutter test test/mining` 全绿、`flutter build windows` 成功含 voice_hook_reader/channel/processIsWow64/pid、`native/galgame_voice_hook` **x64 与 x86 Release** 三目标零 warning）。**真机门仍未过**（无可运行的 galgame + 无法在此环境注入/放声）——声明「能用」前必须按各节「验证门」在真机复测。C.2 已覆盖 **XAudio2 + DirectSound**（后者供 KiriKiri/吉里吉里等旧引擎）。

| 任务 | 状态 | 已验证（本地上界） | 仍需真机 |
|---|---|---|---|
| **A5** 波形选区 widget | ✅ 代码完成 | `galgame_waveform_select.dart`/`_dialog.dart` + 8 单测绿 | 目视：能画/能拖/返回值对 |
| **A6** 端到端一键 | ✅ 代码完成 | 接入 `texthooker_page.dart`；`slicePcmByMs` + 单测绿；`_captureGalAudioBytes` 串起 grab→选区→切片→编码→制卡 | galgame 热键→对话框→Anki 出卡（文本+可播音频+画面） |
| **A native 运行验证** | ⏳ 未验证 | loopback native 已编译 | 放声→`grabRecent` 返非零 PCM |
| **C.2** XAudio2 + DirectSound hook | ✅ 代码完成 | MinHook vendored；**XAudio2**（`XAudio2Create`/`CreateSourceVoice(vt5)`/`SubmitSourceBuffer(vt21)`）+ **DirectSound**（`DirectSoundCreate(8)`/`CreateSoundBuffer(vt3)`/`Unlock(vt19)`,跳主缓冲+格式一致性门控）零阻塞写环形；**x64 与 x86 Release 均链接过** | 真实 XAudio2/KiriKiri 游戏注入→环形填非静音语音、无爆音 |
| **C.4** EngineHookGalAudioSource+接回 | ✅ 代码完成 | `voice_hook_reader.{h,cpp}`+`app.hibiki.reader/voice_hook` channel（含 `processIsWow64` 目标位数查询，windows build 过）；`EngineHookGalAudioSource`+`targetIsWow64` + 单测绿；`ExternalWindowInfo.pid` 已通；A6 已「引擎-hook 优先(按目标位数选 x86/x64 注入器)，不可用回退 loopback」 | 切引擎-hook→出卡为干净语音；不可用无缝回退 |
| **C.3** 逐引擎覆盖 | ⛔ 未做 | — | 需各引擎真机标定 callsite/接口（C.2 当前捕获所有同格式 source voice/DS buffer，未按 callsite/音量精筛只留角色语音） |

**接缝提醒**：injector 可执行文件约定放在 app 同级 `voice_hook/<arch>/hibiki_voice_injector.exe`（`_resolveGalInjectorPath({is32Bit})`，按 `EngineHookGalAudioSource.targetIsWow64(pid)` 查目标进程位数选 x86/x64——**KiriKiri 多为 32 位必须 x86 注入器**），由 `native/galgame_voice_hook` 单独 cmake（`-A x64` / `-A Win32`）构建后随包分发/按需下载；缺失/位数不符时 A6 自动回退 loopback。C.2 的**校准模式 callsite/音量精筛**（只留角色语音、BGM/SE 不捕获）留 TODO（`dll_main.cpp` 内注释），需真机各引擎标定=C.3。

## ✅ 真机验证（2026-07-18，KiriKiriZ / `otomeki.exe` 32 位 DirectSound 游戏）

**捕获管线本身跑通了**（首个真实 galgame 验证）：
- 新增 injector **`--launch <exe>` CREATE_SUSPENDED 早注入模式**（`injector_main.cpp`）——KiriKiriZ 启动时创建一次 DirectSound 设备，post-hoc attach 会漏掉；早注入在游戏 WinMain 前把 hook 装好。新增 x64 诊断读取器 **`tools/ring_probe.cpp`**（`hibiki_voice_ring_probe <pid>`，读共享内存打印 hooked/格式/total_written/peak）。
- 实测：x86 injector `--launch otomeki.exe --hold` → `OK hooked hooked=1` → ring_probe 读到 **`sr=44100 ch=2 bits=16`、`total_written` 以 ~174KB/s（=44100×2×2，实时字节率）持续增长、`peak` 恒在数千（SOUND 非静音）**。证明：早注入命中、`DirectSoundCreate`→`CreateSoundBuffer`→`Unlock` hook 生效、干净 PCM 真的进了共享内存环形、外部进程可读。

**关键发现（诚实，影响 C-path 前提）**：捕获到的是**连续单流、恰好等于主输出字节率**——说明 **KiriKiriZ 是软件混音后走单个 DirectSound 输出 buffer**，故 DS-输出 hook 抓到的是**混音（标题界面=BGM）而非孤立干净语音**。即：**对 KiriKiriZ，引擎-hook 与 loopback 等效（都是混音），拿不到「干净语音」这个 C-path 卖点**。干净语音优势只对**每音/每 voice 独立 buffer** 的引擎成立（经典 KiriKiri 的 per-sound DS buffer、XAudio2 的 per-source-voice）。KiriKiriZ 要干净语音得 hook 其**引擎内部 per-channel 混音输入**（KiriKiriZ 专属，=C.3 深度活），或直接用 loopback（等效更省）。

**另一影响**：C.4 现设计是 Hibiki attach 用户已启动的游戏（post-hoc）——对 KiriKiriZ 这类**启动即建音频设备**的引擎会漏，必须 Hibiki 自己经 injector `--launch` 启动游戏才行（UX/设计取舍：Hibiki 拉起游戏 vs 附着到已开游戏）。

### launch 模式已接进 Hibiki（用户已确认「拉起游戏」这个取舍无所谓）

- **`EngineHookGalAudioSource` 加 launch 模式**：给 `launchExe`（而非 `targetPid`）即走 `injector --launch <exe> --hold`，从 injector stdout 的 `OK hooked pid=<N>` 解析游戏子进程 PID（纯函数 `parseInjectorHookedPid`），再 open 共享内存。`exeIs32Bit(path)` 读 PE COFF Machine 字段（0x014c=x86→true / 0x8664=x64→false）为**待启动的 exe**选 x86/x64 注入器（launch 时游戏还没进程，不能用 `processIsWow64`）。`gamePid` getter 暴露命中 PID。
- **texthooker UX**：AppBar 加「拉起 galgame（引擎-hook）」按钮（`_launchGalgameEngineHook`）——选 exe→按位数选注入器→拉起+早注入→就绪后以引擎-hook 为音频源，并按游戏 PID 从 `listWindows()`（已带 `pid`）找主窗口绑定（制卡截图）。失败明确 toast、不静默；起不来仍可用「绑窗+loopback」。
- 验证：analyze 0 issue、`galgame_audio` 37 测过（含 `parseInjectorHookedPid`/`exeIs32Bit` 单测）。**Dart 编排层编译+单测验证**；底层 `injector --launch`+DS 捕获已真机验证（上文），故整链 = 真机验证的注入/捕获 + 编译验证的 Dart 编排。**未做**的仍是干净语音（KiriKiriZ 软件混音，见上）+ 全程 UI 真机跑一遍出卡。

## 0. 当前状态（起点）

- **分支** `worktree-galgame-mining`（base `develop`），**PR #212（draft）**。仓库 `D:\APP\vs_claude_code\hibiki`（Melos workspace，Flutter app 在 `hibiki/`）。
- **工具链**：Flutter `3.44.0` / Dart `3.12.0`，路径 `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat`（不在 PATH）。CMake 4.x + VS2022（`flutter build windows` 与独立 cmake 均验证可用）。GitHub 走代理 `export HTTPS_PROXY=http://127.0.0.1:34151 HTTP_PROXY=http://127.0.0.1:34151`。
- **纪律（CLAUDE.md，强制）**：根因修复不打补丁；改前读最近的 `CLAUDE.md`；用独立 worktree；函数带类型注解；**声明「修好」前必须真机复测原始失败路径**；提交只 stage 本轮文件（禁 `git add -A`）；push 前跑全量 `flutter analyze`（CI 把 warning 当致命）+ `flutter test`。
- **已落地件（可直接依赖，均已单测/编译验证）**：
  - `hibiki/lib/src/mining/external_window_mining.dart` — `buildExternalWindowRequest({fields, sentence, screenshotBytes, audioBytes, audioName, ...})` 已透传音频。
  - `hibiki/lib/src/mining/galgame_audio_encode.dart` — `PcmFormat`、`buildWavBytes`、`pcmDurationMs`、`pcmSliceToAacBytes(...)`（PCM→WAV→AAC）。
  - `hibiki/lib/src/mining/galgame_audio_source.dart` — `GalAudioSource` 抽象、`GalAudioSlice`、`LoopbackGalAudioSource`（`app.hibiki.reader/audio_loopback` channel）。
  - `hibiki/lib/src/mining/galgame_waveform.dart` — `pcmToEnergyEnvelope(pcm, format)` → 逐窗 RMS dBFS。
  - `hibiki/windows/runner/audio_loopback_capture.{h,cpp}` — WASAPI loopback 环形缓冲 native（A 阶段音频源）。
  - `native/galgame_voice_hook/` — C.1 独立注入组件（injector + hook DLL + IPC 契约）。

## 1. 铁律（贯穿所有剩余任务）

1. **`providedAudioBytes` 引擎逐字节写盘不重编码**（`hibiki/lib/src/mining/immersion_mining_engine.dart:173`）→ 塞进制卡的音频**必须是已封装容器**（aac/m4a），裸 PCM 先过 `pcmSliceToAacBytes`。
2. **视频波形对话框 `SubtitleWaveformZoomView` 不可整体复用**——它是字幕对轴、产出 `delayMs`、无框选、音频硬绑 videoPath+ffmpeg。**只复用渲染层**：`SubtitleWaveformPainter` / `timeToX`（`hibiki/lib/src/media/video/subtitle_waveform_painter.dart`）+ `downsampleEnergyEnvelope`（`hibiki/lib/src/media/video/audio_energy_probe.dart:260`）。
3. **注入代码绝不进 `hibiki.exe` 本体**（报毒污染全 app）。`native/galgame_voice_hook/` 独立构建/分发；hibiki.exe 只**读**注入组件建好的共享内存（读共享内存不是注入、不被标记）。
4. **音频 hook 回调零阻塞**（C.2）：回调里只 memcpy + 更新 `write_pos`/`total_written`，写盘/编码/锁/IPC 全部移出——回调阻塞即爆音。
5. **中文源码 native**：CMake 必须 `/utf-8`（否则中文 locale 下 MSVC 按 GBK 误读致编译失败，见 `native/galgame_voice_hook/CMakeLists.txt`）。

---

## 2. A5 —— 波形选区 widget

**目标**：给一段 `GalAudioSlice`，弹对话框画波形、用户拖一个范围选区、返回 `(startMs, endMs)`；VAD 给默认框。

**文件**：新增 `hibiki/lib/src/mining/galgame_waveform_select_dialog.dart` + 纯逻辑 `galgame_waveform_select.dart`（几何/VAD 便于单测）。

**接缝**：
- 数据：`pcmToEnergyEnvelope(slice.pcm, slice.format)` → dB 帧 → `downsampleEnergyEnvelope(frames, targetBuckets)` → 0..1 桶（喂 painter）。
- 渲染：`SubtitleWaveformPainter`（cues 传 `const []` → 只画波形+中线；见 painter `cueBoundariesMs` 空分支）。
- 交互：叠一层 `GestureDetector`，`onPanStart/Update` 把像素 x 反算成 ms（`timeToX` 的逆：`ms = (x / width) * durationMs`，`durationMs = pcmDurationMs(slice.pcm.length, slice.format.byteRate)`），产出 `RangeSelection(startMs,endMs)`。
- **VAD 默认框**（纯函数）：在 dB 帧上取阈值（如 `峰值 - 20dB` 或绝对 `-40dBFS`），找**最后一段**连续高于阈值的区间作默认起止（galgame 一句语音通常是缓冲尾部最近一段）。用户可拖动微调。

**gotcha**：`downsampleEnergyEnvelope` 吃 dB 帧不是 PCM（故有 `pcmToEnergyEnvelope` 桥）；桶数少时退化为 min/max 归一化，正常。

**验证门**：
- 纯函数单测（`test/mining/`）：像素↔ms 映射、VAD 默认区间（造响/静窗 PCM 断言默认框落在响区）。
- 真机目视：对话框能画、能拖、返回值正确。

---

## 3. A6 —— 端到端一键（A 阶段可交付里程碑）

**目标**：galgame 里按热键 → 抓 loopback 切片 → 波形选区 → 抓当前帧 → 制卡出「句子+句子音频+画面」。

**接入点**：`hibiki/lib/src/pages/implementations/texthooker_page.dart` 的外部窗口挖矿流（`onMineEntry` ~L81-140，现已做 `{截图+文本}→mine`）。**文本（`fields['sentence']`）和画面（`WindowCaptureChannel.captureWindow(hwnd)`）已现成**，只补音频这条线。

**数据流**（全部现成件串起来）：
1. 会话开始时 `LoopbackGalAudioSource().start()`（拿 `PcmFormat`），关闭时 `stop()`。
2. 热键：`grabRecent(backMs)`（如 8000）→ `GalAudioSlice`。
3. A5 对话框 → `(startMs,endMs)`。
4. **切片**（新增纯函数 `slicePcmByMs(pcm, format, startMs, endMs)`，帧对齐，可单测）→ 子 PCM。
5. `pcmSliceToAacBytes(pcm: 子PCM, format, tempDir, outputExtension: immersionMiningAudioExtension())` → aac 字节。
6. `WindowCaptureChannel.captureWindow(gameHwnd)` → png（点词时游戏画面）。
7. `buildExternalWindowRequest(fields, sentence, screenshotBytes: png, audioBytes: aac)` → `ImmersionMiningEngine.mine(req, compression, tempDir, repo)`。

**gotcha**：loopback 抓的是**混音**（BGM+语音），A6 交付的是「能用」的混音卡；干净语音是 C。`requireAudio` 由 `buildExternalWindowRequest` 在有音频时自动开。

**验证门**：真机 galgame，热键→对话框→Anki 里出卡（正面文本 + 可播音频 + 画面），留截图 + 卡证据。

---

## 4. A native 运行验证（补 A4 的运行门）

`flutter build windows` 已编译过 `audio_loopback_capture.cpp`。**运行**未验证：跑 app → `start()` → 放一段系统声音 → `grabRecent(3000)` → 断言返回非全零 PCM、格式合理（48k/2ch 常见）。可加一个 debug 页/日志钩子取证。静音包按零写（`AUDCLNT_BUFFERFLAGS_SILENT` 已处理）。

---

## 5. C.2 —— XAudio2/DirectSound 语音捕获 hook（C 的核心，需真实 galgame）

**位置**：`native/galgame_voice_hook/hook/dll_main.cpp` 的 `HookWorker` 里「C.2 挂钩点」注释处。

**依赖**：引入 **MinHook**（MIT，与 GPLv3 兼容）做 inline/vtable hook。CMake `FetchContent` 或 vendor 进 `native/galgame_voice_hook/third_party/minhook/`。

**XAudio2 路径**（现代 VN 主流）：
- XAudio2 的语音接口是 COM vtable，`SubmitSourceBuffer` 不能 `GetProcAddress`。方案：hook `IXAudio2::CreateSourceVoice`（vtable 索引固定）→ 每次创建 source voice 时记下它的 `WAVEFORMATEX`（填 `SharedHeader` 格式）并 vtable-hook 该 voice 的 `SubmitSourceBuffer`。
- 拿到 `IXAudio2` 实例的途径：hook 导出的 `XAudio2Create`（`xaudio2_9.dll`/`xaudio2_8.dll`；旧版经 `CoCreateInstance`）→ 包裹返回的接口。
- `SubmitSourceBuffer` hook 内：读 `XAUDIO2_BUFFER`（`pAudioData`/`AudioBytes`/`PlayBegin`/`PlayLength`），把 `[PlayBegin,PlayLength)` 段 PCM **memcpy 进 `SharedHeader` 之后的环形缓冲**（`ring_capacity` 处起），单写者只推 `write_pos`（回绕）+ `total_written`（单调）——**只 memcpy，无锁无分配无 IO**，然后调原函数。首帧填 `sample_rate/channels/bits_per_sample/is_float/block_align`。
- 环形写逻辑照抄 A 阶段 `audio_loopback_capture.cpp` 的 `RingAppendLocked`（但这里单写者无需锁，volatile 即可）。

**DirectSound 路径**（旧引擎）：hook `IDirectSoundBuffer::Lock`/`Play`（或 `DirectSoundCreate`），同理在混音前取 buffer 段。

**校准模式**（`SharedHeader::calibrating`）：混音后分不清语音/BGM/SE，但引擎级能按**哪个 source voice/callsite** 分。首次识别产生角色语音的 callsite（抓一次调用栈 / 按格式启发式），让用户确认，存 `game.exe SHA + callsite RVA`；正常模式只捕获该 callsite，BGM/SE 连 memcpy 都不做。

**gotcha**：32 位游戏→x86 build（DLL 位数必须匹配）；部分引擎经 wrapper 用 XAudio2；anti-tamper 游戏可能拒注入；hook 装在工作线程（已避 loader lock）。

**验证门**：真实 XAudio2 galgame，注入 → 播一句语音 → 共享内存环形缓冲填入**非静音、与该语音吻合**的 PCM；主观听感无爆音/卡顿。无 galgame 不能声明 C.2 完成——别写没法验证的 hook 逻辑当完成。

---

## 6. C.4 —— `EngineHookGalAudioSource` + 接回 Hibiki

**目标**：Hibiki 用引擎 hook 的干净语音，复用 A 的同一波形选区 + 制卡出口。

**架构（隔离红线的落法）**：
1. Hibiki 主进程把 `hibiki_voice_injector.exe --pid <游戏PID> --hold` 当**子进程**拉起（注入这一步的报毒代码在隔离组件里）。
2. hibiki.exe **自己的** native（新增，如 `hibiki/windows/runner/voice_hook_reader.{h,cpp}` + channel `app.hibiki.reader/voice_hook`）**按名打开**共享内存（`SharedMemoryName(pid)`，见 `native/galgame_voice_hook/include/voice_hook_ipc.h`，可把该头共享/复制进 runner）→ `grabRecent(backMs)`：按 `write_pos`/`total_written`/`ring_capacity`/格式算最近 N 毫秒 PCM。**读共享内存不是注入、不被杀软标记**，可安全进 hibiki.exe。
3. Dart 新增 `EngineHookGalAudioSource implements GalAudioSource`（`galgame_audio_source.dart`），`grabRecent` 走上面的 voice_hook channel——**和 `LoopbackGalAudioSource` 同接口**，A5/A6 上层零改动。
4. 加「音频来源」开关：loopback(A) / 引擎 hook(C)，hook 不可用（未注入/无该引擎）自动回退 A。

**验证门**：真机 galgame，切到引擎 hook 源 → 出卡音频是**干净语音**（无 BGM）；hook 不可用时无缝回退 loopback。

---

## 7. C.3 —— 逐引擎覆盖

C.2 打通一个引擎后，按引擎补 callsite/接口差异（KiriKiri/吉里吉里、Artemis、Ren'Py、Unity、各自研）。每个引擎：识别方式 + voice callsite + 是否循环 buffer。未覆盖引擎自动回退 A。维护一张 `game.exe SHA/引擎 → callsite RVA` 表。

---

## 8. 建议顺序 & 依赖

```
A5 (波形 widget) ──► A6 (端到端一键，A 阶段可交付) ──► A native 运行验证
                                                        └► 先交付「能用的混音一键制卡」

C.2 (XAudio2 hook，需 galgame + MinHook) ──► C.4 (EngineHookGalAudioSource 接回) ──► C.3 (逐引擎)
     └► C.2 产出数据后 C.4 才有源可读
```

- **先把 A5→A6 做完**：这是用户能马上用上的「一键 + 波形选区 + 混音音频 + 画面」，价值最大、全可在本机+真机验证。
- **C.2 起需要一台装了目标 galgame 的 Windows**，且 hook 逻辑只能在真实游戏上验证——没有游戏别硬写。
- 每一步遵守：纯逻辑先抽出来单测；native 先 `cmake`/`flutter build windows` 编译；端到端必真机复测原始路径留证据。
