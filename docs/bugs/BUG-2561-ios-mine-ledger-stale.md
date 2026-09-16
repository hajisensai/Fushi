## BUG-2561 · iOS 在 Anki 里删掉卡后 Fushi 仍画 ✓，没有任何纠正出口
- **报告**：2026-09-16（用户：「而且卡片删掉也不会检测是否还存在」）
- **真实性**：✅ 真 bug（表现真实），但**「自动检测」在 iOS 上不可达**，得分两层说：
  - 平台边界：AnkiMobile 的 `anki://x-callback-url` 只有 `addnote` / `infoForAdding` / `search` / `sync`，一个回读 collection 的入口都没有，所以 iOS 上的 ✓ 只能建立在本机账本 `AnkiMobileMinedLedger` 上（`fushi/lib/src/anki/ankimobile_mined_ledger.dart`）。
  - 真正的缺陷是**账本只增不删、且没有任何纠正出口**：`record` 之外没有反向操作，用户在 AnkiMobile 里删掉卡之后账本照样说「制过」，✓ 永久亮着，词头旁的 ↗ 还会去开一个搜不到东西的界面（`ankimobile_repository.dart` 的 `openWordInAnki` 用同一份账本）。更糟的是点 ✓ 的编排：`runAnkiMinedCardAction`（`fushi/lib/src/anki/anki_mined_card_action_sheet.dart`）此前把 `findMatchingNotes` 的空结果一律当成「卡已被删」→ 直接重制，而 AnkiMobile 的反查是**恒空**（基类降级实现），于是卡还在时点 ✓ 会默默再制一张。
  - 其余后端（AnkiConnect / AnkiDroid）每次查词都真问 Anki，删掉的卡下一次查词自动变回「+」；但此前它们也**只在重新查词时**才纠正——已经打开的弹窗上那个 ✓ 不会因为用户切到 Anki 删了卡而收回。
- **[x] ① 已修复** — 三处：
  1. 基类新增能力声明 `canVerifyExistingCards`（`packages/fushi_anki/lib/src/base_anki_repository.dart`），AnkiMobile 覆写为 `false`；编排层据**能力**而不是类型分流，只有能回读 Anki 的后端才把「反查为空」当「卡已被删」，回读不了的改为弹裁决框（新 `showAnkiUnverifiedMinedCardDialog`：再加一张 / 「我已在 Anki 里删了」），把只有用户知道答案的判断交还用户。
  2. 账本新增 `forget`（+ 基类 `forgetMinedCard`，AnkiMobile 覆写委派），用户说删了就划掉记录，✓ 立刻变回「+」（走 BUG-2560 的同一条广播）。
  3. 已渲染弹窗的复核：`DictionaryPopupWebViewState` 在 `resumed` 时调 `window.fushiRefreshMineStates()`（范围未知，只重问已探测过的按钮，不把 BUG-1833 的懒探测退化成整屏发桥），与 texthooker 徽章的 BUG-1799 同口径——这条让**桌面 / Android** 上「切到 Anki 删卡再切回来」当场把 ✓ 收回。
  另：`AutoRepositionAnkiRepository` 补上两条委派，否则开了自动重排的 iOS 用户会拿到基类默认 `true`，整条裁决路径被旁路。提交 `e54a6ab593`
- **[x] ② 已加自动化测试** — `fushi/test/anki/ankimobile_mined_ledger_test.dart`（`forget` 划掉后不再算已制卡、穿持久层、空/不存在的词不抛；`canVerifyExistingCards` 为 false；`forgetMinedCard` 委派）；`fushi/test/pages/anki_mined_card_action_sheet_widget_test.dart`（回读不了的后端反查为空时弹裁决框而不是默默重制、两个出口各自的效果、能回读的后端仍走旧路一步不多）；`fushi/test/utils/misc/popup_asset_behavior_test.js` 的 `testHostRefreshWithoutTargetOnlyRepaintsProbedButtons`（切回前台复核把 ✓ 收回 + 未探测过的按钮不被拖去发桥）；`fushi/test/anki/auto_reposition_repository_delegation_test.dart` 守住装饰器委派。
- **备注**：iOS 上「自动核对」仍然做不到，这是 AnkiMobile URL scheme 的边界，不是本次没做完——有回读通道的那天（或用户改用 AnkiConnect）应当直接问 Anki，而不是加厚账本。同一报告的另一半见 BUG-2560。
