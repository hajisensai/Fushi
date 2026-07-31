## BUG-1276 · 黑色主题下学习活动热力图空周融进背景
- **报告**：2026-07-29（用户：「这个主题什么也看不见」）
- **真实性**：✅ 真 bug。截图中的黑色主题把学习活动卡底与无活动格子的
  surface 填充压进低对比区；已有 BUG-1073 只把填充从 `surfaceContainer`
  换到 `surfaceContainerHighest`，没有建立独立于 surface 色阶的可见边界。
- **根因**：
  - `hibiki/lib/src/pages/implementations/home_dashboard_page.dart:1417`
    只向热力图传了 `emptyColor`；主题的 surface 色阶接近时，53 周无活动格子
    仍会融进 `_sectionCard` 背景。
  - `hibiki/lib/src/utils/components/stat_contribution_heatmap.dart:515`
    对 level 0 与 level 1..4 一律只画填充，没有 outline 兜底。
- **[x] ① 已修复** — `StatContributionHeatmap` 新增可选
  `emptyBorderColor`，首页传入主题的 `outlineVariant`；level 0 在填充之外画
  1px 内描边，即使填充与卡底完全相同也能看见完整网格。实现提交：
  `bbdefaf05`。
- **[x] ② 已加自动化测试** —
  `hibiki/test/widgets/stat_contribution_heatmap_wide_test.dart` 构造黑色卡底 +
  黑色空格填充的 surface 色阶完全坍缩场景，读取真实 `CustomPaint` 像素，断言
  空格边缘保持可见而中心仍为原填充色。
- **备注**：用户明确免去本轮编译验收；PR 会如实记录未跑完整编译/真机截图复测。
