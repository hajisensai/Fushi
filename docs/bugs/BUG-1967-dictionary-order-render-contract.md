## BUG-1967 · 词典管理顺序未约束弹窗释义卡顺序
- **报告**：2026-08-30（用户：）
- **真实性**：✅ 真 bug。管理页把顺序写入 `Dictionary.order` 并重建 native 引擎，但 `packages/fushi_dictionary/lib/src/language/language.dart` 的 `buildResultFromLookup` / `buildPopupJsonFromLookup` 直接消费 FFI glossary 顺序，没有把当前管理顺序作为结果契约；暖驻留或独立查词入口拿到旧次序时，弹窗继续按旧次序排卡。
- **[x] ① 已修复** — 两条 Dart 结果生成路径新增显式 `dictionaryOrder`，按当前 term 词典顺序稳定归一 glossary；未知词典保持末尾及原相对次序。`AppModel.searchDictionary` 与紧凑 popup 查询路径都传入当前顺序。
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_order_render_contract_test.dart` 构造 native 旧次序 `wty-en-en → OALDPE`，断言完整结果与 popup JSON 均按管理顺序 `OALDPE → wty-en-en` 输出。
- **备注**：用户要求直接开 PR，不等待测试；提交前仅做格式化、静态 diff/BUG 索引检查，运行态由 PR CI/后续设备验证兜底。
