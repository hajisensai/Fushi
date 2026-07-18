# Galgame 一键制卡（句子 + 句子音频 + 画面）设计

> 状态：草稿 / 分阶段实现。A = loopback 混音一键；C = 引擎级干净语音。
> 两阶段共享同一条流水线（`GalAudioSource` 抽象 → 波形选区 → 制卡出口），C 只是往里插一个音频来源，不推翻 A。

## 目标

在 galgame（视觉小说）里按一次热键，就能把「当前这句台词 + 这句的语音音频 + 当前画面」做成一张 Anki 卡：
- **文本**：来自 texthooker（Hibiki 自带的外部窗口 texthooker 流；可选接 LunaHook 隔离子进程增强）。
- **音频**：A 阶段用 WASAPI loopback 抓系统混音切片；C 阶段用引擎级 voice hook 抓混音前的干净语音轨。
- **画面**：复用现有 `window_capture`（WGC 抓一帧 PNG）。
- **选取**：弹一个波形选区对话框（复用视频波形渲染层，新写框选手势），VAD 给默认框，用户微调起止。

## 现有可复用件（调查已核实，file:line 为主 checkout 值）

| 环节 | 现成件 | 位置 |
|---|---|---|
| 统一制卡入口 | `ImmersionMiningEngine.mine(req, ...)` | `hibiki/lib/src/mining/immersion_mining_engine.dart:83` |
| 制卡请求（已支持音频/封面字节） | `ImmersionMiningRequest.providedAudioBytes` / `providedCoverBytes` | `hibiki/lib/src/mining/immersion_mining_request.dart:80,109` |
| 外部窗口制卡请求构造 | `buildExternalWindowRequest`（M0 写死无音频） | `hibiki/lib/src/mining/external_window_mining.dart:19` |
| 画面抓帧 | `WindowCaptureChannel.captureWindow(hwnd)` → PNG | `hibiki/lib/src/mining/window_capture_channel.dart:47` |
| 字节→AAC 编码模板 | `transcodeClipToCapture` / `extractAudioSegmentViaFfmpeg` | `hibiki/lib/src/mining/immersion_capture_channel.dart:113` |
| 波形渲染纯函数 | `SubtitleWaveformPainter` / `timeToX` / `downsampleEnergyEnvelope` | `hibiki/lib/src/media/video/subtitle_waveform_painter.dart` / `audio_energy_probe.dart:260` |
| native 抓帧（WGC，可扩展） | `window_capture.cpp`（`CreateForWindow`；加 `CreateForMonitor` 即抓屏） | `hibiki/windows/runner/window_capture.cpp` |
| native channel 注册范式 | `RegisterWindowCaptureChannel`（worker 线程 + PostMessage 回 UI） | `hibiki/windows/runner/flutter_window.cpp:1254` |

## 关键约束（红线）

1. **`providedAudioBytes` 逐字节写盘不重编码**（`immersion_mining_engine.dart:173`）。loopback 抓到的裸 PCM 必须先编码成 AAC/m4a（先包 WAV → `extractAudioSegmentViaFfmpeg`），否则 Anki 播不了。
2. **音频回调零阻塞**（C 阶段）：hook 回调期间引擎暂停出声，几毫秒延迟即爆音。回调里只 memcpy + 无锁队列 push；写盘/编码/IPC 全部移出。队列满即丢本次采集、保游戏正常，绝不等待。
3. **32 位游戏内存预算**（C 阶段，注入 DLL 吃的是游戏地址空间）：DLL 自身 <16MB、共享池 ≤64MB、单句 ≤30s。
4. **注入代码绝不编进 `Hibiki.exe` 本体**（见「部署形态」）。

## 架构主干（A、C 共享）

```
 热键 ──┬─ 文本：texthooker 当前句（fields['sentence']）
        ├─ 画面：WindowCaptureChannel 抓当前帧 PNG
        └─ 音频：GalAudioSource.grabRecent(now, backMs) ──► PCM
                    ├─ A: LoopbackGalAudioSource（WASAPI loopback 环形缓冲切片，混音）
                    └─ C: EngineHookGalAudioSource（注入 DLL 回传干净语音轨）
                              │
                    波形选区对话框（复用渲染层 + 新框选手势 + VAD 默认框）
                              │ selectRange(startMs,endMs)
                    PCM 切片 → 包 WAV → extractAudioSegmentViaFfmpeg → AAC bytes
                              │
                    buildExternalWindowRequest(..., audioBytes) → ImmersionMiningEngine.mine
                              │
                    Anki 上传（现成，{sentence-audio}/{card-image} token 零改动）
```

### `GalAudioSource` 抽象

