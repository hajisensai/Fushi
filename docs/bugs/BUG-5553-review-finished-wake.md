## BUG-5553 · 复习做完后几十秒到期的卡不自己出来：完成页只在库变化时重查
- **报告**：2026-11-11（用户：应用内反馈 LAk5vHGWUe，开发者自提；11-26 补充「多出来的是 10 秒或 30 秒后到期的短间隔卡」）
- **真实性**：✅ 真 bug。按代码核实（旧 AI 总结前一版说「全仓没有 learn-ahead」是错的）：
  - FSRS 牌组：学习卡有 20 分钟提前窗口（`native/fushi_fsrs/src/store/queue.rs:60` `LEARN_AHEAD_MS`，`study.rs` `Picker::next` 末尾兜底出），几十秒后到期的学习卡排空时会直接出，不是这条的来源。
  - RWKV 牌组（没写过步长时不用学习步，`packages/fushi_srs/lib/src/deck.dart` `learnStepsFor`，答错的卡留在复习队列由 RWKV 按 R 决定何时再出）：同日重复间隔守卫 `native/fushi_fsrs/src/store/study.rs:963`（`instant_eligible` 的 `spaced`，默认 30 秒 AND 之后同组别的卡 5 次作答，`deck.dart:163-164`）把唯一剩下的卡暂缓，排队返回 `next = null`，复习页进「今天的复习做完了」。
  - 完成页只在库变化时重查（`fushi/lib/src/pages/implementations/srs/srs_review_page.dart:1647` `_syncOnce` → `:1682` `_recheckFinished`），守卫到点解除不是库变化，页面永远停在「复习完」；退出后牌组列表重新排队，卡又出现。同一缺口也覆盖 FSRS 学习卡在 20 分钟窗口之外（例如 30 分钟学习步）到期的情形。
- **[x] ① 已修复** — 用户拍板方案 A（不改排程）：内核排空时回传 `wakeIn`（`study.rs` `Picker::wake`：最早一张学习卡进入提前窗口的时刻、RWKV 只差守卫时间那一半且路径有复习额度的卡的解除时刻，只给晚于此刻的；只差作答次数的不报，那要别的卡被答过才会解除）；`SrsStudyState.wakeIn`（含远程复习线格式 `wake`）；复习页「复习完」按它挂计时器（`_armWake`），到点重排一次，排得出就亮出既有的「继续」入口（`srs-review-more-due`），排不出就按新结果重定，不自动出卡。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/study.rs` `study_reports_when_a_time_held_rwkv_card_comes_back` / `study_reports_when_a_learning_card_enters_the_learn_ahead_window`（会话与 SQL 基准对拍）；`packages/fushi_engine/test/srs/srs_remote_store_test.dart`「排队结果线格式往返保留 wake」；`fushi/test/srs/srs_review_external_changes_test.dart`「复习完时学习卡过一会儿才进入提前窗口：到点自己亮出入口，不自动出卡」。
- **备注**：自定义学习会话（`CustomPicker`）排空时不报 `wakeIn`（它的学习卡只含会话里答过的，另一套查询），会话里 20 分钟外到期的学习卡仍要库变化或重进才出；未做真机复测。
