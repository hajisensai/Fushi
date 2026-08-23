## BUG-1806 · 实机截图helper在iOS写相对codex-test目录失败
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机视频来源流程在扫描/归组后抓图）
- **真实性**：✅ 真 bug（测试证据层）。`fushi/integration_test/helpers/observe_capture.dart:29-49` 在没有 `FUSHI_TEST_ROOT` 时固定创建相对 `.codex-test/observe/...`；iOS App 进程当前目录不可写，真实扫描完成后 `captureFlutterFrame` 抛 `PathAccessException: Creation failed, path='.codex-test' (errno=1)`。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — RED：物理机 `video_source_import_flow_itest.dart` 在第一张扫描后截图失败、exit 1；快速守卫 `fushi/test/integration/observe_capture_mobile_path_test.dart` 把平台覆写为 iOS，要求裸跑 fallback 位于 `Directory.systemTemp`。
- **备注**：runner 显式传 `FUSHI_TEST_ROOT` 时路径契约不变；只把没有 runner 根目录的 iOS/Android fallback 移到 App 沙盒可写的 system temp，桌面裸跑仍保留仓库 `.codex-test` 证据路径。
