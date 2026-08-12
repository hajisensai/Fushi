## BUG-1583 · manga OCR 编排测试硬读 Platform，macOS/iOS 宿主上结构性必红
- **报告**：2026-08-12（在 macOS 上跑全量门时暴露：`test/ocr/manga_ocr_service_impl_test.dart` 9 条红，其余 42 条见 [BUG-1585](BUG-1585-golden-cross-platform-raster-false-red.md)）
- **真实性**：✅ 真 bug（测试可移植性，非产品缺陷）。`MangaOcrServiceImpl` 对 modelsDir / manifest / jobRunner / downloader **四个依赖都留了构造注入口**，唯独平台闸门 `isSupportedPlatform` 直接读 `dart:io` 的 `Platform`：
  - `lib/src/ocr/ocr_inference_ort.dart:32` — `isLocalOnnxRuntimeAvailable => !(Platform.isMacOS || Platform.isIOS)`
  - `lib/src/ocr/manga_ocr_service_impl.dart:427`（修复前）— `isSupportedPlatform => (Platform.isWindows || Platform.isLinux) && isLocalOnnxRuntimeAvailable`

  于是 `ocrFolder` 一进 `onListen` 就在 `manga_ocr_service_impl.dart:508` 抛 `StateError('manga OCR is not supported on macos')`，`group('ocrFolder 编排')` 里**每一条**编排断言（逐页事件转发 / 取消订阅 / 加速状态回传 / 降级原因）全部级联失败——失败的是宿主平台，不是被测的编排逻辑，而这些编排逻辑本身与平台无关。
  - 在 CI（ubuntu）上 `isSupportedPlatform` 为真，所以这 9 条一直是绿的，问题只在 macOS / iOS 开发机上显形；这也是它能一直活着的原因。
  - 注意：**整卷本地 OCR 在 iOS/macOS 上不支持是产品的有意设计**（重活只给桌面，Apple 侧退回 Google Lens / 外部 mokuro / 配对主机三种引擎），这条 bug 修的不是那个设计，而是「测试无法在该设计下的宿主上运行」。
- **[x] ① 已修复** — `MangaOcrServiceImpl` 补上与其它四个依赖同形的注入口 `platformSupport`，真实实现抽成 `static bool defaultPlatformSupport()` 作默认值；`isSupportedPlatform` 改为 `=> _platformSupport()`。测试侧 `service()` 辅助函数默认注入 `() => true`，让编排断言在任何宿主上都走同一条分支。（提交：本提交）
- **[x] ② 已加自动化测试** — 同文件 `test/ocr/manga_ocr_service_impl_test.dart` 新增 2 条，补回原先只在 macOS 上"意外"覆盖到的分支：
  1. `平台不支持：error 结束流，任务不启动，且不去碰模型目录` — 显式注入 `platformSupported: false`，断言抛 `StateError` 且 `runner.requests` 为空（模型写齐，排除「未就绪」路径干扰，确保验的确实是平台闸门）；
  2. `默认构造走真实平台闸门（不被注入桩悄悄替换）` — 断言不传 `platformSupport` 时 `isSupportedPlatform == defaultPlatformSupport()`，防止注入口把生产默认值也一起改掉。
- **备注**：修复后 `flutter test test/ocr/` 在 macOS 上 **105 项全绿**（修复前 96 绿 9 红）。
