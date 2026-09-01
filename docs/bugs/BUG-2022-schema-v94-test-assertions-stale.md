## BUG-2022 · 刮削 P1 升 schema 到 94 但漏改 43 处测试断言，堆叠 PR 拿不到真单测门导致一路合进 develop
- **报告**：2026-09-02（读 develop 的 `Build Release APK` 失败日志时发现，非用户报告）
- **真实性**：✅ 真 bug。PR #1126（刮削重设计 P1，v94）把 `packages/fushi_core/lib/src/database/database.dart:726` 的 `schemaVersion` 从 93 升到 94 并加了 `identity_json` 两列的迁移，但没有同步更新测试里的版本断言。develop 上 `release.yml` 的 `tests` job → `Run unit tests (main app)` 因此连续三次 failure：
  ```
  The Flutter test harness reported failures (39 error event(s), 21926 test(s) completed).
    suite: fushi/test/database/migration_test.dart
    Expected: <93>
      Actual: <94>
  ```
- **不是合并时弄丢的**：在 #1126 的分支原始 head `61893e6a15` 上实测，`database.dart` 已是 `schemaVersion => 94` 而 `collection_relations_test.dart:53` 仍是 `expect(db.schemaVersion, 93)` —— **PR 自己分支上就是坏的**。
- **为什么没被发现（结构性根因）**：刮削三条 PR 是堆叠的，真实方向是 **P2 → P1 → P3**（`#1124` base=develop，`#1126` base=`worktree-scrape-redesign-p2`，`#1127` base=`worktree-scrape-redesign-p1`）。而 `main.yml`（唯一跑 `flutter_test_failures.dart` 与 R8/proguard/native 校验的 workflow）的触发是 `pull_request: branches: ['main','develop']` —— **base 不是 develop 的 PR 从不触发**。所以 #1126 / #1127 的检查列表里永远只有 SonarCloud，它们显示 `MERGEABLE/CLEAN` 时，那个 CLEAN 只代表没冲突、不代表测过。同族事实：**PR 处于 CONFLICTING 时 GitHub 建不出 `refs/pull/N/merge`，所有 `pull_request` 触发的 workflow 整批不跑**，DIRTY 的 PR 同样会静默失去 CI。
- **[x] ① 已修复** — 共 43 处，分两类，**判据不同、不能盲替**：
  - **34 处 `expect(db.schemaVersion, 93)`**（24 个文件）→ 94。这是「迁移完成后当前 schema 版本」。
  - **9 处 on-disk `user_version` 断言**（7 个文件）→ 94。分两种写法：`expect(version.read<int>('user_version'), 93)` 与 `expect(probe.select('PRAGMA user_version').first.values.first, 93)`，都出现在 `openUpgraded()` 或 `migrated.close()` **之后**，读的是迁移后的磁盘版本。
  - **刻意不改**：`migration_v94_download_identity_json_test.dart` 里的 93（`PRAGMA user_version = 93` 建种子库、以及 `seedV93()` 之后断言迁移前状态）。它们是**迁移起点**，下一行还断言 `identity_json` 列 `isFalse` 佐证。盲目全仓替换会把这条测试变成空转。
- **[x] ② 已加自动化测试** — 这些断言本身即测试（版本字面量是刻意的绊线：升 schema 必须逐条确认每条迁移路径仍落地正确）。修复前 `test/database` 实测 `VERDICT: FAILED`（先 39 条，改完 `db.schemaVersion` 后仍余 9 条 `user_version`），修复后 `FLUTTER TEST VERDICT: PASSED - 618 tests ran, all tests passed`。
- **备注**：修法刻意**不是**把字面量换成 `db.schemaVersion` 之类的自反断言——那会让绊线永久失效（`expect(db.schemaVersion, db.schemaVersion)` 恒真）。`packages/*/test` 侧另有守卫 `package_schema_version_literal_guard_test.dart` 禁止等值断言，那是不同作用域的不同约定，本次不涉及。
