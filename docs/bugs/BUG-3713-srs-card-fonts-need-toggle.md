## BUG-3713 · SRS 卡片字体需关掉再打开字体设置才生效
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：SRS 卡片字体设置要先关掉再重新打开字体设置才生效。
- **真实性**：✅ 真 bug。根因：`app_model.dart` 启动首帧前只解析 appUi / 字幕 / 游戏三条字体链，漏了 `_srsCardFonts` / `_srsCardFontFamilies`（只在 `refreshAppFont` 填充），首帧无值。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/models/app_font_init_covers_refresh_guard_test.dart`
- **备注**：无。
