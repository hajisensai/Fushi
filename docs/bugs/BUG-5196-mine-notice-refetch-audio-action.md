## BUG-5196 · mine-notice-refetch-audio-action
- **报告**：2026-11-22（用户要求制卡提示重做「顺便把重做做了」，设计图里「已制卡，缺单词音频」的结果卡带「补音频」按钮；BUG-5195 同批落地了其余动作，这一项未做）
- **真实性**：✅ 缺口真实存在。「补音频」需要只重取并写回单词音频字段，但后端没有窄接口：`packages/fushi_anki/lib/src/base_anki_repository.dart:171` `updateMinedNote` 是整卡覆写（AnkiConnect `ankiconnect_repository.dart:725` / AnkiDroid `ankidroid/anki_repository.dart:491` / 复习同口径），拿制卡当时的载荷再覆写一遍会冲掉用户在 Anki 里对这张卡做过的手改，风险大于收益。
- **[ ] ① 未修复** — 还缺：`BaseAnkiRepository` 加一个只更新指定字段（单词音频）的窄操作（AnkiConnect `updateNoteFields` 只带音频字段 + `storeMediaFile`；AnkiDroid ContentProvider 读改写单字段；复习走 Rust 核心单字段更新），再由 `mineResultToastAction`（`fushi/lib/src/anki/mined_card_undo.dart`）在 `addedWithWarning` 且 `outcome.audioWarning` 非空时给「补音频」。
- **[ ] ② 未加自动化测试** — 落地时加：三后端各自的单字段更新测试 + 结果卡动作选择测试。
- **备注**：现状下缺音频的结果卡会说清缺失原因（`describeMineOutcome` 的 detail），并可展开看完整原因、复制。
