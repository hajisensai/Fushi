## BUG-1169 · release 剥离 assert 后 failed(none) 被判成启动成功
- **报告**：2026-07-28（用户：代码审查）
- **真实性**：✅ 真 bug（潜伏隐患，非当前可复现路径）。根因
  `hibiki/lib/src/mining/gal_hook_session_controller.dart:209`（PR#466 引入）：
  `GalHookLaunchResult.failed()` 只用 `assert(reason != none)` 拦「没有原因的失败」，
  而 `launched` 的判据是 `reason == GalHookLaunchFailureReason.none`。**assert 在 release
  构建里被整个剥离**，届时 `failed(none)` 可以正常构造，`launched` 读成 `true` ——
  一次失败的启动被当成成功播报：界面说「启动成功」，游戏没起来，且没有任何失败原因。
  防御性断言恰好在用户实际运行的那个构建里不存在。
  当前分类器不中一律落 `unknown`，`none` 走不到失败分支，所以尚不可复现；但值域里留着
  哨兵 = 非法状态可构造，只靠 debug-only 检查约束。
- **[x] ① 已修复** — 提交 `be8ad407b`。类型层消除非法状态，不再依赖运行期断言：
  - `GalHookLaunchFailureReason` 删除 `none` 成员，枚举**只列失败**；
  - `GalHookLaunchResult.reason` 改 `GalHookLaunchFailureReason?`，`null` 是「启动成功」
    的唯一表示；`launched => reason == null`；
  - `failed()` 形参为非空 `GalHookLaunchFailureReason`，空安全在**编译期**挡住 `null`，
    枚举里又没有成功哨兵 ⇒ 「读起来像成功的失败」根本构造不出来，assert 随之删除；
  - 两个命名构造器都重定向到私有生成式构造器 `GalHookLaunchResult._`，外部只有
    `launched`（reason 恒 null）/ `failed`（reason 恒非 null）两条路，写不出第三种状态；
  - `gal_hook_failure_text.dart` 的 `_failedMessage` switch 去掉 `none` 分支、补 `null`
    分支（落兜底事实，绝不编造原因）。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_hook_launch_outcome_and_encoding_test.dart`
  新增 3 条，**刻意不用 `throwsA(isA<AssertionError>())`**——那种断言只在 assert 生效时成立，
  等于用「本 bug 里失效的那个机制」证明自己没事：
  1. 值域守卫：`GalHookLaunchFailureReason.values` 不得含 `none`/`success` 哨兵（纯结构，
     debug/release 语义相同）；
  2. 行为守卫：遍历全部 `values` 构造 `failed(v)`，断言 `launched == false` 且分级不为
     `running`——assert 被剥离时由 `expect` 抓，assert 生效时由 assert 抓，两种语义都红；
  3. 源码守卫：`failed()` 构造器体内不得出现 `assert(`，且 `launched` 判据必须是
     `reason == null`。
  负向验证（临时改回旧实现）：① 旧实现原样 → 4 红；② **旧实现 + 删掉 assert（= release
  语义）→ 仍 4 红，且日志里零 AssertionError**，失败来自
  `Expected: false / Actual: <true>`（`launched` 把失败读成成功）与
  `Expected: failed / Actual: windowMissing`（误判继续传到分级）。还原后全绿。
- **备注**：同类型其它状态已核——`superseded` 在 `_failedMessage` 里同样走不到，但后果只是
  落兜底文案，不构成「失败报成成功」；`GalHookInjectorDiagnostics.failure == none` 是合法
  状态（失败早于 injector 运行时诊断本就为空），不是非法组合。`lib/src/mining/` 全目录
  原本只有这一个 `assert`，修复后为零。
