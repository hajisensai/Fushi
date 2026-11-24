## BUG-5369 · lyric-visualizer-style-desc-truncated
- **报告**：2026-11-24（用户，应用内反馈 MBFpXNlnMK：歌词页顶栏「歌词动画样式」面板里，商籁、心象、浮名等卡片的说明被截成两行加省略号，显示不全）
- **真实性**：✅ 真 bug。BUG-5355 修了「说明被上下裁」后，样式卡高度 `lyricVisualizerStyleTileExtent`（`fushi/lib/src/pages/implementations/music/music_lyric_visualizer_view.dart` 修前 680-699 行）只量「图标行 + 标题一行 + 说明两行」，说明 `Text` 又写死 `maxLines: 2` + 省略号（修前 775 行）；多数样式说明在 `maxCrossAxisExtent: 220` 的列宽里要排 3～4 行，于是被截断。
- **[x] ① 已修复** — 选择面板的网格包进 `LayoutBuilder`，`lyricVisualizerStyleTileExtent(context, entries:, gridWidth:)`（同文件 692 行）按 `lyricVisualizerStyleTileWidth`（与 `SliverGridDelegateWithMaxCrossAxisExtent` 同一分列算法）算出的实际列宽，把每张卡的标题 + 说明完整排版一次（含系统字号放大、locale、DefaultTextStyle），取最高那张定 `mainAxisExtent`；标题与说明都去掉 `maxLines` / 省略号（同文件 811 行）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/visualizer/lyric_visualizer_host_layout_test.dart`：宽窗 1280 / 窄窗 420 × 字号 1.0 / 1.3，滚过全部 18 种样式，逐张断言说明 `didExceedMaxLines == false`、高度不小于固有高度、无溢出异常。
- **备注**：委托说明里把上一版写成 BUG-5337，实际是 BUG-5355（BUG-5337 是漫画音频包导入）。
