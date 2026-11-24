## BUG-5348 · 歌词页开着时关掉「有 MV 时背景放 MV」，MV 照放不停
- **报告**：2026-11-23（合并 #4249 后补设置效果测试时发现）
- **真实性**：✅ 真 bug（效果测试复现：关掉开关后解析器订阅没退、`source` 不变）。根因 `fushi/lib/src/pages/implementations/music/music_lyrics_mv_backdrop.dart` 的 `enabled` setter：微任务里先把 `_trackUid` 清成 null 再调 `_onEngine()`；关掉时目标曲目也是 null，去重判断 `uid == _trackUid`（null == null）直接返回，旧的画面订阅、正在放的 MV 和远端画面票都留着。打开方向没问题（目标是当前曲目，≠ null）。
- **[x] ① 已修复** — `_onEngine({bool force = false})`，setter 走 `_onEngine(force: true)` 强制重算，不再靠清 `_trackUid` 绕过去重；引擎监听照旧走默认的去重。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music_lyrics_mv_backdrop_setting_effect_test.dart`「关掉即退订，再打开重新订阅当前曲目」（同时是该设置在 settings_schema_coverage_test 的效果证据）。
- **备注**：同一轮修了 #4249 带进 develop 的歌词页测试卡死（卸载时 drift watch 退订排的零延时 timer，`music_lyrics_page_test.dart` 的 `unmountPage`）。
