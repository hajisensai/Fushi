## BUG-954 · 非外部窗口模式制卡 sentence 字段恒空
- **报告**：2026-07-21（PR#295 落地审查 H5，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:118-126`：非外部窗口模式（含全部非 Windows 路径）制卡 fallback 未注入 `sentence`，in-app popup payload 也不带该字段，挖出的卡 `{sentence}` 恒为空；`_activeSentence`（:62,:409-413）只写不读是漏接实证；`onUpdateEntry`（:129-140）同病。
- **[x] ① 已修复** — 抽顶层可测函数 `injectActiveSentence(fields, activeSentence)`（`texthooker_page.dart`，@visibleForTesting），`onMineEntry`/`onUpdateEntry` 的 fallback 分支改走 `super.onXxx(injectActiveSentence(fields, _activeSentence))`：仅在 fields 未自带非空 sentence 且有活跃台词时注入，不覆盖调用方句子。
- **[x] ② 已加自动化测试** — `test/pages/texthooker_page_test.dart` 的 `injectActiveSentence` 单测组：无 sentence+有活跃台词→注入、已有 sentence→不覆盖、null/空串→原样。
- **备注**：
