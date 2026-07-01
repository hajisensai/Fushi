## BUG-495 · 悬浮字幕字号改值不即时生效
- **报告**：2026-07-01（用户：TODO-1069）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/settings/settings_schema_listening.dart:75`（悬浮字幕字号 stepper 的 onChanged 只 `setFloatingLyricFontSize`(写 pref) + `refresh()`，漏了 `audiobookSession.applyFloatingLyricStyle()`。该方法 `hibiki/lib/src/media/audiobook/audiobook_session.dart:458` 把整支 style（含 fontSize）经 `FloatingLyricChannel.updateStyle` 推给原生悬浮窗。同文件透明度三项每项都调了它 → 所以改透明度才顺带把字号推过去，单改字号不生效。
- **[x] ① 已修复** — 字号 onChanged 补 `applyFloatingLyricStyle()` 调用，与透明度三项对齐（`settings_schema_listening.dart` 字号 stepper onChanged）。提交见分支 `fix-1069-floating-lyric-settings`。
- **[x] ② 已加自动化测试** — `hibiki/test/settings/floating_lyric_settings_liveupdate_test.dart`：源码守卫断言字号 onChanged 在写 pref 后调 `applyFloatingLyricStyle()`。
- **备注**：与 BUG-496 同源三修的一部分（TODO-1069/1070/1072）。
