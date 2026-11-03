## BUG-3978 · 阅读器点 ruby 词的后半个基字：查的只有后半、亮的却是整个词
- **报告**：2026-11-02（用户反馈 chj2rZn89F）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/reader/reader_selection_scripts.dart` selectFromPosition 从点中码点起扫（旧 3263-3271），highlightSelection 只要段在 <ruby> 内就给整个 ruby 元素加 `fushi-selection-ruby-active`（旧 4040-4054，BUG-110 取舍），查词范围与高亮范围口径不一致）
- **[x] ① 已修复** — 新增 `selectionStartFor`：命中 ruby 基字时吸附到该 ruby 基字段首个文本节点偏移 0（多对基字按段），选区起点、悬停去重、点击 toggle 共用；新增 `rubiesFullyCoveredBy`：只有裁剪后的段完整覆盖 ruby 全部基字才整元素加类，部分覆盖按字符范围进 ::highlight，绝不超画（分支 claude/review-merge-bug-fixes-b183d4，未提交）
- **[x] ② 已加自动化测试** — `fushi/test/reader/ruby_tail_tap_selection_test.dart` + `ruby_tail_tap_selection_harness.mjs`（真 Chrome，分页 / 连续两个 shell）
- **备注**：按 CLAUDE.md 需在 paginated / continuous / vn 三模式真机复测：本轮只在无头 Chrome 跑了分页与连续 shell 的生产脚本；vn shell 用独立的 fushiReader 但共用 fushiSelection，未单独验证；真机复测未做。部分覆盖时竖排仍走 ::highlight，可能出现 BUG-110 描述的双绘加深（不再超画范围）。
