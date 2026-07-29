## BUG-1243 · 有声书片段导出多句退化并附带多余音频文件
- **报告**：2026-07-29（用户）
- **真实性**：✅ 真 bug。导出先用 currentSentence 的单句 range 分类，动态计划又通过“句级优先”的 `_miningSpanRange()` 把跨句原生选区收窄，最终只裁第一句并退化为整段静态高亮；移动分享还额外暴露临时 AAC，显示成多余附件。
- **[x] ① 已修复** — 先用真实 `_cachedSelectionRange` 的 offset/length 建多 cue 计划，并让该计划的全局起止成为最终裁剪范围；无原生选区才回退单句锚。移动端仅分享已显式映射 AAC 音轨的 MOV，临时 AAC 始终清理。
- **[x] ② 已加自动化测试** — `audiobook_clip_dynamic_divergence_guard_test.dart` 钉住选区 span 与“先计划后分类”的完整范围；`audiobook_clip_export_contract_test.dart` 钉住视频显式音轨映射且分享列表不含 AAC sidecar。
- **备注**：字幕/EPUB 文本不一致时仍安全回退精确 EPUB 文本静态卡，不用字幕文字替换原文。
