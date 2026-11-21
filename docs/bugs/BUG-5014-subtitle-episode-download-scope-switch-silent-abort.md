## BUG-5014 · 本集字幕下载途中重搜或切作用域静默丢下载
- **报告**：2026-11-20（路线图 #3722 遗留（docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md 第 3 节），c23 留下的「本集面板批量下载途中重搜没加闸」「批量途中切作用域会静默中止」）
- **真实性**：✅ 真 bug，两处同源——下载在途时面板没有任何「在下载」的状态闸：
  - 重搜：`fushi/lib/src/pages/implementations/subtitle_search_panel.dart` 的 `_search` / `_selectSeries` 与搜索钮、回车、标题 chip、系列 chip 都只看 `_searching`；下载途中重搜清空候选与勾选，批量按旧勾选往下跑，部分失败后「失败的仍勾着可重试」随之丢失。（合集面板的同类问题 c23 已加闸。）
  - 切作用域：`fushi/lib/src/pages/implementations/subtitle_workbench_page.dart` 的作用域开关随时可点，`AnimatedSwitcher` 把本集面板换下即 dispose，`_pageClosed`（`!mounted`）为真 → 在途那条不落盘、其余勾选不再下，无任何提示。
- **[x] ① 已修复** — cb474f4ff9：面板加 `_downloading` 闸（单条 / 批量共用，挡所有发起检索的入口），经 `onDownloadingChanged` 告知宿主；工作台据此禁用另一个作用域按钮，tooltip 说明「字幕下载完成后才能切换」。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_search_panel_reliability_test.dart`「工作台：本集下载途中锁住作用域开关与重搜，下完解锁」。
- **备注**：c23 同组的「对话框壳点遮罩关闭时拿不到已落盘路径」核实为生产无调用方（`JimakuSubtitleDialog` 只剩测试在用），未改。
