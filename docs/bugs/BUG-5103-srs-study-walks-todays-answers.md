## BUG-5103 · 常驻出卡会话每次排队复制并整表扫描今天的作答（HBK-AUDIT-010）
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 项目审查 HBK-AUDIT-010，来自 PR #4002）
- **真实性**：✅ 真 bug（性能）。根因（origin/develop `cbdc2a45ed`）：
  - `native/fushi_fsrs/src/store/gen4/cmd/study.rs:131-136`：每次 `study`（含 `answerAndStudy` 的作答带排队）无条件把会话里整份「今天的作答」复制成 `Vec<(String, i64)>`，只为自定义学习「会话里答过」备用，普通出卡根本不读。
  - `native/fushi_fsrs/src/store/gen4/cmd/study.rs:361`、`:370`、`:383`：作答后的增量重读（`G4Feed::reread_logs`）为「碰到的卡上今天的作答」「这批日志记在哪张卡」「重放分量里别的卡上今天的作答」各把 `LogState::answer_ids()` 整表扫一遍。
  - 数据结构缺口：`native/fushi_fsrs/src/store/queue.rs` `LogState.answers` 只有「日志 id → (卡, 时刻)」一个方向，没有按卡的索引，只能整表扫。今天答 N 次，累计 O(N²)。
- **[x] ① 已修复** — `LogState` 加按卡的作答索引 `answers_by_card`（`queue.rs` `apply` / `unapply` 同增同删，`answers_on` / `answer_card` 查询）；`reread_logs` 三处整表扫描改为按卡 / 按日志 ID 查索引，工作量随碰到的卡与日志；去掉每次排队的整份复制，`Tables::answered` 改为接收常驻会话的计数上下文（`Source::resident`），只有自定义学习（会话开始在今天之内）才读今天的作答。提交 92df18e898。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/gen4/cmd/study_session_tests.rs` `ordinary_study_never_walks_the_whole_list_of_todays_answers`（经 C ABI 分发器答 80 次、排 40 次，整表遍历计数必须为 0，结果与无状态基准逐键相同，自定义学习仍读会话里的作答）；`native/fushi_fsrs/src/store/queue.rs` `answer_index_tests::the_per_card_answer_index_follows_every_fold_and_forget`（索引与整张作答表一致）。审查补 `study_session_tests.rs` `a_linked_history_refolds_todays_answers_on_the_touched_card`（经 C ABI：卡接上另一张卡的历史后，它今天那条学习步不再算引入；索引查空时会话计数多算一张，与基准不同）——原先把 `answers_on` 改成恒空，`store::` 下只有上面那条单元测试红，端到端对拍全绿。
- **备注**：变异实测：只恢复「每次排队整份复制」一项，计数测试红（4880 次访问 vs 0）；去掉索引的插入，索引不变量测试红。原实现另有每次增量重读 3 次整表扫描，修复后都没有了。