只暴露一个能力：给一个时刻，还我最近 N 秒的 PCM（+ 采样率/声道）。波形对话框、VAD、制卡出口只认它，不关心音频哪来的。
- A 实现 = loopback 环形缓冲（拿到混音）。
- C 实现 = 引擎 hook 语音 slab（拿到干净语音轨）。

## A 阶段任务（第一里程碑，能一键，靠 loopback 混音）

| # | 任务 | 层 | 可验证性 |
|---|---|---|---|
| A1 | `buildExternalWindowRequest` 增 `Uint8List? audioBytes` → `providedAudioBytes`；有音频时 `requireAudio` 开 | Dart 纯函数 | ✅ 单测 |
| A2 | PCM→WAV→AAC 编码 helper（`pcmSliceToAacBytes`） | Dart | ✅ WAV 头纯逻辑单测；ffmpeg 段真机 |
| A3 | `GalAudioSource` 抽象 + `AudioLoopbackChannel`（EventChannel，fail-open 同 WindowCaptureChannel） | Dart | ✅ analyze；流真机 |
| A4 | native `audio_loopback_capture.cpp`：`IAudioClient`+`AUDCLNT_STREAMFLAGS_LOOPBACK` → 环形缓冲；EventChannel 推 PCM/电平 | C++ | ⏳ 需 Windows 构建 + 真机 |
| A5 | 波形选区 widget（复用 painter + 新框选手势 + VAD 默认框） | Dart UI | ⏳ 真机目视 |
| A6 | 热键 → 切片 → 波形 → 抓帧 → 制卡 端到端接线 | Dart | ⏳ 真机 galgame |
| A.5 | 进程级 process-loopback（Win10 20H1+，异步激活，滤掉别的 app 声音） | C++ | ⏳ 增量 |

## C 阶段任务（第二里程碑，干净语音，逐引擎，独立可选组件）

组件在 `native/galgame_voice_hook/`（独立 CMake，**不被 hibiki/windows 引用**——部署红线，见下）。

| # | 任务 | 状态 |
|---|---|---|
| C.1 | 注入管线 + IPC 契约 proof-of-life：injector（`CreateRemoteThread`+`LoadLibraryW`）注入 hook DLL、建共享内存（`SharedHeader`+环形缓冲）+ 就绪事件、位数校验；DLL 注入后标记 `hooked=1`+`SetEvent` | ✅ x64/x86 编译过 + 对无害进程真实注入验证（`OK hooked pid=.. hooked=1`） |
| C.2 | `dll_main.cpp` 标注处安装 XAudio2/DirectSound vtable hook（MinHook 之类）：`CreateSourceVoice`/`SubmitSourceBuffer` 混音前 memcpy 语音进环形缓冲（回调只 memcpy+更新 write_pos，零阻塞爆音红线）；首帧填格式；校准模式记 `game.exe SHA + callsite RVA` | ⏳ 需真实 galgame |
| C.3 | 逐引擎覆盖（KiriKiri / Artemis / Unity …），其余自动回退 A | ⏳ |
| C.4 | `EngineHookGalAudioSource`（Dart 实现 `GalAudioSource`）：Hibiki 拉起 injector 子进程、读共享内存，接同一个波形选区 + 制卡出口 | ⏳ |

## 部署形态（许可 + 报毒隔离）

- Hibiki 与 LunaTranslator/LunaHook **同为 GPLv3**，复制/链接合法（保留 GPLv3 + 署名 + 源码可得）。
- **文本（LunaHook）**：作为**隔离子进程**跑、消费其输出，不把源码静态编进 `Hibiki.exe`。可选组件。
- **音频注入（C）**：injector + 音频 hook DLL 打包成**独立可选 helper 组件**，和主程序**分离分发**（按需下载）。
  - 理由：`CreateRemoteThread`/`WriteProcessMemory`/DLL 注入是杀软启发式的「代码注入」特征，**必然报毒**。编进本体会污染整个 app 的分发口碑；隔离成独立组件把污染面锁死在该组件。
  - 缓解：代码签名改善声誉分（挡不住启发式）；引导用户加杀软白名单（galgame texthook 用户对此有预期）。
- **进程边界消费**：被标记的代码只待在隔离二进制里，主程序通过共享内存/管道拿结果。

## 验证门（CLAUDE.md 纪律）

- Dart 纯函数（A1/A2 头/A3 抽象）：`flutter test` 覆盖。
- native（A4/A.5）：`flutter build windows` 编译 + 真机跑一个出声程序验证环形缓冲。
- C.1 注入管线：`cmake` x64/x86 编译 + 对无害进程真实注入（读回 `hooked=1`）——无需 galgame。
- 端到端（A5/A6/C.2+）：真实 galgame 上按热键 → 波形选区 → 出卡，留证据（截图 + Anki 卡）。声明「能用」前必须真机复测。
