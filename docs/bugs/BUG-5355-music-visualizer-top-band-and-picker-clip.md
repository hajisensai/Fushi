## BUG-5355 · music-visualizer-top-band-and-picker-clip
- **报告**：2026-11-23（用户：全屏歌词动画顶部露出一条封面背景没覆盖到；「歌词动画样式」面板排版烂、卡片说明字看不全）
- **真实性**：✅ 真 bug。① 歌词页把整块版面包在 `SafeArea` 里（`fushi/lib/src/pages/implementations/music/music_lyrics_page.dart:1742`），沉浸页的桌面顶栏拖动条高度经 `FushiTitleBarDragBandScope` 注入成 MediaQuery 顶部 padding，全屏动画也被一起往下挤，露出下面的封面背景。② 选择面板样式卡写死 `mainAxisExtent: 112`（`fushi/lib/src/pages/implementations/music/music_lyric_visualizer_view.dart` 选择面板 GridView），扣掉内边距和 48dp 图标行后说明只剩十来像素，中文字形上下被裁；面板标题顶边距只有 4。
- **[x] ① 已修复** — 动画开着时 SafeArea 四边都不让位，场景铺满整窗；悬停条与共享字幕按 `MediaQuery.paddingOf` 内缩。样式卡高度改由 `lyricVisualizerStyleTileExtent` 按实际字体行高（含系统字号放大）量出「图标行 + 标题 + 两行说明」；标题顶边距 16。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/visualizer/lyric_visualizer_host_layout_test.dart`（说明两行高度不被压缩 ×1.0 / ×1.3；悬停条按安全区内缩）。
- **备注**：
