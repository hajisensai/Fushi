## BUG-3009 · 组件棘轮守卫路径替换空串导致零文件扫描并静默通过
- **报告**：2026-10-06（Codex 全量目录守卫复核）
- **真实性**：✅ 真 bug。`fushi/test/build/m3e_raw_component_ratchet_guard_test.dart:59` 用 `replaceAll(r'', '/')` 归一化路径，把斜杠插到每个字符之间，随后的 `.endsWith('.dart')` 恒为 false；组件棘轮守卫实际扫描零文件，仍报成功。
- **[x] ① 已修复** — `e61bf97c24e`：路径归一化改为替换反斜杠，各组件守卫统一使用共享词法掩码。`2b3c95f5a8a`：真实扫描暴露的 Tooltip / Badge 消费调用迁移到现有共享组件，不提高存量预算。
- **[x] ② 已增加自动化测试** — `m3e_raw_component_ratchet_guard_test.dart` 增加扫描规模下限 1200（本次实测 1547）与注释/字符串合成自检；另三个消费守卫补块注释、URL、行号自检。
- **备注**：这是验证基础设施缺陷。整批守卫及相关组件测试结果见外部 `outputs/verify-1006-last.md`。

- **PR #1984 集成**：已在 pr/m3e-wave-1 复用对应修复；本 PR 的验证独立记于 outputs/pr-m3e-wave-1-review.md，不能继承 verify-1006 的通过结果。
