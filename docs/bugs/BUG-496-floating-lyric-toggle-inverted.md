## BUG-496 · 悬浮字幕总开关不即时且与书内翻转显隐反相
- **报告**：2026-07-01（用户：TODO-1069/1070）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/settings/settings_schema_listening.dart:59`（总开关 onChanged 只 `setShowFloatingLyric(value)` + `refresh()` 走旁路，不真正拉起/隐藏原生窗）。更深根因：`show_floating_lyric` pref 被当「用户意图」与「当前窗可见」两语义混用——设置页置位 vs 书内 `AppModel.toggleFloatingLyricFromControls`(`app_model.dart:3431`) 翻转（`!currentlyOn`）并存，且真正即时显隐的入口是 `audiobookSession.toggleFloatingLyric`，设置页没走它 → 开关不即时、进/退书显隐反相。
- **[x] ① 已修复** — 新增语义意图入口 `AppModel.setFloatingLyricEnabled(bool value)`（`app_model.dart`）：置位（非翻转）+ 有会话时经 `toggleFloatingLyric` 原子拉/隐原生窗 + 写意图 pref；拉窗失败（缺 overlay 权限）不写 pref、返回 false。设置页总开关改为委托此入口，废掉裸调 `setShowFloatingLyric` 旁路。退书 `stop()`→`_stopBackgroundSurfaces`(`audiobook_session.dart:366`) 隐窗时不改意图 pref（保持用户意图，供进书 `_startBackgroundSurfaces` 以同一 pref 为唯一门控自动拉起）。提交见分支 `fix-1069-floating-lyric-settings`。
- **[x] ② 已加自动化测试** — `hibiki/test/settings/floating_lyric_settings_liveupdate_test.dart`：守卫断言①设置页开关委托 `setFloatingLyricEnabled`、不再裸写 `setShowFloatingLyric`；②`setFloatingLyricEnabled` 是置位语义（写 value 而非翻转）+ isActive 门控 + 拉窗失败返回 false；③退书 `_stopBackgroundSurfaces` 不改意图 pref。
- **备注**：never-break——无活动会话时仅置意图 pref；overlay 权限门控保留。
