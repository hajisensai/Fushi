## BUG-829 · 制卡选择上下文·往前加一句每句都是当前句(重复)
- **报告**：2026-07-15（用户：截图「往前加一句都是一样的，往后就正常」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/reader/reader_selection_scripts.dart:738`（`getSurroundingSentences` 向前循环）。
- **[x] ① 已修复** — `reader_selection_scripts.dart` 向前循环把 `getSentenceContext(before.node, before.offset + 1)` 改为 `getSentenceContext(before.node, before.offset)`。根因：`charBefore(node, offset)` 在同节点内返回 `{node, offset-1}`，即 `before.offset = anchorOffset - 1`；再 `+1` 就等于 `anchorOffset` = 当前句首光标，`getSentenceContext` 于是重新解析出**当前句**、anchor 原地不动 → 每次「往前一句」都拿到当前句、前文列表全是同一句重复（正是截图现象）。向后循环 `getSentenceContext(after.node, after.offset)` 本就无 `+1`，故「后加一句」一直正常。去掉 `+1` 后 `before.offset` 落在上一句最后一个字符（其句号）上，正确解析出上一句，anchor 逐句后退。修复提交见 PR#147 分支。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_surrounding_sentences_prev_walk_guard_test.dart`：扫描 `ReaderSelectionScripts.source()` 的 `getSurroundingSentences` 向前循环，钉死其用 `getSentenceContext(before.node, before.offset)` 且**不得**再出现 `before.offset + 1`（触屏真机才能跑真 DOM 遍历，故沿用 BUG-764 同款生成 JS 源码扫描守卫层）。
- **备注**：与 UI 重制（PR#147 一句一卡）同分支；UI 只是让重复句更显眼，数据层根因在此。跨分支可能与 PR#148 撞 829 号，合并期 `dart run tool/bug.dart reindex` 重排。
