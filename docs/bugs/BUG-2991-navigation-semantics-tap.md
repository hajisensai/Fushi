## BUG-2991 · 自适应导航按钮未提供读屏激活动作
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实无障碍动作接线缺陷，固定审查快照为 `1a5424c847a`。
- **根因**：`fushi/lib/src/utils/adaptive/adaptive_navigation.dart:1318`、`:1405`、`:1989` 的 mini capsule、FAB、rail menu 包装使用 `excludeSemantics: true` 移除子节点动作，却未给自身 Semantics 提供 onTap；读屏虽能找到按钮却不能激活。
- **[x] ① 已实现修复** — 三类控件补自身语义 tap，rail menu 复用同一个含触觉反馈的激活函数。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/adaptive_nav_semantics_actions_test.dart`，直接发出语义 tap 并断言相应操作回调。
- **验证结果**：见 [审查报告 HBK-AUDIT-013 及最终验证记录](../reviews/2026-10-06-project-review.md)。
- **备注**：未完成 TalkBack/VoiceOver 真机交互验收，不宣称读屏端到端通过。
