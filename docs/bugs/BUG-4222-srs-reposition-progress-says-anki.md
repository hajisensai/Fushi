## BUG-4222 · srs-reposition-progress-says-anki
- **报告**：2026-11-07（用户：挖词目标 = Fushi 复习时「按词频重排新卡」进度显示「正在从 Anki 读取卡片…」）
- **真实性**：✅ 真 bug（仅文案）。重排本身走对了后端：目标 = Fushi 复习时装饰链最外层是 `SrsMiningAnkiRepository`，`listNewCards` / `setNewCardPositions` 读写复习库（`fushi/lib/src/srs/srs_mining.dart:1409`、`:1461`）；但进度文案 `fushi/lib/src/anki/anki_deck_reposition_dialogs.dart` `_RepositionProgressBody` 写死 `anki_reposition_progress_fetch`，弹窗里的「牌组选项新卡顺序为随机」提示也是 Anki 专属。
- **[x] ① 已修复** — `AnkiViewModel.repositionTargetsSrs`（复用 `repositionSnapshotFolderFor` 的装饰链判据），弹窗与进度按它选文案：`anki_reposition_progress_fetch_srs`「正在读取 Fushi 复习的卡片…」、`anki_reposition_srs_order_hint`（复习牌组「新卡顺序」设为「按位置」才生效）；进度文案抽成纯函数 `ankiRepositionProgressLabel`。
- **[x] ② 已加自动化测试** — `fushi/test/anki/anki_deck_reposition_dialog_test.dart`（两种目标的进度文案 / Anki 目标弹窗仍显示 Anki 提示）、`fushi/test/srs/srs_mining_test.dart`（装饰链 → `repositionTargetsSrs` 真 / 假）。
- **备注**：同屏「本机服务 › AnkiConnect（Fushi 复习）」是协议名，不在本 bug 范围。
