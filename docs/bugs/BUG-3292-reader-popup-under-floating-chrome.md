## BUG-3292 · 阅读器悬浮底栏/迷你播放条盖住查词弹窗
- **报告**：2026-10-10（反馈 #7NmMDZKs2f，Android：查词「格式也出现了问题」，截图里有声书播放条与悬浮工具栏压在弹窗词条上）；iOS 反馈 #LZDKhmJFpM 的截图同样可见迷你播放条 + 悬浮工具栏压在弹窗下半截。
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/reader_fushi_page.dart` 的 `popupBottomReserve` 只对挤压底栏预留（`_bottomChromeReserve > 0 ? … : 0`），而 `bottomChromeReserve()`（`fushi/lib/src/reader/reader_chrome_floating.dart`）在悬浮态恒为 0；悬浮工具栏样式是默认值。同时 `_buildBottomChrome()` 在 Stack 里排在 `buildDictionary()` **之后**绘制。于是悬浮底部件（迷你播放条 / 底部悬浮工具栏，点空白唤出后常驻到下一次点击）被唤出时，弹窗按「底部没东西」排版并被它们盖住。
- **[x] ① 已修复** — 新纯函数 `readerPopupBottomReserve`（`reader_chrome_floating.dart`）：挤压底栏照旧；悬浮底部件此刻在画（`_floatingToolbars && !_lyricsMode && _bottomBarShouldPaint`，与 `_buildFloatingBottomChrome` 的显隐判据同一份）时，弹窗让开 状态行画出带 + `_bottomChromeExtent`；收起时仍用满到屏底。提交 `cde1987e24`。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_chrome_floating_test.dart` 的 `popup bottom reserve (BUG-3292)` 组（真值表 + 页面经该 helper 接线的源码守卫）。
- **备注**：真机未复测。弹窗打开期间再唤出 / 收起底栏时，弹窗位置随下一次重建重算。
