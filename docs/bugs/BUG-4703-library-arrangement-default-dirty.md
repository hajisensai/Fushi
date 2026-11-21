## BUG-4703 · 外观页「色块摆放」恢复默认对照旧默认：全新安装（封面网格）就标已改过，恢复默认反把网格下色块分区写成散落
- **报告**：2026-11-16（PR #3454 合并后审查发现）
- **真实性**：✅ 真 bug。没选过时生效的摆放跟着库页布局走（`fushi/lib/src/models/theme_notifier.dart` 的 `shellBlockArrangement` = 偏好 ?? `ShellBlockArrangement.defaultFor(shellContentLayout)`），而设置项的「出厂默认」写死成拼贴下的散落（`fushi/lib/src/settings/settings_schema_appearance.dart:402` `defaultValue: ShellBlockArrangement.defaultFor(ShellContentLayout.collage)`）。PR #3454 把默认布局改成封面网格后，全新安装生效值 = 规整 ≠ 散落 → 外观页标「已改过」；点恢复默认把偏好钉成散落，网格下页面里固定排成色块的分区随之变成散落。
- **[x] ① 已修复** — `SettingsSegmentedItem` 加 `defaultValueBuilder`（渲染时求值的默认）与 `resetToDefault`（自定义恢复写法），`settingsResetSpecFor` 读 `defaultValueFor(context)`；色块摆放的默认改成 `defaultFor(当前布局)`，恢复默认调新加的 `resetShellBlockArrangement()` 清掉偏好、回到跟着布局走，不把此刻的默认钉死。
- **[x] ② 已加自动化测试** — `fushi/test/settings/shell_block_arrangement_reset_test.dart`（真实外观 schema + 真实 ThemeNotifier：全新安装不算已改过；只切拼贴仍不算；网格下选交错后恢复默认回到规整且偏好清空，再切拼贴跟着走成散落）。
- **备注**：纯设置元数据 / 偏好写法，无布局像素改动，不需设备复测。
