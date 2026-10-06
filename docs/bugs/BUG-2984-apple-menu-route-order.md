## BUG-2984 · Apple 菜单回调打开的新路由被随后关闭
- **报告**：2026-10-06（样式改版审查）
- **真实性**：共享组件 API 契约缺陷；已定位真实执行路径，未找到已受影响的现有业务调用，不称为线上已复现故障。
- **根因**：固定快照 `1a5424c847a` 的 `fushi/lib/src/utils/components/glass/fushi_glass_overlays.dart:2262` 先执行 `item.onTap` 再 pop 菜单；回调同步打开新路由时，随后的 pop 会关闭新路由而留下旧菜单，泛型不同时还可能发生返回值类型错误。
- **[x] ① 已实现修复** — 先带 value 关闭菜单，再执行回调，与 Material 菜单契约一致。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/fushi_shared_controls_contract_test.dart`，两套主题下菜单回调打开对话框的路由行为。
- **验证结果**：见 [审查报告 HBK-AUDIT-003 及最终验证记录](../reviews/2026-10-06-project-review.md)；失败或未完成的中间轮次不计通过。
- **备注**：未完成真实设备验收，不宣称业务端到端已通过。
