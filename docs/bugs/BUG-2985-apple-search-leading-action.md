## BUG-2985 · Apple 搜索框丢弃显式前缀操作按钮
- **报告**：2026-10-06（样式改版审查）
- **真实性**：共享搜索组件 API 契约缺陷；真实渲染路径可确认，未找到已受影响的现有业务调用。
- **根因**：固定快照 `1a5424c847a` 的 `fushi/lib/src/utils/components/glass/fushi_glass_inputs.dart:903` 将搜索框所有 prefixIcon 替换成静态放大镜，连上层显式提供的 `FushiSearchLeading` 操作按钮也被丢弃，按钮及其回调不可达。
- **[x] ① 已实现修复** — 保留显式 `FushiSearchLeading`，普通搜索图标仍转换为 Apple 图标。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/fushi_shared_controls_contract_test.dart`，校验自定义 leading 可见且点击触发回调。
- **验证结果**：见 [审查报告 HBK-AUDIT-004 及最终验证记录](../reviews/2026-10-06-project-review.md)，不将测试存在等同于运行通过。
- **备注**：未完成真实设备验收，不宣称线上业务已复现或实机已通过。
