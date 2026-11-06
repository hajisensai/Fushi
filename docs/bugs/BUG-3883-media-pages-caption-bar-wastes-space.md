## BUG-3883 · media-pages-caption-bar-wastes-space
- **报告**：2026-10-30（用户：用户：顶栏条只有在应用外才显示，视频 / 小说 / 漫画 / 音乐默认占满）
- **真实性**：✅ 体验缺陷。`fushi/lib/src/utils/components/fushi_desktop_title_bar.dart` 对沉浸页（上报了 `FushiTitleBarColorScope` 的页面）仍把内容整体下移一条顶栏高度，媒体页顶部白占一条。
- **[x] ① 已修复** — Windows / Linux 上沉浸页铺满整窗（`immersivePagesFillWindow`），顶栏改为悬停 / 聚焦才淡入（`_ImmersiveCaptionReveal`，透明底 + 页面底色光晕）；页面经 `MediaQuery.padding.top` 仍知道顶栏占位，悬浮胶囊排在窗口按钮下面（视频 `controls_theme.part.dart` / `video_subtitle_style.dart` 加 `immersiveCaptionInset`），小说正文用 `_contentTopInset` 扣掉这一段、拿到更多显示面积；歌词页也上报配色。macOS 维持原样。
- **[x] ② 已加自动化测试** — `fushi/test/desktop/fushi_title_bar_page_colors_test.dart`「Windows 沉浸页」组（页面从窗口顶端铺起、padding 仍为顶栏让位、标题行透明、悬停才显示、普通页常显）；旧的「标题行画上报底色」与歌词接缝契约改钉 macOS 宿主（`lyrics_player_title_bar_seam_test.dart` 另加 Windows 不让位断言）。
- **备注**：Windows 调试实例上人工确认过；macOS 未改未验。
