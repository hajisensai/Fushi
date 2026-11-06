# 模块索引

从根 `CLAUDE.md` 迁出（2026-10-24）。

| 模块 | 语言 | 职责 / 接入方式 | 文档 |
|---|---|---|---|
| `fushi/` | Dart | Flutter 主应用：UI/阅读器/视频/导入/设置 | [fushi-app-module.md](fushi-app-module.md)（硬规则在 [fushi/CLAUDE.md](../../fushi/CLAUDE.md)） |
| `packages/fushi_core/` | Dart | DB schema（118 表）/偏好/语言配置 | [CLAUDE.md](../../packages/fushi_core/CLAUDE.md) |
| `packages/fushi_dictionary/` | Dart | 词典引擎 Dart 侧/FFI 绑定/多格式导入（C++ 在 `native/fushidicts/`） | [CLAUDE.md](../../packages/fushi_dictionary/CLAUDE.md) |
| `packages/fushi_anki/` | Dart | Anki 集成（AnkiDroid + AnkiConnect） | [CLAUDE.md](../../packages/fushi_anki/CLAUDE.md) |
| `packages/fushi_audio/` | Dart | 字幕解析/有声书播放/音频匹配 | [CLAUDE.md](../../packages/fushi_audio/CLAUDE.md) |
| `packages/fushi_platform/` | Dart | TTS/平台集成/存储路径抽象 | [CLAUDE.md](../../packages/fushi_platform/CLAUDE.md) |
| `packages/flutter_inappwebview_windows/` | Dart+C++ | inappwebview Windows fork | [CLAUDE.md](../../packages/flutter_inappwebview_windows/CLAUDE.md) |
| `packages/flutter_inappwebview_linux/` | Dart+C++ | inappwebview Linux（WPE WebKit）vendored，Dart 层降到 platform_interface 1.3.0，薄注册层 + dlopen 实现库 | [UPSTREAM.md](../../packages/flutter_inappwebview_linux/UPSTREAM.md) |
| `packages/fushi_torrent/` | Dart | 内置 torrent 引擎 FFI 绑定 + `EmbeddedTorrentEngine`（path 依赖） | — |
| `packages/fushi_p2p/` | Dart | 互联 P2P 隧道（iroh，dumbpipe 形态）纯 Dart FFI；引擎侧运行时 `fushi_engine/lib/sync/interconnect_p2p.dart`，原生库缺失时能力判不可用 | 设计 `docs/specs/2026-09-28-interconnect-remote-reach.md` |
| `native/fushi_p2p/` | Rust | iroh 1.x TCP-over-P2P 转发 C ABI；`build_windows_dll.ps1` / `build_android_so.*` / `build_linux_so.sh` 产出到 `prebuilt/`（不入库），Windows CMake / Android jniLibs 有则随包 | [README.md](../../native/fushi_p2p/README.md) |
| `packages/fushi_engine/` | Dart | 无 Flutter 的共享引擎：互联 host / 库服务 / OCR / ASR 任务 / 下载管线 / EPUB 导入 / 视频元数据（app 与服务端共用；纯度守卫在 fushi/test/build） | 设计 `docs/specs/2026-09-08-fushi-server-headless-design.md` |
| `packages/fushi_cli/` | Dart | 桌面客户端命令行 `fushi_cli`：经本机控制通道（127.0.0.1 + token，发现文件 `endpoint.json`）驱动正在运行的 app，app 没开时自动拉起；app 侧接线 `fushi/lib/src/platform/desktop/desktop_ctl_host.dart`；Windows 发布随包放 `fushi.exe` 同级 | [README.md](../../packages/fushi_cli/README.md) |
| `packages/fushi_server/` | Dart | 无头服务端 CLI + WebUI（Linux/Windows/macOS）；`dart build cli` 出 bundle，CI `build-multiplatform.yml` 的 `linux-server` job 随包 torrent bridge `.so` + onnxruntime（Linux app 已不在 CI 构建） | [README.md](../../packages/fushi_server/README.md) |
| `packages/gamepads_windows/` | Dart+C++ | gamepads Windows vendored fork（BUG-116 崩溃修复，path override） | — |
| `packages/gamepads_android_stub/` | Dart | `gamepads_android` no-op stub（防启动 ClassCastException，path override） | — |
| `native/fushidicts/` | C++ | 词典查询/导入引擎（上游深度 fork；`fushidicts_external/` 为 vendored 第三方）；FFI/JNI 编入 app | [UPSTREAM.md](../../native/fushidicts/UPSTREAM.md) |
| `native/fushi_torrent/` | C++ | libtorrent 2.x C ABI bridge；FFI，Windows 预编译 DLL / macOS arm64 dylib / Android arm64 `.so` 随包 | [README.md](../../native/fushi_torrent/README.md) |
| `services/log-backend/log-collector/` | Go | 报错日志接收端（自有服务器 + EdgeOne 版）；独立部署（原 `server/`，改名消与同步层 `fushi_sync_server.dart`/`SyncBackendType.hibikiServer` 的三义撞词） | [README.md](../../services/log-backend/log-collector/README.md) |
| `services/log-backend/cf-worker/` | JS | 报错日志接收端（Cloudflare Worker + D1 版，与 Go 版择一）；独立部署 | [README.md](../../services/log-backend/cf-worker/README.md) |
| `tools/browser-extension/` | JS | 浏览器查词扩展（根级 `tools/`，非 `tool/`） | — |
| `third_party/` | — | 12 个 path-override vendored 补丁包：carousel_slider、desktop_drop、fading_edge_scrollview、ffmpeg_kit_next_flutter（+ platform interface；移动端进程内跑**统一 FFmpeg**，见下行）、flutter_inappwebview_android、media_kit_libs_{android,ios,macos,windows}_video、media_kit_video、network_to_file_image；vendor 原因见 `fushi/pubspec.yaml` dependency_overrides 逐包注释。另有 `m_extension_server/`（**不是** pub 包）：Mihon 桌面 sidecar 的 Kotlin 源码，上游 GitHub 仓库已删除，按 MPL-2.0 整树 vendored 在 `upstream_src/`（pristine）+ `overlay/`（Hibiki 安全边界）+ `server-build.gradle.patch`，构建走 `tool/mihon/build_desktop_runtime.{sh,ps1}`，规则见该目录 `UPSTREAM` | — |
| `tool/ffmpeg-unified/` | sh/py | **统一 FFmpeg 真相源（2026-10-17）**：全平台一份 FFmpeg（版本 `recipe.env` + 补丁 `patches/` + 能力下限 `capabilities.json`），播放器 libmpv 与制卡/导出/ASR/转码在每个平台链接**同一份**产物：Windows 进 libmpv 运行时归档（`ffmpeg.exe`/`ffprobe.exe` 与 libmpv 共用 `fbd*.dll`）、Android/iOS 是 FFmpegKitNext AAR/xcframework（libmpv 动态链接其中的 libav*）、macOS 是 `media_kit_libs_macos_video/native/ffmpeg-unified-macos.tar.gz`（framework + 程序）。升级流程与补丁说明见 `docs/specs/2026-10-17-unified-ffmpeg.md`；**不要再引入第二份 FFmpeg**（守卫 `ffmpeg_unified_*`） | [spec](../../docs/specs/2026-10-17-unified-ffmpeg.md) |
| `references/ReinaManager` | — | git submodule：galgame 库信息架构参考（AGPL-3.0，不参与构建） | — |
| `references/ShokoServer` | C# | git submodule：动画识别/刮削长期参考；AniDB 核心身份 + TMDB 补充（MIT，不参与构建） | [上游 README](../../references/ShokoServer/README.md) |
| `references/mangayomi` | Dart | git submodule：Aniyomi / Mihon 扩展桌面 + Android 适配参考（Apache-2.0，不参与构建） | [上游 README](../../references/mangayomi/README.md) |

> 完整架构、技术栈、构建命令、致谢见 [README.md](../../README.md)。`file_picker` 用 pub.dev 版（**不是** fork）。依赖补丁机制（vendored vs apply-patches）见 [docs/agent/build.md](build.md)。
