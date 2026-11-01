## BUG-3930 · 查词弹窗「音调 · N」药丸中文字形混用
- **报告**：2026-11-01（用户：应用内反馈 9GSrEkVLai）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/dictionary_language_css.dart` 弹窗根节点按默认内容语言（日语）建兜底字体链，`fushi/assets/popup/popup.js` `createPitchGroup` 的「音调 · N」药丸是界面语言（中文）文案却无 lang，日文字体缺「调」→ 单字掉到别的字体。
- **[x] ① 已修复** — e9266ac3f1（popup.js `uiText()` 给界面文案节点挂界面语言 lang；Dart 注入 `__fushiUiLanguage`）
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-ui-text-lang.test.js`
- **备注**：未在 Windows 真机肉眼复测。
