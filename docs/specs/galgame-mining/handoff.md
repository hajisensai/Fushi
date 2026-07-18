# galgame 一键制卡 —— 后续实现交接（handoff）

> 面向接手的另一个 AI/开发者，**自包含**。总设计见 [design.md](design.md)。
> 已完成 A 阶段 Dart 基座 + native loopback + 波形桥 + C.1 注入组件（PR #212）。本文档给出**剩余任务**的落地路径：文件、接缝、gotcha、验证门。

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
