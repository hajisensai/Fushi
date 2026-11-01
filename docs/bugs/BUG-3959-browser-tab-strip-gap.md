## BUG-3959 · 浏览器顶部活动标签不贴地址栏、中间露 6dp 缝
- **报告**：2026-11-01（用户：截图「浏览器标签页贴合有问题」，Windows 200% 缩放、顶部标签栏模式）
- **真实性**：✅ 真 bug。截图量像素：活动标签底色占 0–30dp，标签栏背景 30–36dp，地址栏 36dp 起——标签顶对齐而非贴底。根因 `fushi/lib/src/pages/implementations/web_browser/web_browser_tab_lists.dart` `_StripReorderList.itemBuilder`：贴底用的 `Align(bottomCenter)` 套在 `_GrowIn` 外面，而 `_GrowIn` 横向是 `SizeTransition`——它纵向撑满并按顶对齐（`AlignmentDirectional(x, -1)`），外层 Align 形同虚设；加上 `FushiReorderableRow` 外层 `Stack` 把纵向约束放松成 0..36，标签恒停在顶部。
- **[x] ① 已修复** — itemBuilder 外包 `SizedBox(height: kWebBrowserTabStripHeight)` 定高，贴底的 `Align` 挪进 `_GrowIn` 里面（直接包 `_StripTab`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/web_browser/web_browser_tab_middle_click_test.dart`「标签贴着标签栏底边」：断言 strip 高 36、标签 bottom == strip bottom。
- **备注**：Windows 真机肉眼复测待补。
