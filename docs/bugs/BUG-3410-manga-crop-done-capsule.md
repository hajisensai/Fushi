## BUG-3410 · 手机漫画高级制卡全屏框选页右上角「完成」在动作胶囊里偏左
- **报告**：2026-10-14（用户：手机截图「漫画高级制卡手机右上角 ui 有问题」）
- **真实性**：✅ 真 bug。M3E 悬浮顶栏（`fushi/lib/src/utils/components/glass/fushi_glass_bars.dart` `_buildFloating`）把 actions 收进一枚 `FushiPageChromeCapsule`，并在胶囊**外**自己留 16 的尾部边距；全屏框选页（`fushi/lib/src/mining/advanced_mining/advanced_mining_manga_panels.dart` `_MangaCropFullscreenPageState.build` 的 `actions`）还沿用旧 AppBar 写法给「完成」包了 `Padding(end: 12)`，这 12 落进了胶囊**里面**：按钮左侧只剩胶囊内边距 4、右侧 4+12=16，胶囊被撑宽、按钮明显偏左。
- **[x] ① 已修复** — 去掉页面自带的尾部 Padding，留白交给悬浮顶栏统一负责。
- **[x] ② 已加自动化测试** — `fushi/test/mining/advanced_mining/advanced_mining_dialog_test.dart`「手机漫画：图片行进入全屏框选…」断言「完成」在动作胶囊里左右间距相等（修复前 4 vs 16 红，修复后绿）。
- **备注**：`subtitle_workbench_page.dart` 的作用域开关也带 `Padding(right: 12)`，但走的是 `FushiPageScaffold` 另一条页头路径，本次未报、未改。
