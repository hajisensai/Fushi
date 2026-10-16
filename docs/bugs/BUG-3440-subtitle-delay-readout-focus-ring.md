## BUG-3440 · 字幕调轴读数胶囊的焦点环四角残缺
- **报告**：2026-10-16（用户反馈 `B-yPx_on2A`，Windows：「字幕调轴中间的数值显示区域怎么感觉不太对」，附截图）
- **真实性**：✅ 真 bug。截图里「+0 ms」读数胶囊处于聚焦态，主色描边只在四角露出几段弧、直边几乎看不见。根因 `fushi/lib/src/media/video/video_subtitle_sync_row.dart` `_DelayReadoutFieldState.build`：读数胶囊是带不透明底色（`surfaceContainer`）、圆角 `FushiM3eShape.cardRadius`（20）的 `AnimatedContainer`，外层用 `FushiFocusable` 默认参数包着；`fushi/lib/src/utils/components/fushi_focusable.dart` 的焦点环是 `DecoratedBox`（默认 background 位置）、半径 8 —— 环画在胶囊下面被底色盖住，只在两种圆角的差值处漏出残角。不是溢出 / 截断。
- **[x] ① 已修复** — `FushiFocusable` 新增 `ringPosition`（默认仍是 background，其它调用点不变）；读数胶囊传 `borderRadius: FushiM3eShape.cardRadius` + `ringPosition: DecorationPosition.foreground`，焦点环与胶囊同形并画在上面。提交见本分支 `fix(video): draw subtitle delay readout focus ring on top of the pill`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_delay_float_bar_test.dart`「读数胶囊聚焦：焦点环与胶囊同形并画在胶囊上面」：聚焦读数后断言环 `DecoratedBox.position == foreground`、`borderRadius == cardRadius`、描边非透明。
- **备注**：未在 Windows 真机目测（纯视觉；widget 测试钉住形状与图层顺序）。其它 `FushiFocusable` 调用点（排行榜头像、设置项等）若子组件自带不透明底色同样会盖住焦点环，本次未逐一处理。
