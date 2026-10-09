## BUG-2988 · 自定义主题色卡及编辑预览与实际应用配色不一致
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实配色解析契约缺陷，固定审查快照为 `1a5424c847a`。
- **根因**：`fushi/lib/src/settings/settings_actions.dart:373` 的自定义色卡另造 ColorScheme，遗漏 surfaceColor、neutralDerived 及系统强调色解析；`fushi/lib/src/pages/implementations/custom_theme_page.dart:270` 的编辑预览遗漏 pureBlackDark。预览与活跃主题的多个解析入口产生配置漂移。
- **[x] ① 已实现修复** — 在 ThemeNotifier 提供 `buildCustomThemeColorScheme`，活跃主题、设置色卡及编辑草稿共用，并将纯黑开关纳入预览缓存条件。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/models/custom_theme_scheme_consistency_test.dart`，比较预览与实际 scheme，覆盖 surface、中性派生、系统色、纯黑及墨水屏；校验设置色卡消费实际配色。
- **验证结果**：见 [审查报告 HBK-AUDIT-008 及最终验证记录](../reviews/2026-10-06-project-review.md)。
- **备注**：未进行像素比较或真实设备主题视觉验收，不宣称实机通过。
