## BUG-2850 · CI 构建期实时从 GitHub 下载 PDFium（pdfium_dart 构建钩子），下载一抖 develop 的 Windows / macOS / Android 发布同时红
- **报告**：2026-10-01（用户：「现在 action 不少流水线跑红了，看看什么情况修复一下」）
- **真实性**：✅ 真问题（CI 构建不封闭）。develop `82c5db4ad` 的三条发布构建在 13:08–13:12 UTC 同时失败：
  桌面 run 36865627262 的 Windows / macOS（`Target dart_build failed … Building native assets failed`）与
  Android run 36865627415（`Build release-signed debug-channel APK`），错误都是
  `Exception: Failed to download PDFium: https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F7811/pdfium-<平台>-<架构>.tgz`。
  上一个提交 `8b05b2ebf` 的同两条流水线全绿，两者之间没有任何依赖 / workflow 改动（6 个提交只动 Dart 源码与测试），
  事后该地址也能正常下载（200）——是 GitHub release 资源的瞬时故障，但**让它能打红构建的是我们这边**：
  pdfrx → pdfrx_engine → pdfium_dart 0.2.5 的 `hook/build.dart:46-54`（pub cache 内）在每次
  `flutter test` / `flutter build`（Android / Windows / macOS / Linux，iOS 跳过）时把 PDFium 下进
  `.dart_tool/hooks_runner/shared/pdfium_dart/build/chromium_7811/<平台>-<架构>/`，非 200 即抛；
  CI 每个 job 都是全新 runner，没有任何缓存，于是每个跑 app 测试 / 构建的 job 都实时依赖 GitHub 下载
  （本机实测：只跑过 `flutter test` 的 worktree 里也有这份下载产物，单测分片同样暴露）。
- **[x] ① 已修复** —— 新增复合 action `.github/actions/pdfium-hook-cache`：缓存上述共享输出目录
  （钩子在目标文件已存在时直接跳过下载，`if (await output.exists()) return;`），key =
  用途（test / android / windows / macos，避免同 OS 不同目标的 job 互相占位）+ runner OS / 架构 +
  pubspec.lock 里的 pdfium_dart 版本（下载的 release 按它钉死）。挂到 6 个 workflow 里全部 11 个跑 app
  Flutter 测试 / 非 iOS 构建的 job，排在 checkout 之后、第一条测试 / 构建命令之前。只在缓存未命中时下载一次。
- **[x] ② 已加自动化测试** —— `fushi/test/build/pdfium_hook_cache_guard_test.dart`：钉 action 的缓存路径与 key 组成；
  扫全部 workflow，凡是跑 `flutter test` / `flutter drive` / `flutter build apk|appbundle|windows|macos|linux`
  （允许 `flutter --verbose build` 这类全局选项）/ `flutter_test_failures.dart` / `comprehensive_test_runner.dart`
  的 job，必须先 checkout、再挂这个缓存、purpose 合法。变异验证过：删掉 release.yml 打 APK job 的缓存步骤即红。
- **备注**：
  - 同时段另一条红是 iOS `Upload to TestFlight`（403 `FORBIDDEN_ERROR.CONTRACT_NOT_VALID` /
    `Cannot determine the Apple ID from Bundle ID`），是 Apple 账号协议失效，与本条无关、仓库侧无可修，需账号持有人处理。
  - 清理条件：pdfrx / pdfium_dart 移除，或 pdfium_dart 改为随包分发二进制时删 action 与守卫。
