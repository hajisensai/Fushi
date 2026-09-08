## BUG-2326 · 歌词模式没有顶栏，也没有回到阅读模式的入口
- **报告**：2026-09-09（用户：hajisensai）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_desktop_chrome.dart:39`（旧
  `readerDesktopChromeEnabled` 直接委托给 `readerStatusFooterEnabled`，判据 `!lyricsMode`）
  → `fushi/lib/src/pages/implementations/reader_fushi_page.dart:1941` 的
  `_desktopChromeEnabled` 在歌词模式恒 false → `chrome.part.dart:2115` 的
  `_buildDesktopHeader` 整条早返回。
  两个后果连在一起：
  1. 顶栏（返回 / 目录 / 插图 / 统计 / 有声书 / 全屏 / 设置）在歌词模式整条不画；
  2. 「切回阅读模式」的开关只住在这套 chrome 的设置抽屉里
     （`reader_quick_settings_sheet.dart` 的排版页），顶栏一没，歌词模式就没有任何
     可见的回正文入口——只剩播放条上的齿轮那一条隐蔽路径。
  另有一笔几何差：歌词页是独立 HTML（`LyricsModeHtml`），`_applyChromeInsets` 对它
  整体早返回，留白只能由 Flutter 侧给；`independentDocumentInsets` 当时只给底部留白，
  顶部恒 0 → 文档从 y=0 起画，系统状态栏 / 刘海直接压在首行歌词上。
- **[x] ① 已修复** — `_desktopChromeEnabled` 不再随 `_lyricsMode` 翻转（顶栏两种模式都
  在场，动作按模式取舍：导航 / 插图只在正文模式挂，歌词模式换成一颗 pinned 的
  「歌词 ⇄ 阅读」模式键）；`independentDocumentInsets` 增加 `topReserve`，由
  `_lyricsTopReserve`（系统顶 inset + 顶栏预留，不含歌词模式不画的进度 pill 预留）喂入。
  底部状态行仍留在歌词模式之外——`_refreshProgress` 在歌词模式整体早返回，画出来会是
  冻住的旧数；并进播放条右端的那份状态文字（`_playbackStatusInline` /
  `_separatePlaybackStatus`）同理改挂 `_statusFooterEnabled`。
- **[x] ② 已加自动化测试** —
  `fushi/test/pages/reader_lyrics_top_chrome_static_test.dart`（顶栏判据不再随歌词模式
  翻转 / 顶栏挂 pinned 模式键 / 留白接线）、
  `fushi/test/pages/reader_lyrics_progress_bottom_reserve_static_test.dart`（顶部留白的
  行为断言）、`fushi/test/reader/reader_desktop_chrome_test.dart`（pinned 动作在紧凑形态
  仍是可见按钮）、`fushi/integration_test/reader_lyrics_mode_entry_itest.dart`（真 app：
  进歌词模式 → 唤出 chrome → 顶栏与模式键在场 → 按下去真切回正文）。
- **真机证据**：Windows 离屏 runner（`fushi/tool/run_windows_itest.ps1`）跑
  `reader_lyrics_mode_entry_itest.dart` 通过（exit 0，`All tests passed`）：种一本有声书 →
  进歌词模式 → 走生产唤出路径（歌词页空白点击桥 `onLyricsTapEmpty`）→ 顶栏
  `fushi_desktop_header` 与播放条 `fushi_play_bar` 同时在场 → 顶栏模式键按下去后
  `lyricsMode` 落回 false、正文重新就绪。
- **备注**：三处顺带修的既有问题（都会让上面那条真机验证跑不到本 bug 的断言）：
  ① `reader_desktop_chrome_test.dart` 里「顶栏自带 RepaintBoundary」的守卫原来切「方法
  签名后 900 字符」的定长窗口，往方法开头加几行就假红，改成取整个方法体（`methodBody`）；
  ② 该集成测试按 focus-id 前缀 `reader-action` 找歌词开关，而设置面改成右侧抽屉后那颗
  开关的焦点目标前缀已是 `settings-row`——**修本 bug 之前该测试就卡在这一步**（已在
  upstream/develop 基线上复现），改成不钉前缀、只要求「是个能接 ActivateIntent 的具体
  焦点停靠点」；③ 首次进歌词模式的一次性提示对话框是一层吃指针的模态，会把对顶栏的
  点击吸走，测试里把 `lyrics_mode_hint_shown` 预置成已看过。
