## BUG-5381 · home-today-time-line-clipped
- **报告**：2026-11-24（用户：开发者本人，应用内反馈 TinO49VcdQ「27分钟被吞了一半」，Windows 1077×947 窗口）首页色块「今日」格大字下面那行今日时长只露出上半截。
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dashboard_widget_cells.part.dart` 的 `_todayCell`（:778）用整格高度 `c.maxHeight` 判 `dense`，`_todayFigure` 据此定大字号（修前 :1394 `large: !dense`）与挂不挂时长行（修前 :1424 `if (!dense)`）；可内容区是整格减掉内边距和卡头之后更矮的那块，大字 + 4px + 时长行的自然高度放不下时，修前 :1431 / :1474 的 `_fitCenter(column)`（`ClipRect` + `OverflowBox` 竖向居中）不报溢出、直接把上下两头裁掉，时长行下半截就没了。
- **[x] ① 已修复** — `fushi/lib/src/pages/implementations/home_widget_frame.dart` 新增 `HomeWidgetFigureWithLine`：按自己拿到的内容区实际高度排，副行按自然高度完整画出，大字（`HomeWidgetFigure` 自带 `FittedBox` 等比缩小）收进剩下的高度；剩下的不够最小大字高（24）时整行副行不画。副行高度按行样式与当前文字缩放估（`homeWidgetLineExtent`，未给行高时按 1.5 倍字号保守估）。`_todayFigure` 的两处 `_fitCenter(column)` 换成它，不再靠裁剪。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_widget_figure_with_line_test.dart`：真实 `HomeWidgetFrame`（色块外观）里放大字 + 时长行，格高 76 / 96 / 104 / 120 / 140 / 180 × 文字缩放 1.0 / 1.3 共 12 组，断言无溢出异常、大字在内容区内、时长行要么整行不画要么完整落在内容区内且不超行，≥120 高（缩放 1.0）时时长行一定在，内容区里没有 `OverflowBox` 裁切层。
- **备注**：「今日」格的目标翻页（`_todayGoalsPager`）与总览版式不走 `_todayFigure`，本次未动。Windows 真机窄窗口目测复测未做。
