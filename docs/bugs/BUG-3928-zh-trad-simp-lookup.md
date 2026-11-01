## BUG-3928 · 中文词典繁简互查失败：繁体查不到简体词头、独立查词页不开简繁回落
- **报告**：2026-11-01（用户：应用内反馈 3FY6vTqwV-）
- **真实性**：✅ 真 bug。两层根因：(a) `fushi/lib/src/models/app_model.dart:1678` `lookupChineseSimpToTradFor` 只认查词语言，查词页 / 首页从不写 `currentLookupLanguage`，默认内容语言出厂为空 → 独立查词页简→繁回落永远关；(b) `native/fushidicts/fushidicts_src/text_processor/text_processor.cpp` `process()` 只做简→繁（数据也只有 STCharacters），繁→简方向缺失。
- **[x] ① 已修复** — 4d5ce4817a（语言未知时看启用中的 term 词典是否声明中文）、7962eb3059（OpenCC TSCharacters 繁→简，同一 flag 双向展开）
- **[x] ② 已加自动化测试** — `native/fushidicts/tests/chinese_simp_trad_lookup_test.cpp`（之間 ↔ 之间 端到端）、`fushi/test/models/app_model_search_pure_logic_test.dart`、`fushi/test/models/dictionary_lookup_filters_test.dart`
- **备注**：词典包没声明 sourceLanguage 时仍需用户在词典管理里指定语言或设默认内容语言；远端查词服务端判据未跟进；app 内 DLL 待 CI 重编后才生效，未真机复测。
