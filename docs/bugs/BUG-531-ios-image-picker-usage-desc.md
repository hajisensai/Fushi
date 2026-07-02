## BUG-531 · iOS 制卡取图缺 Info.plist 权限键硬崩
- **报告**：2026-07-02（用户：iOS 验证诊断）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/creator/enhancements/camera_enhancement.dart:46` 用 `ImageSource.camera`、`hibiki/lib/src/creator/enhancements/pick_image_enhancement.dart:43`（及 `miscellaneous_settings_page.dart:190`、`media_item_edit_dialog_page.dart:119`）用 `ImageSource.gallery`，但 `hibiki/ios/Runner/Info.plist` 缺 `NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription`（原仅有 Microphone / LocalNetwork / Bonjour）。iOS 平台硬性要求这两个 usage description key，缺失时首次访问相机/相册即 `SIGABRT` 硬崩（App Store 也拒审）。
- **[x] ① 已修复** — 在 `hibiki/ios/Runner/Info.plist` 补 `NSCameraUsageDescription`（“用于拍摄图片添加到生词卡片”）与 `NSPhotoLibraryUsageDescription`（“用于从相册选择图片添加到生词卡片”）；提交见分支 `fix-1020-ios-gaps`。
- **[x] ② 已加自动化测试** — 源码扫描守卫 `hibiki/test/ios/info_plist_media_permission_guard_test.dart`：扫描 `lib/` 若存在 `ImageSource.camera` 用点则断言 Info.plist 含 `NSCameraUsageDescription`；若存在 `ImageSource.gallery` 用点则断言含 `NSPhotoLibraryUsageDescription`。防未来新增取图入口时权限键漏配复发。
- **备注**：真机 iOS 崩溃复现验证（相机/相册取图不崩）需物理/模拟器 iOS，归 Mac 队列；本机 Windows 只做源码级正确 + 守卫绿。
