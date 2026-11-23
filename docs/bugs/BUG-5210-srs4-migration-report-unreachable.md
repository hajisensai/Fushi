## BUG-5210 · 复习库升级没过核对：报告手机上拿不到，恢复页同时说两种失败
- **报告**：2026-11-22（用户：Android 手机复习页截图）
- **真实性**：✅ 真 bug，两处根因。
  1. 报告只给路径：`fushi/lib/src/pages/implementations/srs/srs_generation_view.dart` 的 `srsGen4OutcomeText` 把 `SrsGen4MigrationOutcome.reportPath`（`<库目录>/srs4-migration-report.json`，内核 `native/fushi_fsrs/src/store/gen4/migrate.rs` `REPORT_FILE`）塞进 `srs_gen4_aborted` 文案。Android 上是 `/data/user/0/app.fushi.reader/files/...`，iOS 同理在沙盒里，用户既打不开也发不出去，报告等于没有。
  2. 两段说明叠在一起：`_MigrationPanel` 的主说明按「打开库时的状态」（`SrsGenState.migrationFailed` → `srs_gen4_migration_failed_state`「上次没做完、留下了未完成的文件」）给，本次结论（aborted → `srs_gen4_aborted`）又作为附加说明追加，同一次失败说了两遍、而且互相矛盾。叠出「留下了未完成的文件」还是真的：内核对拍不过时故意留着临时文件 `srs4.db-migrating`「作诊断」（`migrate.rs` `migrate_locked` 的 `Ok(Outcome::Aborted { .. }) => {}` 分支），而内核的 `migrationFailed` 把「对拍不过（有报告）」与「只剩临时文件」两个原因合在一个状态里，页面分不开。
- **[x] ① 已修复** —
  - 内核：对拍不过与拦下 / 叫停 / 出错一样当场删临时文件（`migrate.rs` `migrate_locked`），诊断只在报告里；目录里不再有「没做完的文件」，重新升级照旧在开跑前整份删临时文件重来。规格 `docs/specs/2026-11-11-srs-generation-break.md` §6.1 第 6 步同步改。
  - 状态互斥：`SrsGen4MigrationController` 读目录里的报告（`SrsGen4Migration.abortedReportPath`，只认 `verdict = aborted`），`previousRunAborted` 把 `migrationFailed` 的两个原因分开；页面只有一段主说明，优先级 在跑 > 本次结论 > 本次出错 > 上次失败（按原因二选一）> 要升级。
  - 报告可达：文案不再印路径（`srs_gen4_aborted` 删，换 `srs_gen4_aborted_report`）；对拍不过时给「把报告发给开发者」（`FeedbackComposePage(prefill:)` 打开提交页，报告作样本文件自动附上、分类「问题」带日志，不读写草稿）与「分享报告」（手机系统分享面板，`FushiShare.shareFiles`）/「保存报告」（桌面另存为），见 `srs_gen4_report_actions.dart`。报告内容不变（内核默认只给 ID 与计数，`dryrun.rs` 有不带笔记内容的断言）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_generation_view_test.dart`（MD3 / Apple 各一遍：只剩临时文件只说一种；对拍不过只说一种、不上路径、两个动作可点；再跑一次对拍不过 / 取消都不叠「上次」）；`fushi/test/srs/srs_gen4_migration_controller_test.dart`（报告跟着最新结论走）；`fushi/test/feedback/feedback_draft_test.dart`（预填打开自动附文件、不碰草稿）；`packages/fushi_srs/test/store/srs_gen4_migration_test.dart`（报告文件名与 migrate.rs 一致、只认 aborted）；`native/fushi_fsrs` `migrate::tests`（对拍不过后不留临时文件）。
- **备注**：对拍为什么不过（截图里那次）是另一件事，由并行的会话按根因查；本条只修「报告拿不到」与「状态叠说明」。
