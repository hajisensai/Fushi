## BUG-4374 · 同步冲突页批量处理被删成只剩逐条
- **报告**：2026-11-08（应用内反馈 `IBjxAjty39` 重开，macOS 3.3.0-debug.23876：「我希望的是能够批量处理同步冲突的问题，而不是直接把按钮删了」；截图里页上只有一组「可能重复的笔记」，右上角是一颗灰掉的「全部确认」）。
- **真实性**：✅ 真 bug（BUG-4188 修错了方向）。顶栏「全部确认」当初只循环字段冲突 `_conflicts`（`srs_conflicts_page.dart` 旧 `_confirmAll`），而冲突页同时列着扣住的删除 `_held`、可能重复的笔记 `_duplicates`——这两节只有逐条按钮，没有任何批量入口；页上只剩它们时按钮恒灰。BUG-4188 把「灰掉」改成「整颗不画」，症状（点不动）没了，但真正的缺口（这几节无法批量处理）原样留着，用户要的批量能力反而彻底消失。
- **[ ] ① 已修复（PR 待合）** — 顶栏改成「批量处理」（`srs_conflicts_page.dart:603` `_bulkItem`）：被替换的设置 / 扣住的删除 / 可能重复的笔记任一节有条目就画，点开列出当前有条目的各节的批量选项（`:518` `_openBulk`，`showFushiChoiceDialog`）：设置「都按推荐 / 都保留当前值」、扣住的删除「全部保留（推荐）/ 全部删除」、重复笔记「全部合并（各保留复习最多的那条）/ 都不是重复」；删除与合并再确认一次；`:461` `_bulkResolve` 逐条走与逐条按钮相同的 store 调用（`resolveConflict` / `sync2Resolve` / `mergeNotes` / `dismissDuplicates`）。待确认的设备（安全决定）与等你决定的笔记（要在编辑页看字段内容）仍逐条处理，对话框写明。
- **[ ] ② 自动化测试（PR 待合，未在分支上运行）** — `fushi/test/srs/srs_conflicts_held_delete_test.dart`「顶栏批量处理：扣住的删除全部保留 / 全部删除」、`fushi/test/srs/srs_conflicts_duplicates_test.dart`「两组重复笔记全部合并 / 都不是重复」，MD3 与 Apple 各一遍；`srs_device_names_test.dart` 与原重复笔记测试改断言批量按钮在。
- **备注**：前一次修复见 BUG-4188（同一反馈 `IBjxAjty39`）。
