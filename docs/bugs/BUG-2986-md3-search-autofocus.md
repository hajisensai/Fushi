## BUG-2986 · MD3 默认尺寸搜索框忽略自动聚焦
- **报告**：2026-10-06（样式改版审查）
- **真实性**：真实参数转发缺陷，固定审查快照为 `1a5424c847a`。
- **根因**：`fushi/lib/src/utils/components/fushi_material_components.dart:1289` 的 regular MD3 搜索框分支遗漏 `autofocus`，而 large 与 Apple 分支已转发；调用方请求自动聚焦时默认尺寸搜索框不聚焦。
- **[x] ① 已实现修复** — regular 分支向底层输入框转发 `autofocus`，不改变默认值。提交见本文件所在修复提交。
- **[x] ② 已增加自动化测试** — `fushi/test/widgets/fushi_shared_controls_contract_test.dart`，尺寸与设计系统组合下的实际焦点行为。
- **验证结果**：见 [审查报告 HBK-AUDIT-005 及最终验证记录](../reviews/2026-10-06-project-review.md)。
- **备注**：未完成真实设备软键盘及硬件键盘验收，不宣称实机通过。
