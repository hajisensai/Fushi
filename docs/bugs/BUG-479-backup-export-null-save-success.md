## BUG-479 · 备份导出未选择位置也提示成功
- **报告**：2026-07-01（用户：`导出备份没有选择位置直接导出了`）
- **真实性**：✅ 真 bug。沿真实路径复现：设置 → 同步与备份 → 导出备份 → 确认分类后未出现保存位置选择器，却显示“备份导出成功”。根因在 `hibiki/lib/src/sync/sync_settings_schema/backup.part.dart:66`：桌面分支 `FilePicker.platform.saveFile` 返回 `null` 时只跳过 copy，但继续执行 `backup_export_success` 成功提示（修复前约 `backup.part.dart:77`）。
- **[x] ① 已修复** — 桌面导出分支在 `savePath == null` 时直接返回，并用 `finally` 清理临时 zip，避免取消/面板失败后显示成功。提交：`a8957cc7ac02edcdaf4906e0bc2dd9995f751261`。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/backup_export_file_picker_guard_test.dart` 锁定 `savePath == null` 必须提前返回，防止成功 toast 越过取消路径；已通过 `flutter test test/platform/macos_file_picker_entitlements_test.dart test/sync/backup_export_file_picker_guard_test.dart --reporter expanded`。
- **备注**：修复前已用 Computer Use 复现“未选择保存位置仍提示成功”。修复后已重新构建 macOS app，导出备份确认分类后会弹 Save 面板；在 Save 面板点 Cancel 后回到设置页，未再出现“备份导出成功”。
