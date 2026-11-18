## BUG-4767 · MV / 卡拉 OK 舞台页歌词用 ref.read 读「模糊非当前行」，页面开着时改了偏好不刷新
- **报告**：2026-11-17（PR #3577 审查遗留「非阻塞项 3」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_mv_page.dart` 舞台页 `_app` 是 `ref.read(appProvider)`（原 :415），结构化歌词叠层 `_buildStructured` 里 `KaraokeLyricsAppearance(blurInactive: _app.musicLyricsBlurInactive)`（原 :893）不订阅变化；偏好 setter（`preferences_repository.dart` `setMusicLyricsBlurInactive`）`notifyListeners` 经 AppModel 转发，但舞台页没 watch，页面开着时经 AI 操作 / 其他窗口改了要退出重进才生效。歌词页走 `BaseSourcePageState.appModel`（`ref.watch`）是即时的，两页行为不一致。
- **[x] ① 已修复** — 叠层抽成 `MusicKaraokeStageLyrics`（ConsumerWidget，`music_mv_page.dart:369`），在 build 里 `ref.watch(appProvider.select((AppModel m) => m.musicLyricsBlurInactive))`（:388），只在这一项变化时重建；舞台页 `_buildStructured` 改用它。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_karaoke_stage_lyrics_test.dart`：组件挂着时切换偏好，断言 `KaraokeLyricsView.appearance.blurInactive` 跟着变。
- **备注**：舞台页本身依赖 media_kit `Player`（libmpv），widget 测试里起不来，所以测在抽出的叠层组件上；舞台页全屏实机切换未做真机复测。
