## BUG-3887 · apkg-reimport-deleted-notes-changed-notetype
- **报告**：2026-10-30（用户：应用内反馈，导入 `日本語1.apkg` 报「10946 notes were not imported because their note type conflicts」，删了再导也不行）
- **真实性**：✅ 真 bug。用户在 Anki 里把一批笔记「更改笔记类型」成 Kiku（guid 不变），Fushi 本机同 guid 的笔记仍挂在旧类型（Core）下。本机笔记还在时按 Anki 规则记 `noteTypeChanged` 冲突跳过属预期；但 `packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart` `_importNote` 里「本机笔记类型不同 → 冲突跳过」排在「本机已删 → 恢复」之前，用户在 Fushi 删掉这批笔记后再导入照样被拦，永远导不回来。另：报告只给总数，不说哪个笔记类型、什么原因（`fushi/lib/src/srs/srs_import_entry.dart`）。
- **[x] ① 已修复** — 本机已删的笔记在类型不同时按来源类型恢复（同一次 `editFields` 写 `noteType` 键 + 来源字段 + 清删除标记）；报告按（原因, 笔记类型）分行，`noteTypeChanged` 行写明类型名与「在浏览里更改笔记类型后重导」的做法（i18n 拆成 `srs_import_report_conflicts_type_changed` / `_kind_mismatch` / `_missing_type`）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/srs_apkg_import_test.dart`「来源换了笔记类型…（BUG-3887）」（去掉修复后变红已实测）；`fushi/test/srs/srs_import_entry_test.dart`「冲突笔记按原因与笔记类型分行」。
- **备注**：本机笔记仍在时依旧跳过（与 Anki 一致，不擅自换类型）；用户绕过办法是在浏览里把这批笔记改成来源类型再重导。
