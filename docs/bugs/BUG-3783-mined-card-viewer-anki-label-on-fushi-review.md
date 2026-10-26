## BUG-3783 · mined-card-viewer-anki-label-on-fushi-review
- **报告**：2026-10-26（用户：制完卡「已存在的卡片」里，卡用的是 Fushi 复习也显示「在 Anki 中打开」）
- **真实性**：✅ 真 bug。`fushi/lib/src/anki/anki_mined_card_action_sheet.dart` 的已有卡对话框与 note viewer 把标题「卡片已在 Anki 中」、行尾「查看 / 在 Anki 中打开」、按钮「在 Anki 中打开」、打开失败提示全部写死成 Anki；仓库层 `BaseAnkiRepository` 没有任何「卡住在哪 / 能否按 id 打开」的声明，制卡落点是 Fushi 复习（`SrsMiningAnkiRepository.openNoteInAnki`，`fushi/lib/src/srs/srs_mining.dart`，实际打开的是复习笔记）时界面照样说 Anki；远端制卡 / AnkiMobile 等根本打不开笔记的后端也照样露出必然失败的「打开」按钮。
- **[x] ① 已修复** — `BaseAnkiRepository` 新增 `minedNoteHome`（`MinedNoteHome { anki, fushiReview }`，`packages/fushi_anki/lib/src/anki_models.dart`）与 `canOpenMinedNote`（默认 false，与默认 `openNoteInAnki` 恒 false 同步）；AnkiConnect / AnkiDroid 声明可打开，`DelegatingAnkiRepository` 透传，`SrsMiningAnkiRepository` 声明住在 Fushi 复习、有打开器才可打开。对话框按二者选文案，不能打开不出按钮。
- **[x] ② 已加自动化测试** — `fushi/test/anki/anki_note_viewer_backend_label_test.dart`（Fushi 复习 / Anki / 打不开三种后端的按钮文案与可见性）。
- **备注**：查词弹窗 ↗ 按钮（popup.js 的「在 Anki 中打开」提示）不在本次范围。
