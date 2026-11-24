## BUG-5385 · 有声书插图大图浏览打开期间新走过的插图看不到（只列已听到的、且不随播放刷新）
- **报告**：2026-11-24（维护者应用内反馈 wV1kvoLjI3，Android 歌词模式插图大图浏览「16 / 16」：「少了图片，后面的图片有一张新出现，但是这里竟然没有；就算没出现也应该在这里显示，默认遮罩」）
- **真实性**：✅ 真 bug。截图里大图停在第 16 张（四章标题页），左下小封面缩略图却已换成另一张深色插图——插图位已换上新走过的那张，浏览里没有它。根因两层：
  1. 大图浏览 `_LyricsIllustrationViewerState` 不监听状态机：总数 `_count => controller.reached + 1`（旧 `fushi/lib/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart:782`）只在本页自己 setState 时重读，`PageView.itemCount` 与「下一张」按钮都停在打开那一刻的已听到范围。浏览期间音频照常播放（`_openLyricsIllustrationViewer` 注释），`LyricsIllustrationController.observe` 推进 `reached`、把插图位换成新插图，浏览页不知道。
  2. 设计上浏览只列 `0..reached`（旧 `lyrics_illustrations.dart:350-352` 注释、`canShowNext` 的 `index < _reached`、`showLyricsIllustrationViewer` 的 `clamp(0, reached)`、计数 `reached + 1`），没听到的插图完全不出现——维护者要求列出全部、未听到的遮罩。
- **[x] ① 已修复** — 大图浏览列出全书插图（`_count = items.length`），并 `addListener` 监听状态机，已听到范围 / 揭开状态一变就重画；未听到又没揭开过的页（`LyricsIllustrationController.isLocked`）盖 `maskedIllustrationCover` 模糊遮罩（与阅读器插图册同一套），点一下 / Enter 揭开（`reveal`），揭开经 `onReveal` 写回阅读器 `revealed_images`（`_markReaderImageRevealed`，插图册「仍要查看」同一条），`load(revealed:)` 以阅读器已揭开集为种子。插图位 / 缩略图只放已解锁的插图（`showAt` 不放未解锁的，翻页跳过未解锁的），不剧透；插图卡与封面胶囊计数改为全书插图数。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_illustration_view_test.dart`「大图浏览打开期间播放走过新插图：那一页当场解锁」「列出全部插图，未听到的遮着、点一下揭开」「遮着的页按 Enter 揭开」；`fushi/test/media/audiobook/lyrics_illustrations_test.dart`「未解锁 = 没听到且没揭开…」「往回 seek：揭开过的插图留在插图位」。
- **备注**：待真机（Android 歌词模式）复测：浏览中播放走过新插图那一页即时解锁；未听到页遮罩 + 点开。
