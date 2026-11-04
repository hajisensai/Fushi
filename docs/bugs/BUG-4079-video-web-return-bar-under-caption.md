## BUG-4079 · video-web-return-bar-under-caption
- **报告**：2026-11-04（用户：应用内反馈 -TwLAKqRZx，Windows）网页视频页顶栏右端按钮与 Fushi 窗口关闭键重叠
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/video_fushi/web_source.part.dart` `_wrapWebVideoSurface` 的返回条 `Positioned(top: 0, height: 52)`（修前 :1092-1096）画在窗口 y=0，不读 `MediaQuery.padding.top`；视频页是沉浸页，`FushiDesktopTitleBar`（`fushi_desktop_title_bar.dart` 约 :498-545）的标题行浮在页面顶端、只把高度交成页面顶部 padding，页面要自己让开。返回条右端「在浏览器中打开」于是正好压在最小化 / 最大化 / 关闭三键底下；WebView 的 top 偏移同样没算标题行
- **[x] ① 已修复** — 返回条抽成 `fushi/lib/src/media/video/web_video_return_bar.dart` 的 `WebVideoReturnBar`：底色铺到窗口顶端、按钮行排在顶部 padding 下面；总高度 `webVideoReturnBarExtent` = padding.top + 52，WebView 与 OSD 层的 top 同步用它
- **[x] ② 已加自动化测试** — `fushi/test/media/video/web_video_return_bar_test.dart`：Windows 自绘标题栏下断言「在浏览器中打开」矩形与 `closeButtonKey` 不相交、按钮行在标题行以下（修前红：overlaps 为 true）
- **备注**：未做真机 / 模拟器复测
