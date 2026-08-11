## BUG-1494 · 制卡记账守卫仍钉 addMiningCount，P4 写侧收敛后把红带进 develop
- **报告**：2026-08-11（用户：巡检发现 develop 常驻红）
- **真实性**：✅ 真 bug（守卫过期红，非产品行为回归）。`develop@0c6ca0a0fd` 上
  `fushi/test/pages/mining_count_wiring_static_test.dart` +
  `fushi/test/pages/favorite_button_wiring_static_test.dart` 共 3 条用例红，
  断言均为 `Expected: contains 'addMiningCount('`。
  - 根因：`a8439b2f45`（P4 写侧收敛 A 组）把制卡记账收编成唯一复合入口
    `FushiDatabase.recordMiningEvent`（`packages/fushi_core/lib/src/database/database_statistics.part.dart:1063`，
    同事务写 `mining_statistics` + `lookup_mining_counters`）。两个记账 helper 随之改调复合入口：
    - `fushi/lib/src/pages/implementations/reader_fushi/mining.part.dart:382`（`_recordMined`，
      内部 `recordMiningEvent(` 在 `:388`）
    - `fushi/lib/src/pages/implementations/dictionary_page_mixin.dart:501`（`recordMined`，
      内部 `recordMiningEvent(` 在 `:507`）
    `addMiningCount` 仍存在，但已降级为 `recordMiningEvent` 的**内部实现细节**，页面层不再直调
    （P4 自己的守卫 `fushi/test/tools/statistics_write_convergence_guard_test.dart:55` 正是**禁止**
    `lib/` 直调它）。两条页面级守卫没跟着改，于是 P4 那批提交把红带进 `develop`。
  - 受影响用例：`reader onMineFromPopup 成功分支把制卡计入书籍统计`、
    `mixin 暴露 protected recordMined（供 video 等覆写页调用）`、
    `mixin 默认书籍来源、提供收藏 handler 并把成功制卡计入统计`。
- **[x] ① 已修复** — 不删守卫、改判据。这两条守卫守的是**接线**（记账调用必须落在记账 helper
  体内、必须由 `described.record` 触发、来源必须对），而 P4 守卫只问**文件级**「这个写点文件里
  出现过 `recordMiningEvent` 吗」——把记账整段删掉、把 `if (described.record)` 那行删掉、
  或把 `sourceType` 写错，P4 守卫全都照绿。所以两者互补，删任一条都会掉覆盖。
  改法：把 `contains('addMiningCount(')` 换成**作用域限定**的
  `containsIdentifierCall(methodBody(src, '<记账 helper 签名>'), 'recordMiningEvent')`
  —— 比原断言更强（原来只是文件级 `contains`）。顺带把这两个文件里被触及的裸 `contains`
  全部换成 `test/helpers/source_guard.dart` 的共享原语（`containsCodeLine` /
  `containsIdentifierCall` / `methodBody` / `maskComments`），消掉「注释里的同名字面量喂绿」。
  另修一条既有假绿：`expect(src, contains('@protected'))` 只问文件里有没有这个注解
  （`dictionary_page_mixin.dart` 里有一大把），`recordMined` 就算被改回 private 也照绿；
  现在钉的是**紧邻 `recordMined` 签名的那一个**。
- **[x] ② 已加自动化测试** — 就是被修的这两条守卫本身（改判据 + 收紧）：
  `fushi/test/pages/mining_count_wiring_static_test.dart`、
  `fushi/test/pages/favorite_button_wiring_static_test.dart`。已做变异实测：
  把 `mining.part.dart` 的 `recordMiningEvent(` 改成 `addMiningCount(`、把
  `dictionary_page_mixin.dart` 的 `@protected` 摘掉，对应用例各自变红（非零测试执行），
  再反向替换还原。
- **备注**：本条是「守卫没跟着实现走」造成的 develop 常驻红，不是用户可见行为回归；
  制卡计数在 P4 之后始终正常写穿。
