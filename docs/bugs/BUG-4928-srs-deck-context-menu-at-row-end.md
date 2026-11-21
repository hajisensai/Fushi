## BUG-4928 · 复习牌组列表右键菜单弹在行的右端，不在鼠标处
- **报告**：2026-11-21（用户：应用内反馈 Ne6WHI9TYE「右键怎么是在右边弹出的，不符合 M3E 规范」）
- **真实性**：✅ 真 bug。牌组行的右键经 `FushiCard` / `FushiGroupedListItem` 的 `ContextMenuTrigger` +
  `contextMenuInvoker` 同步派发，按下坐标此时在 `activeContextMenuAnchor` 里；但行的 `onSecondaryTap`
  （`fushi/lib/src/pages/implementations/srs/srs_deck_list_page.dart:1752`、`:1843`）调 `_showMenuFor(rowContext)`
  不带坐标，`_showDeckMenu` 也不读 `activeContextMenuAnchor`，`at == null` 时一律用 `rowRect.centerRight` 当锚点
  （`fushi/lib/src/pages/implementations/srs/srs_deck_home.dart:2043`），于是宽屏右键在行首点也会从行的最右端弹菜单。
  widget 测试实测：右键点在 x≈189，菜单项出现在 x≈824。
- **[x] ① 已修复** — `_showDeckMenu` 在第一个 await 前读 `activeContextMenuAnchor`，有按下点就经
  `overlay.globalToLocal` 换算后以该点（零尺寸矩形）为锚弹菜单；长按 / 菜单键 / 详情「选项」按钮没有按下点，照旧贴在
  锚点组件右端。删掉从未有调用方传值的 `at` 参数。提交哈希：见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_pages_test.dart`「牌组列表宽屏：行尾是三列计数 + 播放…」用例补：
  右键点牌组名，断言菜单第一项左上角与按下点水平 / 垂直距离都 < 80（MD3 与 Apple 两套各跑一遍；修前偏 635 / 641）。
- **备注**：
