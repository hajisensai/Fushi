## BUG-549 · Xcode 27 真机编译失败：iOS deployment target 低于 15.0
- **报告**：2026-07-05（用户：wight）
- **真实性**：✅ 真 bug。Xcode 27 beta 真机编译日志拒绝 iOS deployment target 低于 15.0；修复前根因是 Runner 工程在 `hibiki/ios/Runner.xcodeproj/project.pbxproj:390` / `:476` / `:525` 使用 `13.0`，Podfile 在 `hibiki/ios/Podfile:2` 使用 `13.0`，HoshiDicts CMake 默认值在 `hibiki/ios/build_hoshidicts_ffi.sh:44` 使用 `13.0`。
- **[x] ① 已修复** — Runner / Podfile / HoshiDicts FFI 默认 deployment target 统一升到 iOS 15.0；Pod post_install 强制所有 Pod target 也使用 15.0，避免第三方 podspec 写入 9/10/12/13 后被 Xcode 27 拒绝。（提交：`cabb53121`）
- **[x] ② 已加自动化测试** — `hibiki/test/dictionary/hoshidicts_ios_packaging_guard_test.dart` 新增 Xcode 27 deployment target 静态守卫；验证：`flutter test test/dictionary/hoshidicts_ios_packaging_guard_test.dart`。
- **备注**：deployment target 已修；真机启动仍需本机签名可用的 Bundle ID / provisioning profile。不能把个人 Bundle ID 写入仓库。
