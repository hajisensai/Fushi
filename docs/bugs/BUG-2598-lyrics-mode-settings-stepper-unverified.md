## BUG-2598 · 歌词模式「阅读设置调节按钮不生效」——Windows 真机未复现
- **报告**：2026-09-19（用户：「阅读设置调节按钮不生效」，与 BUG-2596 同一条反馈）
- **真实性**：❌ 未复现（Windows 离屏 runner，`win-itest-20260919-134250` 基线跑）。沿真实链路：设置抽屉「布局显示」在歌词模式渲染 `_buildLyricsDisplaySection`（`reader_quick_settings_sheet.dart`），歌词字号 stepper `onChanged → ReaderFushiSource.setLyricsFontSize`（`ReaderSettings._set` 先同步写缓存）→ `onStyleChanged = _applyStylesLive` → `_lyricsMode` 分支 `_updateLyricsStyleLive` → `__lyricsUpdateStyle` 改 `--cue-font-size` + `__lyricsFitCues`。集成测试用方向键把 stepper 推两步，WebView 的 `--cue-font-size` 从 24px 变 26px，通过。
- **[ ] ① 未修复** — 未复现，无根因可修。待用户补：平台（iOS / Android / Windows）、动的是哪一行（字号 / 边距 / 竖排 / 模糊 / 文字色 / 主题）、是否用了自定义正文字体、是否在竖排歌词下。
- **[x] ② 已加自动化测试** — `fushi/integration_test/reader_lyrics_settings_and_chapter_nav_itest.dart` ①：歌词模式打开设置抽屉、焦点驱动推歌词字号 stepper、断言 WebView 变量跟到新值，作为这条链路的常驻真机门。
- **备注**：若用户指的是「行为 / 查词」两页的正文设置在歌词模式看不到效果——那两页写的是正文偏好，歌词页本就不消费，退回正文时经 `_exitLyricsMode → _navigateToChapter` 整章重载后生效，属预期。
