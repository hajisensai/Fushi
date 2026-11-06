## BUG-4111 · AnkiConnect 下「按词频重排新卡」被拒——新版 AnkiConnect 禁写 due
- **报告**：2026-11-05（用户拍板⑱：AnkiConnect 下按词频重排新卡被拒，按推荐方案做）
- **真实性**：✅ 真 bug（根因 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart:992`（修复前 `setCardsDueMany`）：重排逐卡发旧协议 `setSpecificValueOfCard {keys:['due']}`；上游 AnkiConnect 自 tag 26.10.11.0 起重写 `plugin/legacy.py`，`expert_card` 对不在映射表里的键（含 `due`）一律 `raise ApiError('compatibilityError', 'Use native scheduling commands for protected state.')`，整批必然失败）
- **[x] ① 已修复** — 重排改走原生 `scheduling.repositionNewCards`（`/api/v1` JSON-RPC）；先 `api.describe` 探测能力，没有就禁用入口并提示版本，绝不再写 `due`（分支 claude/ankiconnect-native-reposition）
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/ankiconnect_deck_reposition_test.dart`（探测 / 原生调用形状 / 探测不到时一条写请求都不发）、`fushi/test/anki/anki_deck_reposition_test.dart`（runner 读卡前挡下、VM 门控）、`fushi/test/anki/anki_auto_reposition_test.dart`（自动重排静默跳过）、`fushi/test/tools/fake_ankiconnect_smoke_test.dart`（假 AnkiConnect 走原生接口）
- **备注**：原生方法只在上游 master `a579cd5d76`（2026-10-31，"Added `scheduling_repositionNewCards`"）之后才有，截至 2026-11-05 最新 tag 26.10.14.0（`760ff48`）不含它——所以 26.10.11.0 ~ 26.10.14.0 用户现在会看到入口置灰 + 版本提示，等上游发版后自动恢复。

### 根因

`AnkiConnectRepository.setNewCardPositions` → `AnkiConnectService.setCardsDueMany` 把每张卡的新位置打成
`multi` 里的 `setSpecificValueOfCard {card, keys:['due'], newValues:[pos], warning_check:true}`。
上游 26.10.11.0 起旧协议只是 v1 的翻译层，`setSpecificValueOfCard` 仅允许
`factor/ivl/reps/lapses/custom_data/did/flags`，`due` 被判为「受保护的调度状态」直接拒绝
（证据：https://git.sr.ht/~foosoft/anki-connect/tree/master/item/plugin/legacy.py `expert_card`）。
官方替代是 v1 的 `scheduling.repositionNewCards`
（https://git.sr.ht/~foosoft/anki-connect/tree/master/item/API_V1.md#schedulingrepositionnewcards），
但它尚未进任何发布 tag。

### 修复

- `AnkiConnectService.supportsNativeRepositionNewCards()`：`POST /api/v1` `api.describe`，`methods` 里
  `scheduling.repositionNewCards` 存在且 `available != false` 才 true；旧版（无 v1，回旧协议信封）/ 方法缺失 → false；
  401/403 → 抛（下不了结论，不降级成不支持）。apiKey 走 `Authorization: Bearer`。
- `AnkiConnectService.repositionNewCards()`：每卡一条 `{cardIds:[id], startingFrom:pos, stepSize:1, randomize:false, shiftExisting:false}`，
  JSON-RPC 批次 ≤100 条、按 id 对回结果。单卡一条是因为上游「selected siblings share a position」，多卡同请求会把同 note 的位置合并。
- `BaseAnkiRepository.probeDeckReposition()`（新）；AnkiConnect 覆盖成上面的探测；`setNewCardPositions` 写前再探一次，
  没有能力抛 `AnkiRepositionUnsupportedException`，一张不写。删掉 `setCardsDueMany` / `ankiSetSpecificValueFailure`。
- runner `plan()` 读卡前探测；自动重排遇到 Unsupported 静默跳过；设置页（行 + 开关 + CLI 操作）按探测结论置灰并显示
  `anki_reposition_ankiconnect_unsupported`。
