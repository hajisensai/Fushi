## BUG-815 · 看门狗重试与在飞初始化竞态致数据全空(移动端)
- **报告**：2026-07-14（用户：截图「启动耗时超出预期」页）
- **真实性**：✅ 真 bug。手机上从没设自定义数据位置，可看门狗逃生页仍弹出、点「重试」后主页**数据全空**、重启 app 即恢复——数据没真丢，是**并发双初始化打烂了可见状态**。
  - 根因数据流：
    1. `hibiki/lib/main.dart:344` 冷启动 `await appModel.initialise()`。慢冷启动（首启 / 慢存储 / 大库）下这个 init 只是**慢**、并未 hang。
    2. `hibiki/lib/main.dart:1309`+ 的 20s 加载看门狗（BUG-572/TODO-1260 引入）纯粹是 UI 逃生口——**不取消**那个在飞的 init。超 20s 翻 `_loadingTimedOut` 显示逃生页。
    3. 用户点「重试」→ `onRetry`（`hibiki/lib/main.dart:1327`+）调 `appModel.retryInitialise()`。修复前 `hibiki/lib/src/models/app_model.dart` 的 `retryInitialise()` **无任何 in-flight 守卫**：`_databaseOpened==true` 时直接 `await _database.close()` 关掉**首个 init 正在用的 DB**，再 `await initialise()` 起**第二个并发 init**。
    4. 两个 init 抢同一批可变字段（`_database` / `_prefsRepo` / `dictRepo` / `_isInitialised`），谁先 `notifyListeners()` 就用谁半加载的 repo → 主页渲染空数据。重启是单次干净 init → 数据回来。
  - 连带文案错误：`hibiki/lib/src/storage/app_paths.dart:90` `_resolveDataRoot()` 在 `!isDesktopPlatform` 时**直接 return null**——自定义数据根 + 2s 超时回退**是纯桌面逻辑**，移动端 documents/support 恒走 `path_provider` 默认路径。故看门狗文案「数据存储位置设在未连接网络盘 / 用默认位置启动」（`loading_slow_message`）在手机上既不适用又吓人（重试根本不换位置）。
- **[x] ① 已修复** — 两道结构不变量让「并发双 init」根本不可能 + 移动端文案（分支 `worktree-bug-init-retry-race`）：
  1. `hibiki/lib/src/models/app_model.dart`：公开 `initialise()` 改为**带 in-flight 守卫的同步包装**（新增字段 `_initInFlight`）——已有 run 在飞时复用同一 future，绝不起第二个；真正的一次性 init 体搬到 `_initialiseOnce()`（内部 catch，永不 rethrow，完成后 `whenComplete` 清 `_initInFlight`，故 error 后的干净重起仍可用）。
  2. `hibiki/lib/src/models/app_model.dart` `retryInitialise()`：在 `_database.close()` 教条式拆卸**之前**先检查 `_initInFlight`，在飞就 `await` 它并 `return`——init 在飞=慢启动而非 hang，await 即可（成功出数据 / 失败落 `_initError`），**绝不关它正在用的 DB**。
  3. `hibiki/lib/src/startup/loading_watchdog_view.dart` + i18n key `loading_slow_message_mobile`（17 语言，经 `tool/i18n_sync.dart --add` + `dart run slang`）：移动端（`defaultTargetPlatform` android/iOS，或显式 `isMobile`）改显不提「默认位置」的安心文案；桌面保留掉线盘解释。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/models/app_model_init_retry_race_guard_test.dart`：源码扫描守卫（沿 BUG-207 范式，~2900 行 init 序列无法在 host 单测真实驱动）——钉住 ①公开 `initialise()` 是带 `_initInFlight` 守卫的同步包装、init 体在 `_initialiseOnce()`；②`retryInitialise()` 的 `_initInFlight` 短路 + `return;` 必须早于 `_database.close()`。撤修复任一 → 守卫红。
  - `hibiki/test/startup/loading_watchdog_view_test.dart`：新增移动端文案用例（`isMobile:true` 显 `loading_slow_message_mobile`、不含桌面 `loading_slow_message`），桌面用例改 `isMobile:false`。
- **备注**：`flutter analyze`（4 改动文件）+ `flutter test`（view 5 / guard 2 / i18n+md3 77）全绿。**待真机验收**：手机上人为拖慢冷启动触发 20s 看门狗（大库 / 慢存储），点「重试」应**照常出全量数据**（不再空），文案不再提「默认位置」。与本地不入库的 `docs/REGRESSION_BUGS.md` 区分。
