## BUG-5531 · srs-export-filtered-review-ease-zero
- **报告**：2026-11-26（内部审查：捐赠导出修了筛选牌组评分，普通导出仍丢）
- **真实性**：✅ 真 bug。根因 `packages/fushi_engine/lib/srs/apkg/srs_apkg_export.dart` 的 `_revlogEase`（原 :661）用 `l.isRatingReview`，而 `SrsReviewType.rating` 只含 learn/review/relearn，导入的 Anki 筛选牌组复习（revlog type 3，ease 1–4，kind 仍是 review）被写成 ease 0（Anki 里 ease 0 = 手动改期）；捐赠包另有 `redaction != null` 特例，两套口径。Anki → Fushi → Anki 往返丢这些复习的评分。
- **[x] ① 已修复** — `_revlogEase` 改为 `kind == review ? (rating ?? 0) : 0`，普通导出与捐赠包共用一条规则，删掉捐赠专属特例。导入侧对 type 3 ease 0 记 rating=null，仍写回 0。提交见本分支 `fix(srs): 普通导出保留筛选牌组复习评分`。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/srs_apkg_export_filtered_ease_test.dart`（往返：type 3 ease 2 保留、type 3 ease 0 与手动仍为 0；修前红 `(3,0)`、修后绿）；`srs_donation_export_test.dart` 原有筛选牌组断言同绿。
- **备注**：纯引擎层，无 UI / 设备复测项。
