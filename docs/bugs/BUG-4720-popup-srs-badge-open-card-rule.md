## BUG-4720 · 制完卡当下与重开弹窗后「打开卡片」跳到不同笔记
- **报告**：2026-11-16（应用内反馈 CGtu-HjN15，维护者自提）
- **真实性**：✅ 真 bug（沿代码路径确认，未在真机复现）。制卡目标 = Fushi 复习时，查词弹窗词条头只留一颗 ↗：复习状态徽标可见时 CSS 藏掉「在 Anki 中打开」↗（`fushi/assets/popup/popup.css:639` `.open-anki-srs-owned`），徽标没状态时 ↗ 兜底。两颗按钮选笔记的判据却不同：
  - 徽标（`fushi/assets/popup/popup.js:403` `createSrsStatusBadge` 的 onclick）把状态回包里的 `noteId` 交给 `srsOpenCard` → `SrsAppHost.openCard`（`fushi/lib/src/srs/srs_app_host.dart:70`）。这个 noteId 是「最需要复习那张卡」所在的笔记（`packages/fushi_engine/lib/srs/srs_db_store.dart:5349` 按 `srsTermUrgencyCompare` 排序取 first，并列时按 SQL 行序），还是取状态那一刻的快照；
  - ↗（`popup.js` `openWordInAnki` → `openInAnki` 桥 → `SrsMiningAnkiRepository.openWordInAnki`，`fushi/lib/src/srs/srs_mining.dart:404`）按词在点击时反查，打开**最新创建**的那条笔记（`packages/fushi_engine/lib/srs/srs_miner.dart:418` `matchingNotes` 按 createdAt 降序）。
  同一个词有几条复习笔记时，制完卡当下（徽标状态刷新前 / 刷新回来的快照）和关掉弹窗重开（徽标按最紧急的卡）点到的是不同笔记。`popup_settings_injection.dart` 的注释与 `popup.js` 的注释都声明「两颗按钮去同一个地方」，实现与设计意图矛盾。
- **[x] ① 已修复** — 徽标接管 ↗ 时（`srsBadgeOwnsOpenWord()`，即宿主注入 `__fushiSrsMiningTarget`）点击改走与 ↗ 同一个 `openWordInAnki(button, expression, reading)`：同一根 `openInAnki` 桥、同一条「这个词最新的笔记」判据，在点击那一刻按词解析，状态回包里的 noteId 不再决定打开哪条笔记。制卡目标 = Anki 时 ↗ 去 Anki、徽标是唯一去复习的入口，仍按状态那张卡走 `srsOpenCard`（两者去处本来就不同）。`tools/browser-extension/vendor/popup.js`、`fushi/assets/browser_extension/vendor/popup.js` 同步镜像。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js` `testSrsOwnedBadgeOpensSameNoteAsOpenAnkiButton`：状态回包 noteId 指向旧笔记时，徽标与 ↗ 必须发出同一个 `openInAnki {expression, reading}`，不得走 `srsOpenCard`（修复前红）。
- **取舍**：两颗按钮统一到 ↗ 的判据（这个词最新建的笔记），不是徽标原来的判据（最需要复习那张卡的笔记）——「制完卡当下打开刚制的卡」应落到新笔记。代价：徽标显示的队列 / 到期标签（如「复习中」）仍按最紧急那张卡算，同一个词有多条笔记时，点开的编辑页不一定是标签对应的那张卡。
- **已知未覆盖（同根因，不在本 bug 场景内）**：
  - 浏览器扩展没有注入 `__fushiSrsMiningTarget`（只在 `popup_settings_injection.dart` 注入），扩展里徽标和 ↗ 都显示，徽标仍走 `srsOpenCard`、↗ 走 background 的 `openInAnki`；扩展若把卡制进 Fushi 复习，两颗按钮仍会打开不同笔记。
  - 作品会话（`WorkProfileScope`）期间徽标状态取自 `SrsAppHost.current.readStore`，而 `openWordInAnki` 的 miner / `openNote` 跟随作品会话的复习副本（`anki_view_model.dart` `_openSrsNote`）；两者若不是同一个库，可能徽标可见、点开却 noMatch（推测，未实测；修复前 ↗ 也如此）。
- **备注**：未在 Windows 漫画页真机复测原始失败路径。
