## BUG-954 · 非外部窗口模式制卡 sentence 字段恒空
- **报告**：2026-07-21（PR#295 落地审查 H5，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:118-126`：非外部窗口模式（含全部非 Windows 路径）制卡 fallback 未注入 `sentence`，in-app popup payload 也不带该字段，挖出的卡 `{sentence}` 恒为空；`_activeSentence`（:62,:409-413）只写不读是漏接实证；`onUpdateEntry`（:129-140）同病。
- **[ ] ① 未修复** — 修法方向：fallback/onUpdateEntry 注入 `_activeSentence`。
- **[ ] ② 未加自动化测试** — 现有 overlay_mine_sentence_behavior_test 补非外部窗口路径断言 sentence 非空。
- **备注**：
