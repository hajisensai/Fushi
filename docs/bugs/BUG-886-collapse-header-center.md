## BUG-886 · 折叠设置分组标题头文字与箭头未垂直居中
- **报告**：2026-07-18（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/components/settings_shared.dart:196`（PR#209 合入的可折叠 section 标题头）。`AdaptiveSettingsSurface._buildContainedTitle` 直接复用「行上方小标题」的上重下轻 padding `fromLTRB(12, 10, 12, 4)`（上10/下4）来渲染折叠头 label；折叠头那一行里 chevron 按 Row 默认 `crossAxisAlignment.center` 垂直居中，导致标题文字比 chevron 低约 3px，视觉上没居中。
- **[x] ① 已修复** — `settings_shared.dart:_buildContainedTitle` 增加 `interactive = onTitleTap != null` 判定：折叠头（可点整头）用上下对称 padding（Material `fromLTRB(12, 10, 12, 10)` / Cupertino `fromLTRB(16, 10, 16, 10)`），标题与 chevron 共享同一垂直中线；静态内嵌小标题（`onTitleTap == null`）保持上重下轻贴住下方设置行，行为不变。提交：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/settings_shared_test.dart`：`collapsible section header title is vertically centered with its chevron (BUG-886)`，构建 `collapsible: true` 的 `AdaptiveSettingsSection`，断言标题文字与 `Icons.expand_more` 的垂直中心差 < 1.5px。已验：还原修复后该测试失败（差约 3px），修复后通过。
- **备注**：同批用户反馈的「互联与同步后端不冲突」（互联从单一 `SyncBackendType` 解耦）是独立架构改动，另立 PR 根修，不在本 bug 范围。
