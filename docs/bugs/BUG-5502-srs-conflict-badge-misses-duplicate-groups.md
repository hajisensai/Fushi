## BUG-5502 · 复习页「同步冲突」角标不数可能重复的笔记组，只有重复组时角标为 0、进去却有冲突
- **报告**：2026-11-26（用户：应用内反馈 4cqrL4u9UI，Android 3.4.0-debug.32203，「同步冲突没提醒，但我进去里面看到有冲突的」）
- **真实性**：✅ 真 bug。角标 `srsConflictCountProvider`（`fushi/lib/src/srs/srs_providers.dart`）只数 `syncConflicts` + `sync2Conflicts` + 待确认设备 + `pendingDecisionCount`；冲突页 `srs_conflicts_page.dart` `_load` 另外列出 `store.duplicateNoteGroups()`（可能重复的笔记，sync v2 设计 §5.4）。只有重复组时角标为 0、菜单显示无数字的「同步冲突」，进去却有内容。
- **[x] ① 已修复** — 角标加上 `duplicateNoteGroups().length`，与冲突页同一个函数、同一口径（含「不是重复」排除）；仍走 `_srsMemoByContent`，内容指纹不变时不重算。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_content_memo_providers_test.dart`「冲突角标数可能重复的笔记组」：两条同词形同读音笔记 → 角标 1，标「不是重复」后 0。
- **备注**：
