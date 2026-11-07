## BUG-4227 · anki-source-link-mine-missing-original
- **报告**：2026-10-17（GitHub #2296，Windows · Anki 26.09 + AnkiConnect · Lapis 笔记类型）
- **真实性**：✅ 真 bug（两处缺陷）
  1. 原卡查找：`packages/fushi_anki/lib/src/card_source_link.dart` 的 `searchQueryForSourceId` 原为不限定字段的 `sourceId=<uuid>`（AnkiConnect `findNotes` 与 AnkiDroid ContentProvider `AnkiChannelHandler.findNotesBySourceId` 同一查询）。Anki 的未限定搜索会跳过设了「不参与未限定字段的搜索」（`excludeFromSearch`）的字段，链接所在字段这样配置时 `findNotes` 返回 0 条，`BaseAnkiRepository.readSourceNote` 返回 null，`SourceReviewSession._readOriginal`（`fushi/lib/src/anki/source_review_session.dart:112`）抛「找不到原卡」。已在 Anki 26.09.4 后端（pip `anki` 包，真实 rslib）实测：默认配置旧/新查询都命中 1 条；把链接字段设为 excludeFromSearch 后旧查询 0 条、`*:*sourceId=<uuid>*` 仍 1 条。用户本机 Lapis 的 MiscInfo 是否开了该选项未能核实（推测）。
  2. 草稿锁：`SourceReviewSession.mine` 先 `saveMining` 落盘草稿再读原卡，原卡确定不存在时草稿仍保留；该草稿 `resumeDraft` 必再失败，之后对同一来源的每次制卡都被 `_canStartEdit` 以「已有未提交草稿」拒绝。
- **[x] ① 已修复** — 候选查询改为 `*:*sourceId=<uuid>*`（字段限定不受 excludeFromSearch 影响，身份仍靠解析 href 精确比对）；`mine()` 先读原卡：后端没能回答（离线 / Anki 未开）才保留草稿，确定不存在直接返回「找不到原卡」且不写草稿。
- **[x] ② 已加自动化测试** — `fushi/test/anki/source_review_session_test.dart`「missing original leaves no draft and does not block the next mining (BUG-4227)」；`packages/fushi_anki/test/card_source_link_test.dart`（AnkiConnect wire 查询串契约）；`fushi/test/platform/source_url_native_contract_test.dart`（Android 查询串同步）。
- **备注**：未在用户真实 Anki + Lapis 卡上复测；Anki 侧机制用 Anki 26.09.4 后端脚本实测。已存在的旧失败草稿需用户在横幅点「丢弃草稿」一次。
