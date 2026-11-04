## BUG-4004 · 复习卡正面例句不高亮目标词
- **报告**：2026-11-04（用户：应用内反馈 VbJo0Y7S0A「SRS 卡片例句里没有高亮目标词」）
- **真实性**：✅ 真 bug。内置「Fushi 卡片」走原生卡面 `SrsFushiCardView`；正面例句 `_frontSentence`（修前 `fushi/lib/src/pages/implementations/srs/srs_fushi_card_view.dart:593`）把 `Sentence` 字段经 `srsKanaFree` 变成纯文本直接画，字段里的 `<b>` 目标词标记（制卡写入，模板 CSS `.fc-front-sentence b` / `.fc-front-context b` 据此高亮，`packages/fushi_anki/lib/src/fushi_card_template_data.dart:783`）被丢掉；背面例句走 `srsEmphasizeSentenceTarget`，正面没有，两面口径不一。
- **[x] ① 已修复** — 正反面共用 `_sentenceSegments()`：`srsClozeToBold` → `srsParseInline` → `srsEmphasizeSentenceTarget(marked: srsMarkedTargets, terms: Term / TermFurigana 假名 / TermReading)`；正面去掉注音（`withoutRuby`）后按 `scheme.primary` 加粗着色，听力卡（masked）仍是 `［…］` 遮住。提交 `b971fbd9e2`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_fushi_card_view_test.dart`（例句卡 `<b>` 目标词加粗着色且不带注音；词 + 例句卡字段里没有 `<b>` 时按 Term 定位；听力卡仍遮住）。
- **备注**：未做真机 / 桌面肉眼复测。
