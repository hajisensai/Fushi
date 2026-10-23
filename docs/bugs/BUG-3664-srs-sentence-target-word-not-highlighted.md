## BUG-3664 · 例句中目标词不高亮
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：例句中的目标词不高亮。
- **真实性**：✅ 真 bug。根因：只有 `<b>` 段上有强调色（`srs_fushi_card_view.dart` `SrsRubyText._styleOf`）；制卡仅在逐字一致时才写 `<b>`（`packages/fushi_anki/lib/src/anki_models.dart` 约 1182 行）。迁移卡、SentenceFurigana、挖空无标记的卡因此没有高亮。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_feedback_test.dart`
- **备注**：无。
