## BUG-4256 · 首页「继续」并排封面行：方向待探测的视频卡解出横图后悬停放大，左缘被视口裁掉
- **报告**：2026-11-09（用户：应用内反馈 me_DAkqFJ_，Windows 3.3.0-debug.24651，截图为首页 dashboard「继续」区，悬停放大的横版剧照卡标题首字被裁）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_continue_hero.dart` `FushiContinueSpotlight._sideRow`（`widest` 计算）：横向悬停留白 `widest * (scale - 1) / 2` 按条目声明的 `coverAspectRatio` 取最大值；首页视频条目声明竖海报比例（`home_dashboard_page.dart` `homeContinuePortraitAspect`）并带 `orientationImage`，解码出横图后 `_EntryAspectProbe` 经 `_oriented` 把条目换成 16:9，`FushiContinueSideTile` 按 16:9 定卡宽，实际卡宽约为留白计算值的 2.7 倍，放大 `kFushiHoverLiftScale` 的溢出超过 ListView 横向 padding，被视口 hardEdge 裁掉。同文件已有的 `layoutAspectRatio`（探测前按 16:9 保守留、探测后按实测）`_sideRow` 没用。同族：BUG-3882（修的是 `FushiContinueCardRow`）。
- **[x] ① 已修复** — `_sideRow` 的 `widest` 改按 `FushiContinueEntry.layoutAspectRatio` 取最大值。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_continue_spotlight_test.dart`「方向待探测的条目解出横图：悬停放大后的首张卡整张留在视口内」：竖图声明 + `CoverProbeMemo` 预记横图，鼠标悬停首张封面行卡，断言放大后左右缘在 ListView 视口内（修复前左缘 652.77 < 视口 659.99，红）。
- **备注**：单行封面高封顶判据（`side.any((e) => e.still)`）与 `_sideAllStill` 仍按声明比例判，探测为横图的条目在全竖声明行里不封顶、行数 / 文字块形态也不变；是否改按实测方向属于布局取舍，未动。未在 Windows 真机肉眼复测。
