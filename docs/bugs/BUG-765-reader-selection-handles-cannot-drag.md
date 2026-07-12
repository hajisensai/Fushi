## BUG-765 · 阅读器移动端自绘选区两端手柄拖不动
- **报告**：2026-07-12（用户：qqbotxiaoxiao，原话「我们改的两边选区按钮都拖不动」，并提议换原生选区——经确认改为修好自绘手柄，不换原生：换原生会把系统选择菜单搬进阅读器、丢失查词/制卡集成）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/reader/reader_selection_scripts.dart` `moveSelectionHandle`（原 :1347）：拖手柄时在**手指当前像素**做 `getCharacterAtPoint(x,y)`，而手柄 div 是 `pointer-events:auto` + `z-index:2147483645` + 24×24px 正压在被选字角。`getCharacterAtPoint`→`getCaretRange` 的 `caretPositionFromPoint`/`elementFromPoint` 命中的是最上层的手柄 div（ELEMENT_NODE，非文本节点）→ `if (node.nodeType !== Node.TEXT_NODE) return null` → `hit` 为 null → `moveSelectionHandle` 早退 → 选区永不更新 → 手柄视觉冻结（拖不动）。守卫测试只查「调用了 collectRangeBetween」照不出真机失效。
- **[x] ① 已修复** — `moveSelectionHandle` 在 hit-test 前把两个手柄临时 `pointer-events:none`、取字后还原（`savedStartPe`/`savedEndPe`），使手指坐标穿透到底下字符。全程仍只改 `this.selection` + CSS Custom Highlight，绝不碰原生选区（不复活 TODO-1279 双选区）。提交：cc6484e87
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_selection_handles_guard_test.dart` 补 `moveSelectionHandle` 在 hit-test 期间置 `pointer-events`='none' 再还原的守卫。
- **备注**：真机验证待用户（长按拖选后，拖两端手柄能实时调整选区）。次因假设（Android 手势竞技场抢 fresh touchstart）未处理——主因单独即足以造成冻结，若真机仍有边缘拖动被抢再单列。
