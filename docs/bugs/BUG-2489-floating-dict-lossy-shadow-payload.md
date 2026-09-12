## BUG-2489 · floating-dict-lossy-shadow-payload
- **报告**：2026-09-13（用户：从 BUG-2488「手机 app 外没有单词音频」追根时发现）
- **真实性**：✅ 真 bug。Android 悬浮词典（`fushi/android/app/src/main/java/app/fushi/reader/FloatingDictService.java`）是词典管线的**有损影子副本**：`FloatingDictChannel._handleNativeCall`（`fushi/lib/src/media/floating_dict_channel.dart` `searchTerm` 分支）把 `DictionarySearchResult` 降维成 `{word, reading, meaning明文}` 交给 Java，`FloatingDictService.onSearchResult` 只把第 0 条存进 `currentWord/currentReading/currentMeaning`，`exportToAnki()` 再把这三个字符串送回 Dart 拼 payload。后果：制卡永远只能制第一条词条、`{sentence}` 恒空（`AnkiMiningContext(sentence: '')`，明明选中文本/剪贴板全文就在窗口里）、无音调/词频/`{glossary}` HTML/外字、不查重。BUG-2488 只补了单词音频。
- **[ ] ① 未修复** — 方向：原生窗口不再持有降维副本——Dart 侧保留最近一次 `DictionarySearchResult`，Java 按词条索引回 Dart 制卡，制卡上下文带窗口里的原文作 sentence；或整窗换成与 `PopupDictionaryPage` 同一份 popup.js WebView（一步到位，但要动 overlay 窗口宿主）。
- **[ ] ② 未加自动化测试** —
- **备注**：与 BUG-2488 同根因、不同症状，拆开是因为 2488 五行能收，这条要动 Java↔Dart 契约。
