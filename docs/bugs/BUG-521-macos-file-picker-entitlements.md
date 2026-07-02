## BUG-521 · macOS 文件选择器不弹出
- **报告**：2026-07-01（用户：`文件选择器打不开`）
- **真实性**：✅ 真 bug。沿真实路径复现：备份导入、数据位置更改、词典导入点击后都没有弹出系统文件/目录选择器。根因是 macOS app sandbox 已启用，但 `hibiki/macos/Runner/DebugProfile.entitlements:9` 与 `hibiki/macos/Runner/Release.entitlements:7` 修复前缺少 `com.apple.security.files.user-selected.read-write`，FilePicker 的 save/open/directory panel 在沙盒下无法取得用户选择文件访问权限。
- **[x] ① 已修复** — 给 DebugProfile/Release 两份 entitlements 增加 `com.apple.security.files.user-selected.read-write`。提交：`a8957cc7ac02edcdaf4906e0bc2dd9995f751261`。
- **[x] ② 已加自动化测试** — `hibiki/test/platform/macos_file_picker_entitlements_test.dart` 锁定两份 macOS entitlements 必须保留用户选择文件读写权限；已通过 `flutter test test/platform/macos_file_picker_entitlements_test.dart test/sync/backup_export_file_picker_guard_test.dart --reporter expanded`。
- **备注**：已用 Computer Use 在修复前复现：词典导入、备份导入、数据位置更改均无系统 picker。修复后已执行 `flutter build macos --debug`，并确认打包后的 `hibiki.app` 实际 entitlements 含 `com.apple.security.files.user-selected.read-write`；随后用 Computer Use 复测导出备份 Save 面板、导入备份 Open 面板、数据位置目录 Open 面板、词典导入 Open 面板均能弹出。
