## BUG-573 · iOS Profile/Release 未启用高刷新率
- **报告**：2026-07-07（用户：）
- **真实性**：✅ 真 bug。`hibiki/ios/Runner/Info.plist:62` 把
  `CADisableMinimumFrameDurationOnPhone` 写死为 `<false/>`，所有 iOS 构建配置
  都禁用了 iPhone 高刷新率/ProMotion opt-in；这虽然规避了 BUG-567 的 iOS 27
  Debug VSync 崩溃，但 Profile/Release 真机包也被一起锁成非高刷。
- **[x] ① 已修复** — 源 Info.plist 保持 `<false/>` 作为 Debug 安全回退（也防止
  `flutter build` 自动把缺失 key 升回 `true`），并在 Runner 的 `Thin Binary`
  build phase 中对最终 app Info.plist 按配置写值：Debug 写 `false`，Profile/Release
  写 `true`。Debug 仍避开 iOS 27 beta VSyncClient 崩溃，实机测试包和发布包恢复高刷新率 opt-in。
- **[x] ② 已加自动化测试** — `hibiki/test/ios/uiscene_startup_guard_test.dart`
  守卫源 Info.plist fallback 必须为 `<false/>`，并断言 `Thin Binary` 脚本必须在
  `embed_and_thin` 前用 PlistBuddy 写入 Debug=`false`、Profile/Release=`true`。
- **备注**：RED 已确认旧代码 Info.plist 写死 `<false/>`；修复后 Xcode
  Profile 最终 app plist 的 `CADisableMinimumFrameDurationOnPhone` 为 `true`。
