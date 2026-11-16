## BUG-4710 · Android 横屏手机上卡片来源回看横幅固定两行，占顶部约 1/5 画面高度
- **报告**：2026-11-16（维护者，应用内反馈 m6TVBNxGa9）
- **真实性**：✅ 真 bug。截图是视频页「回看卡片片段」模式：顶部横幅 76dp（154/734 px @ 363dp 高横屏），视频被整体压到下面。根因 `fushi/lib/src/anki/source_review_session.dart:373`（修前）`SourceReviewBanner` 无论窗口多高都是「标题一行 + 按钮一行」的 `Column`：4 + 标题 20 + 按钮 48（padded tap target）+ 4 = 76dp，在 363dp 高的窗口里占掉 21%。另外 `fushi/lib/src/pages/implementations/video_fushi_page.dart:12778`（修前）外面又套了一层 `SafeArea`，横屏刘海那一侧被外层让成横幅底色以外的空白条（截图里横幅两侧的空白）。
- **[x] ① 已修复** — 横幅按 M3 compact height 窗口类（高 < 480dp）切到单行：标题（1 行省略）与按钮条（自身横向滚动）同排、去掉上下 padding，高度 48dp；更高的窗口保持两行。视频页去掉外层重复 `SafeArea`，由横幅自己的 `SafeArea` 让出状态栏 / 刘海。漫画页同一组件自动受益。
- **[x] ② 已加自动化测试** — `fushi/test/anki/source_review_session_test.dart`：`short landscape window folds banner into one row`（792×363 下横幅高 ≤ 48、标题与「返回」同一行；修前红：`Actual: <76.0>`）、`tall window keeps title above the button row`（411×891 保持两行）。
- **备注**：真机未复测（按规则不做）。阅读器页把横幅放进固定高 `_kSourceReviewBannerHeight = 100` 的 `Positioned`，正文排布按该常数预留，本次未改它的几何（横幅在里面单行居中），矮屏阅读器预留高度如需收紧另开一条。
