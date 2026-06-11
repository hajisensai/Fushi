## BUG-186 · 制卡按钮态在查词时检测 Anki 真实卡存在性（删卡后可重制）
- **报告**：2026-06-11（用户：TODO-084 + TODO-087）
- **真实性**：✅ 真 bug — 根因 `hibiki/assets/popup/popup.js`（mine button 旧逻辑）。
  - TODO-084：「在 Anki 删了卡，重新查这个词算不算制卡？能读 Anki 实际数据吗？重进视频才能重制。」
  - TODO-087：「制卡成功后，不关视频页删掉那张卡，能不能重新制卡。」
  - 合一根因 = 制卡按钮的「已制卡 ✓」态是弹窗 DOM 的一次性快照，制卡成功后被永久禁用：
    - Anki 数据源本身**已是实时查询**（AnkiConnect `findNotes` / AnkiDroid `findDuplicateNotes`，删卡后返回 false；见
      `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart:255` 的 `isDuplicate` 与
      `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart:290` 的 `checkForDuplicates`，
      `packages/hibiki_anki/test/ankiconnect_service_test.dart:179` 的 `isDuplicate query shaping` 组已证实）。
    - 旧逻辑制卡成功后 `disabled = wasAdded && !allowDupes` —— 一旦 ✓ 就永久禁用，
      除非重新查词触发 `renderPopup` 重建 DOM 才重查 Anki。
      这就是「不关视频页删卡后按钮死锁、无法重制」（TODO-087）。
- **修复方向（用户明确要求）**：**查词时检测**决定按钮真实状态，而不是把 ✓ 变纯视觉、按钮永远默认可点。
- **[x] ① 已修复（修订版）** — `hibiki/assets/popup/popup.js` `createEntryHeader` 的 mine button：
  - **主机制 = 查词时检测**：弹窗渲染该词时（`createEntryHeader` 跑在 `renderPopup` 里，每次查词重建 DOM），
    末尾的初始 `duplicateCheck` 实时查 Anki，经 `setMineState` 设置**有意义**的 `data-mined` 状态：
    卡在 → 已制卡 ✓（`data-mined='1'`）；卡不在 → 可制卡 +。`data-mined` 是按钮行为的唯一真相源，
    ✓ **不是装饰**，它真实反映「现在 Anki 里有这张卡」。
  - **TODO-084 天然满足**：删卡后重新查这个词 = 重新渲染 = 重跑查词时检测 → 卡没了 → 可制卡 → 可重制。
  - **TODO-087 边角兜底**：同一弹窗内删卡、不重新查词时按钮仍显示陈旧 ✓ → 点击 ✓ 先实时 `duplicateCheck` 复查：
    卡真没了（或允许重复）→ 走 `mineEntry` 重制；卡仍在且不允许重复 → 只刷新 ✓，不重复制卡。这是兜底，不是主路径。
  - 去掉初始 `disabled: true` 与所有 `disabled = ...allowDupes` 永久锁；按钮长期启停只由 `data-mined`/单次在途守卫决定。
  - 加 `dataset.mining` 单次在途守卫，`finally` 里始终清守卫 + `disabled=false`（保留 BUG-077 失败恢复契约）。
  - 不动 `MiningStatistics`（历史制卡计数，删卡不应减）、`allowDupes` 配置、不加缓存（每次实时查）。
  - 提交：见本仓库 `codex/todo-084-087-anki-real-status` 分支
- **[x] ② 已加自动化测试** —
  - 行为（无头 DOM 驱动 callHandler 模拟查词时检测 / 重新查词重制 / 边角点击复查）：
    `hibiki/test/utils/misc/popup_asset_behavior_test.js`
    （`testLookupTimeDetectionSetsAccurateStateForExistingCard` / `...ForAbsentCard` 证查词时检测设准确态；
    `testRelookupAfterDeletionDetectsMineableAndReMines` 证 TODO-084 重新查词重制；
    `testMineButtonReMinesAfterCardDeletedWithoutReopening` 证 TODO-087 同弹窗边角点 ✓ 复查重制；
    `testMineButtonDoesNotDuplicateWhenCardStillExists` 证卡仍在时不重复制卡）。
  - 源码守卫（锁回归）：`hibiki/test/pages/popup_mine_button_anki_truth_static_test.dart`
    （无 `disabled: true` / 无 `disabled=...allowDupes` 锁；初始 `duplicateCheck.then` 调 `setMineState`（查词时检测）；
    `data-mined` 是真相源；mined 分支内 `duplicateCheck` 在 `mineEntry` 之前（边角复查）；`finally` 始终复位）。
  - 撤修复（还原 pre-fix popup.js）实测：JS 套件 exit=1、Dart 守卫 5 例全红，确认守卫有效。
  - 数据源实时性既有覆盖：`packages/hibiki_anki/test/ankiconnect_service_test.dart` 的 `isDuplicate query shaping` 组。
- **备注**：真 Anki 制卡/删卡的端到端复测需真机/真 AnkiConnect（host 测不到）；本修复不动统计计数
  （`MiningStatistics`「累计制卡 N」是历史计数，删卡不应减，未触碰）。
  残留性能成本：每次查词渲染多一次 `duplicateCheck`（与旧逻辑相同，旧逻辑初始也查一次）；
  点击已制卡 ✓ 多一次复查（仅边角，单次在途守卫防连点）。
