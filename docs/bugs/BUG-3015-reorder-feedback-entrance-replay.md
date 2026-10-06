## BUG-3015 · 开页进场期间拖动列表行时反馈副本重新变透明
- **报告**：2026-10-06（Codex 标签重排修复交叉审查）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_reorderable_column.dart:420` 在拖动时再次调用 itemBuilder 创建反馈副本，处于祖先进场窗口时新 `FushiStaggeredEntrance` 从透明度 0 起播。实测默认/把手模式在开页 200ms 起拖均从已可见约 0.92 退回 0；原始日志为外部 `verify-1006-logs/closure-extra.jsonl`（10 项、8 通过、2 失败）。
- **[x] ① 已修复** — 共享 `FushiReorderDragProxy` 对副本使用关闭的 `FushiEntranceScope`，只禁止子行重复进场，保留代理自身抬起动效；scope 的 enabled 开关默认 true，切换时更新 generation，关闭即到终态、开启可重新进场。
- **[x] ② 已增加自动化测试** — `fushi_reorderable_handle_lifecycle_test.dart` 覆盖两种模式早期起拖不回退透明度、把手取消不提交、快速纵滑由父容器滚动；`fushi_motion_redesign_test.dart` 覆盖 scope 初始关闭及双向切换。
- **备注**：设备视觉复测未执行；自动化修复后复测结果见外部 `outputs/verify-1006-last.md`，不以源码审查替代实际通过数。
