## BUG-4087 · 高级制卡在挖词目标为 Fushi 复习时仍列 Anki 牌组、所选牌组不生效
- **报告**：2026-11-04（用户：应用内反馈 0h0e_6fqhY，Android）
- **真实性**：✅ 真 bug。两处根因：
  - `fushi/lib/src/anki/advanced_mining_deck_section.dart:74`（`loadAdvancedMiningDeckSection`）只读 `ankiRepositoryProvider.loadSettings()` 的 `availableDecks` / `selectedDeckId`，不看挖词目标；目标是 Fushi 复习（`srsMiningToReviewProvider`）时对话框列的仍是 Anki 卡组，按钮写「制卡到 <Anki 卡组>」。
  - `fushi/lib/src/srs/srs_mining.dart:162`（`resolveSrsMiningDestination`）只按偏好 `srsMiningDestination.deckId` 落地，`SrsMiner._mine` 不读 `MiningRequestOverrides.deckName`，对话框里选的卡组对复习路径完全无效，卡总进偏好 / 默认牌组。
- **[x] ① 已修复** — 复习目标下卡组分区改列复习牌组全名（`buildSrsAdvancedMiningDeckSection`，默认值 = 偏好解析后的实际落地牌组，「设为默认」写 `setSrsMiningDeckId`）；`resolveSrsMiningDestination` 新增 `requestedDeckName`，按全名命中现存牌组即本次覆写、不改偏好，命中不了回落偏好牌组、不新建（与 Anki 后端 `resolveTargetDeck` 同口径）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_mining_test.dart`（覆写落进所选子牌组 / 名字对不上回落偏好牌组）、`fushi/test/anki/advanced_mining_deck_section_test.dart`（复习目标列复习牌组、默认取实际落地牌组）。
- **备注**：真机验证本轮未做。
