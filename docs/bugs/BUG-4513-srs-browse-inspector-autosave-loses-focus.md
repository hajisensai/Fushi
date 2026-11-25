## BUG-4513 · 浏览页检查器快捷编辑自动保存后输入框重建、丢焦点
- **报告**：2026-11-15（应用内反馈 a0lR-BHuJU）
- **真实性**：✅ 真 bug，widget 测试复现（修前同一字段的 `EditableTextState` 在自动保存后换成了新对象：
  `SrsFieldEditor` 的 State 没变，它的 `KeyedSubtree('${_kind}-$_source-$_generation')` 因 generation 变了整块重建）。
  - 根因：`fushi/lib/src/pages/implementations/srs/srs_browse_inspector.dart:537-555`（修前）`_EditTabState.didUpdateWidget`
    每次父级重建都拿 `widget.detail` 与「最近一次落库的值」`_saved` 比。停笔 800 ms 的 `_save`（`:584`）一开始就把 `_saved`
    改成新值；写入后浏览页 `_afterWrite` 让 revision +1 并 setState，检查器在新数据读回之前先带着**旧的** detail 重建一次：
    旧值 ≠ 新 `_saved`、编辑器值 = `_saved`，被当成「别处改了这条笔记」，`SrsFieldModel.reset` 把字段换回旧值、generation +1，
    编辑器重建——输入框失焦、光标丢失、刚打的字被换掉。标签输入框同一个比较法，同样会被换回旧标签。
- **[x] ① 已修复** — 对账只在读回新数据时做（`identical(old.detail, widget.detail)` 就跳过），且只认库这一侧相对上一份
  detail 真的变了的格子；变成的正是自己刚存进去的值（自己保存的回声）不算外部修改。别处的写入（批量操作 / 撤销）照旧在没有
  未保存改动时换成新值。标签同理。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_browse_ime_and_inline_edit_focus_test.dart`「检查器编辑页签停笔自动保存后…」：
  宽屏浏览页，焦点切到「编辑」页签、字段持焦打字，等过 800 ms 自动保存与重读，断言仍是同一个 `EditableTextState`、仍持焦、
  文本与光标不变，接着打字再存一次照常。撤销（外部写入）后字段换回旧值仍由 `srs_browse_page_test.dart`「编辑页签停笔自动保存
  （可撤销）」覆盖。
- **备注**：
