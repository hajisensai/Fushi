## BUG-2331 · Shift 悬停同一单词重复查词
- **报告**：2026-09-09（用户：按住 Shift 停在单词上会重复查询）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_selection_scripts.dart:1157` 的 `selectText` 只比较原始 hit 与 selection 起点；拉丁词首归一化发生在其后，多字日语匹配范围也未参与判断。高亮 fallback 还会拆换文本节点。
- **[x] ① 已修复** — 悬停按 `highlightSelection` 实际匹配范围去重，兼容自己的高亮 wrapper；结果未返回时按既有拉丁词首规则去重。不把整段扫描缓冲当成词范围，保留换词和真点击 toggle。提交见本文件所在提交。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_hover_lookup_behavior_test.js` 执行生产 JS，覆盖 pending 拉丁词、相邻词、多字日语、跨节点、范围末端、关闭重查、真点击与 wrapper fallback；Dart wrapper 纳入 Flutter 定向测试。
- **备注**：Node 8 个行为场景、Flutter 44 条定向测试、282 条相邻测试及完整 flutter analyze --no-pub 均通过。旧版生产脚本运行同一测试得到 5 次查询（预期 1），修复后通过。首次 PDFium 下载超时，配置代理后重跑通过。尚未在真实 Windows 阅读器复测原始悬停操作；本轮定位并修改阅读器正文路径，用户尚未确认发生位置。
