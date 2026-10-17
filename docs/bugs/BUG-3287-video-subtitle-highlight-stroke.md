## BUG-3287 · 视频字幕查词高亮底色盖不住 .ass 描边
- **报告**：2026-10-12（反馈 #D54jhFJewR，Windows：「查词的查词背景没覆盖全文字，可能是文字的边框加粗导致」；日志显示在视频播放页）
- **真实性**：✅ 真 bug。宿主是视频字幕 overlay（尊重 .ass 样式 + 带 `\bord`/`Outline` 描边的 cue）。`fushi/lib/src/media/video/video_subtitle_overlay.dart` 的 `_buildCueBox` 把描边与填充分成整行两遍（描边遍整行垫底、填充遍整行压顶），而查词高亮 `SubtitleLookupHighlightBox` 只挂在**填充遍**的字上，且只铺字位布局盒（advance × 行高）。两层后果：① 盒内的描边被压在半透明底色之下的填充遍之下——底色在描边之上；② 描边按 `strokeWidth/2` 向外扩出布局盒，盒外那圈描边完全不在高亮里。阅读器 / 弹窗内嵌套查词 / galgame 浮窗的高亮都是浏览器原生绘制，没有描边层，不受影响。
- **[x] ① 已修复** — 高亮改由描边遍（最底层）画：底色 < 描边 < 填充；底色按该字描边可见宽（`_resolveStroke(...).$2 / 2`，与描边同一时刻取值）外扩：上下每字外扩，左右只在区间首 / 尾外扩（中间相接处不叠出深色接缝）。`SubtitleLookupHighlightBox` 改为 `CustomPaint` 只画不占位，布局几何零变化。提交 `6718b37cf6`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_lookup_highlight_test.dart`：带描边 cue 的高亮盒只包描边遍的字、外扩 = strokeWidth/2、首尾 / 中间外扩形状；不尊重 .ass 时不外扩。
- **备注**：Windows 真机未复测；`\fscx` 压宽时布局盒比字形窄，外扩仍按布局盒算（病态少见，未处理）。
