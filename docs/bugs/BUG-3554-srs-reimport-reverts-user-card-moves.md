## BUG-3554 · 复习：重新导入 / 迁移 Anki 把用户在 Fushi 里挪过牌组 / 暂停过的卡改回 Anki 的状态
- **报告**：2026-10-19（PR #2336 审查遗留，协调要求根本性修复）
- **真实性**：✅ 真 bug，测试复现：导入后在 Fushi 里挪牌组、暂停，再导入笔记内容更新过的同一份集合，卡被挪回 Anki 牌组、取消暂停。根因（修前）`packages/fushi_engine/lib/srs/apkg/srs_apkg_import.dart` `_importCardFlags` 对已有卡片在笔记要更新时无条件 `moveCard` / `setSuspended`，不看本机改动时刻。
- **[x] ① 已修复** — 已有卡片的牌组 / 暂停：按该键修改记录的最后时刻与 Anki 卡片 `mod` 比，本机较新则不覆盖（同 Anki 导入对已有卡片「较新时更新」；与 Lapis 补迁同属「按修改记录判断用户动过」）。卡片 SELECT 加 `mod`，`SrsDbStore.entityEdits` 公开只读。
- **[x] ② 已加自动化测试** — `srs_apkg_import_test.dart`「更新笔记时已有卡片：本机在来源卡片之后挪过牌组 / 暂停过的不改回」（卡片 mod 早于 / 晚于本机改动两种）；变异实测：判据恒 false，测试红。
- **备注**：
