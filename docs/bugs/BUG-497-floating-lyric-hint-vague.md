## BUG-497 · 悬浮字幕设置描述文案含糊
- **报告**：2026-07-01（用户：TODO-1072）
- **真实性**：✅ 真 bug — 根因 i18n key `floating_lyric_hint`（`hibiki/lib/i18n/strings.i18n.json:600` en / `hibiki/lib/i18n/strings_zh-CN.i18n.json:600` zh），复用于 `settings_schema_listening.dart:48` 开关 subtitle 与 `:13` Listening summary。原文 en「Show current sentence over other apps.」zh「在其他应用上方显示当前句子。」含糊。
- **[x] ① 已修复** — 改为 en「Float the currently playing subtitle line on top of other apps.」zh「将当前播放的字幕句悬浮显示在其他应用之上。」直接改两个源 JSON 值后 `dart run slang` 重生成 `strings.g.dart` + `dart format`；17 语言 key 完整性不破坏。提交见分支 `fix-1069-floating-lyric-settings`。
- **[x] ② 已加自动化测试** — `hibiki/test/settings/floating_lyric_settings_liveupdate_test.dart`：i18n 值守卫断言 en/zh 新文案存在（源 JSON + 生成文件）、旧含糊文案已不复存在（防回退）。
- **备注**：仅更新 en/zh 值；其余 15 语言保留原译（Slang 只要求 key 完整）。
