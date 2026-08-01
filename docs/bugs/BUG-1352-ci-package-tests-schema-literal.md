## BUG-1352 · CI Run package tests 红：packages 侧 schemaVersion 等值断言漏跟 v66
- **报告**：2026-08-02（用户：巡检看板 TODO-2553「develop CI 全红」）
- **真实性**：✅ 真 bug（判据坏，非功能坏）。根因
  `packages/hibiki_core/test/mihon_database_test.dart:17` 的
  `expect(database.schemaVersion, 65)`：PR#663 把
  `packages/hibiki_core/lib/src/database/database.dart:426` 的
  `int get schemaVersion => 66;` 连同 v66 迁移（同文件 `if (from < 66)`，
  新增 `collection_relations` + `video_scrape_meta.episode_number`）一起落地，
  并把 `hibiki/test/` 下 24 处版本字面量批量改到 66，唯独漏掉 `packages/` 这一处。

  **为什么会漏**：仓库约定的本地全量门（CLAUDE.md 验证章）只在 `hibiki/` 下跑
  `flutter_test_failures.dart`，`packages/*/test/` 由 CI 的 `Run package tests`
  步骤单独覆盖。两套测试根不重叠 → 本地 `hibiki/` 16771 条全绿，CI 跑到第 40 条
  就红，`Build Release APK`（本仓真正的单测合并门）从 `9fb594896` 起连红 5 个
  commit（run 30698022986 … 30706194311，报错逐字相同）。

  **判据坏的证据**：① 生产侧完全正确——迁移阶梯 v1→v66 连续无断裂，24 处
  `hibiki/test/` 断言都是 66；② 不可能只改生产代码转绿（那要回退 schema bump，
  反过来打爆那 24 条 + 丢掉 v66 迁移）；③ 该用例自身的契约是「Mihon 五张表按声明
  类型存取、不做整数强转」，「当前 schema 恰好第几版」不在契约内，契约未变。
- **[x] ① 已修复** — 不是把 65 改成 66（那只是第四次打同一个补丁：本行历史上已被动
  改过 63→64→65），而是消除跨测试根漂移源：package 侧只断言「本用例依赖的表已进入
  schema」，改为 `expect(database.schemaVersion, greaterThanOrEqualTo(65))` +
  `reason`（v65 = Mihon 五张表引入版本）。「当前是第几版」的等值守卫留在迁移阶梯测试
  `hibiki/test/database/migration_*.dart`——那儿本来就是它的家，也在同一个批量替换
  半径内。顺带把用例名里同样过时的 `v63` 改成 `v65`（migration 注释已记载该迁移
  在集成时从 v63/v64 顺延到 v65）。
- **[x] ② 已加自动化测试** — `hibiki/test/database/package_schema_version_literal_guard_test.dart`：
  源码扫描 `packages/*/test/**.dart`，禁止 `expect(<x>.schemaVersion, <整数字面量>)`
  这类等值断言，只允许下界 matcher。变异实测：把断言还原成
  `expect(database.schemaVersion, 66)` → 守卫真红并指到
  `mihon_database_test.dart:27`；反向替换还原后复绿。
- **备注**：验证证据 `.codex-test/ci-repro/`（不入库）。修复后按 CI 的
  `Run package tests` 原命令在本地逐包复跑：hibiki_core 40 / hibiki_anki 336 /
  hibiki_audio 72 / hibiki_platform 1，四个 `FLUTTER TEST VERDICT: PASSED`，
  退出码全 0（hibiki_dictionary 无 test/ 目录，CI 跳过）。CI 的循环用
  `bash -e`，在 hibiki_core 就中断，后三个包在红的那 5 个 commit 上**从未执行过**
  ——本次一并补跑，确认没有第二处隐藏红。
