## BUG-3283 · 库页工具区收起后内容中间残留浅色横带（嵌套遮罩按恒定 inset 起画）
- **报告**：2026-10-10（应用内反馈 #TpJh4uThcD 书架继续阅读卡浅色横带、#ldcLOOpQg0 漫画发现页大横幅一条亮线 / 视频库下拉白线、#6ixTuvHysg 视频库下滚→上滚→再下滚遮罩残留，均 Windows；截图两张均为工具栏收起后）
- **真实性**：✅ 真 bug，非设计行为。截图里横带顶边在 y≈90–97（视口顶边之下、内容中间），顶端硬边、向下渐隐。根因 `fushi/lib/src/utils/components/fushi_floating_chrome.dart` `_FushiFloatingChromeOverlayState.build`：嵌套层（页面自己的搜索 / 筛选行）的遮罩 `Positioned(top: outer)`，而 `outer` 是外层工具区**恒定**让位量（`FushiFloatingChromeInset`，刻意不随收起变，否则滚动视口抖动）。工具区收起后外壳页签早已滑出画面，嵌套遮罩却仍从页签高度（测试里 56 px，实机约 90 px）起画，顶端不透明度 `kFushiTopScrimOverlayOpacity`(0.72) 起头——内容中间凭空一条硬边亮带；展开到收起途中同理脱节。BUG-3132 的测试只断言了 `solidHeight`，没断言遮罩顶边位置，所以漏了。
- **[x] ① 已修复** — 嵌套层遮罩顶边改为外层可见下沿 `outer * shown`（同一弹簧），完全收起（shown≤0.001）时嵌套层不画；顶边那条短渐隐仍由最外层负责。展开态位置不变，BUG-3132 的覆盖不退化。共享组件，书架 / 漫画库 / 视频库同时生效；遮罩与设计系统（MD3 / Apple）无关，颜色仍取 `fushiTopFadeScrimColor`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_library_test.dart`：「工具区收起后没有遮罩段悬在内容中间」（修复前实测顶边 56 > 1 失败）、「嵌套遮罩顶边始终接在外层可见下沿」（弹回逐帧）。
- **备注**：未做 Windows 真机复测。#6ixTuvHysg「遮罩没去掉」按同一路径（再次收起后停在收起态）判为同根因，无独立截图。
