## BUG-2262 · 墨水屏开关不通知阅读器重注入正文样式
- **报告**：2026-09-08（用户：同 BUG-2261「外观设置不能点完立马生效」排查顺带）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/settings/settings_schema_appearance.dart:79`（`appearance.eink_mode` 的 `onChanged` 只 `settingsContext.refresh()`，不发 `notifyReaderSettingsChanged`），而 `einkMode` 是正文 CSS 的入参（`reader_fushi_page.dart:3381` `ReaderContentStyles.css(einkMode: appModel.einkMode)`）。开着书切墨水屏，Flutter 层主题立即翻转，WebView 正文要退出重进才变黑白。
- **[x] ① 已修复** — `onChanged` 改调 `notifyReaderSettingsChanged(settingsContext)`（含 refresh），走与字号/主题同一条 `onSettingsChangedLive` → `_applyStylesLive` 实时重注入链。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_eink_mode_test.dart` 新增源码守卫：`appearance.eink_mode` 的 onChanged 体内必须调用 `notifyReaderSettingsChanged`。
- **备注**：
