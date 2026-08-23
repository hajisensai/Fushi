## BUG-1806 · 实机截图helper在iOS写相对codex-test目录失败
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机视频来源流程在扫描/归组后抓图）
- **真实性**：✅ 真 bug（测试证据层）。`fushi/integration_test/helpers/observe_capture.dart:29-49` 在没有 `FUSHI_TEST_ROOT` 时固定创建相对 `.codex-test/observe/...`；iOS App 进程当前目录不可写，真实扫描完成后 `captureFlutterFrame` 抛 `PathAccessException: Creation failed, path='.codex-test' (errno=1)`。
- **[x] ① 已修复** — 移动端裸跑 fallback 改用 system temp；提交 `bb1f2ddf7`。
- **[x] ② 已加自动化测试** — `observe_capture_mobile_path_test.dart` 与 iPhone 三张视频来源截图 GREEN；RED 曾报 PathAccessException、exit 1。
- **备注**：runner 显式传 `FUSHI_TEST_ROOT` 时路径契约不变；只把没有 runner 根目录的 iOS/Android fallback 移到 App 沙盒可写的 system temp，桌面裸跑仍保留仓库 `.codex-test` 证据路径。
