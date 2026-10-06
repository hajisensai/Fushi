## BUG-3019 · 设置步进器迁移后声明宽度少算触控区导致标题挤压
- **报告**：2026-10-06，PR #1984 / HBK-AUDIT-W1-005。
- **真实性**：✅ 真布局回归。`fushi/lib/src/utils/components/settings_shared.dart:106` 的 trailing 宽度仍按旧 compact IconButton 的 40dp 计算，而 `_SettingsStepButton` 已使用触控外宽 48dp 的 `FushiIconButtonControl`，实际 176dp 与声明 160dp 不符。`AdaptiveSettingsRow` 在临界宽度因此错误保持横排，标题可用宽度低于契约。
- **[x] ① 修复** — 按钮布局与宽度声明共同使用 `kSettingsStepperButtonWidth`，保留 48dp 触控区及共享按钮视觉。提交见本文件所属修复提交。
- **[x] ② 增加自动化测试** — `fushi/test/settings/settings_stepper_row_label_width_test.dart` 保留实测尺寸断言，扩充临界宽度及 1x/1.3x 文字缩放，明确检查阈值下堆叠、阈值上横排与标题最低可读宽度。
- **备注**：定向测试排队中；设备原始布局复验待补，不声明设备验证完成。
