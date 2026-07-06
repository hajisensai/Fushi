## BUG-567 · iOS 27 真机启动在 Flutter VSyncClient 崩溃
- **报告**：2026-07-06（用户：）
- **真实性**：✅ 真 bug。iOS 27 beta 2 / iPhone 17 真机上，Debug 包直接启动或 Flutter tool 启动会在 `FlutterViewController.viewDidLoad` 进入 `createTouchRateCorrectionVSyncClientIfNeeded` 后崩溃/黑屏；系统崩溃日志 `Runner-2026-07-06-225253.ips` 显示 `EXC_BAD_ACCESS`，触发帧为 `-[VSyncClient initWithTaskRunner:callback:]`。根因是 `ios/Runner/Info.plist:62` 启用了 `CADisableMinimumFrameDurationOnPhone`，在 iOS 27 beta 的 Flutter engine 触摸校正 VSync 路径上触发空指针崩溃。
- **[x] ① 已修复** — `ios/Runner/Info.plist` 将 `CADisableMinimumFrameDurationOnPhone` 显式设为 `false`，避开 iOS 27 beta 的 Flutter VSyncClient 崩溃路径。（本提交）
- **[x] ② 已加自动化测试** — `hibiki/test/ios/uiscene_startup_guard_test.dart` 增加静态守卫，要求该 key 保持存在且为 `<false/>`。
- **备注**：
  - 复测证据：改为 `false` 后，`flutter run -d 00008150-0002021A1478401C --debug --no-pub` 真机启动到书架；截图保存于 `hibiki/.codex-test/ios-device-logs/after-vsync-off-screen.png`。
  - Flutter VM Service 仍因无线调试/本地网络发现未连上，需 USB 或 iOS 本地网络权限进一步处理；但 UI 已从启动黑屏恢复。
