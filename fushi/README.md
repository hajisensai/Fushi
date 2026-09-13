# fushi（Flutter 主应用）

Fushi 的 Flutter 多平台主应用：EPUB 阅读器 + 划词查词 + 有声书同步 + 视频/漫画/galgame 沉浸学习 + Anki 制卡 + 阅读统计。

视频制卡可选择带声音的 MP4，以同一文件同步播放例句与画面。配置、模板更新和三端验证边界见 [Anki 例句音画同步](../docs/specs/2026-09-13-anki-synchronized-video.md)。
Android / iOS / macOS / Windows / Linux 五端出包。项目介绍、下载、构建命令、致谢见仓库根 [README.md](../README.md)；
进入本目录改代码前先读 [CLAUDE.md](CLAUDE.md)（模块规则）与根 [CLAUDE.md](../CLAUDE.md)（全仓规则）。

设置采用分组导航：常用项直接展示、进阶项按组展开、复杂配置进入子页；支持搜索定位到具体表单行，展开偏好仅保存在本机。分类、兼容与验证约定见[设置结构设计](../docs/specs/2026-09-10-settings-organization.md)。

## 引用的自有包

本应用不是单体：算法、数据层、平台桥都拆在自有包里，`pubspec.yaml` 只做装配。分两类：

### 同仓 workspace 包（`../packages/`，`path:` 引用）

| 包 | 职责 |
|---|---|
| [`fushi_core`](../packages/fushi_core/) | Drift 数据库 schema、偏好、语言配置、共享模型 |
| [`fushi_dictionary`](../packages/fushi_dictionary/) | 词典引擎 Dart 侧、FFI 绑定、多格式导入（C++ 引擎在 `../native/fushidicts/`） |
| [`fushi_anki`](../packages/fushi_anki/) | Anki 集成：抽象服务 + AnkiDroid / AnkiConnect 两种实现 |
| [`fushi_audio`](../packages/fushi_audio/) | 音频播放/录音、有声书匹配、字幕解析 |
| [`fushi_platform`](../packages/fushi_platform/) | TTS、平台集成、存储路径抽象 |
| [`fushi_torrent`](../packages/fushi_torrent/) | libtorrent 2.x C ABI FFI 绑定 + 内置 torrent 引擎（native 在 `../native/fushi_torrent/`） |

这些包随 Melos workspace 一起解析（根 `pubspec.yaml` 的 `workspace:` 列表），改动直接在本仓提交，不需要钉版本。

### 独立仓库的自有包（`git:` 引用，钉 sha）

| 包 | 来源 | 职责 |
|---|---|---|
| `fushi_asr_core` | [`hajisensai/fushi-subtitles`](https://github.com/hajisensai/fushi-subtitles) `packages/asr_core`（GPL-3.0，纯 Dart，零 Flutter） | 设备端语音识别：VAD、fbank、zipformer RNN-T / CTC 解码、分批、字幕输出，以及共享 ONNX 推理抽象 |

`fushi-subtitles` 仓库里还有 `fushi_asr_align`（EPUB/文本与音频对齐）、`fushi_asr_onnx_ffi`、`fushi_asr_cli`、`fushi_asr_server`，本应用目前只引用 `fushi_asr_core`。

本应用与该包的分工（详见根 `CLAUDE.md`「有声书」条目）：

- **算法一律去 `fushi-subtitles` 改**，本仓只留三样：Flutter 插件后端 `lib/src/onnx/onnx_inference_ort.dart`（method channel → `flutter_onnxruntime`）、装配层 `lib/src/asr_host/asr_host.dart`、UI（`lib/src/media/audiobook/asr_transcribe_sheet.dart` 等）。
- 漫画 OCR（`lib/src/ocr/ocr_inference.dart`）复用同一套 ONNX 抽象，所以这个包不只服务 ASR。
- 装配点在 `asr_host.dart`：数据根、出站 HTTP（必须经 `createAppHttpClient` 走全应用代理）、日志、ffmpeg 后端、后台 isolate 引导。`installAsrHostBindings()` 在 `main()` 里调一次。

## 升级 `fushi_asr_core` 钉住的 sha

钉 sha 而不是分支：转录产物要能字节级复现，跟着分支飘会让「同一版 Fushi 转出来的字幕不一样」无从追查。升级步骤：

1. 在上游拿目标提交：`git ls-remote https://github.com/hajisensai/fushi-subtitles.git main`。
2. 先看两个 sha 之间 `packages/asr_core/lib` 的 diff，找公共 API 变化（枚举加值、接口方法加参数、包名/入口文件改名），再对照本仓消费方（`grep -rn "package:fushi_asr_core/" lib test tool integration_test`）。
3. 改 `pubspec.yaml` 的 `ref:`；若包名变了，依赖名和所有 `import 'package:…'` 一起改。
   注意 `test/onnx/onnxruntime_device_memory_guard_test.dart` 按包名在 `package_config.json` 里找源码，包名变了它会直接抛 `StateError`。
4. 仓库根跑 `powershell -ExecutionPolicy Bypass -File tool/bootstrap.ps1`（pub get + 补丁），确认 `pubspec.lock` 只动了这个包的条目。
5. `flutter analyze`，再定向跑 `flutter test --no-pub test/asr test/onnx test/media/audiobook/asr_*`。

## 第三方 vendored 包

`../third_party/` 下 11 个 `dependency_overrides` 补丁包（media_kit 系列、flutter_inappwebview_android、desktop_drop 等）**不是自有包**，是上游 pub 包打了本仓补丁的副本；vendor 原因见 `pubspec.yaml` 里逐包注释，补丁机制见 [docs/agent/build.md](../docs/agent/build.md)。
