## BUG-815 · 启动数据根不可达/看门狗重试致「数据全空」观感(移动端竞态 + 桌面静默回退空默认库)
- **报告**：2026-07-14（用户：截图「启动耗时超出预期」页 + 追报「电脑也不行，我数据正常在，你给我弄没了」）
- **真实性**：✅ 真 bug（两条独立根因，观感都是"数据全空、重启就好"，**数据从未真丢**）。用户桌面真实数据核实完好：`flutter.data_root=D:\APP\HIBIKI_date`，`D:\APP\HIBIKI_date\support\hibiki.db` 27MB 干净关闭、默认位置无残留空库。
- **【桌面根因·主】静默回退空默认库**（真正吓到用户的那条）：`hibiki/lib/src/storage/app_paths.dart` `_resolveDataRoot()` 对自定义数据根做 2s 存在性探测，盘一慢（休眠唤醒/杀软/高负载）就误判不可用 → **静默退回 `path_provider` 默认空位置**打开 → 满屏全空，用户以为数据被清空（真库其实原封不动在 D 盘），甚至可能在空态里把新内容写进错误位置。这是 BUG-572 兜底"能开就行"的设计副作用。
- **【移动端根因·次】看门狗重试并发竞态**：手机 `_resolveDataRoot` 非桌面恒 return null（无自定义根），但慢冷启动 >20s 触发加载看门狗（`hibiki/lib/main.dart` 20s，BUG-572/TODO-1260），它**不取消**在飞的首个 `initialise()`；点「重试」→ `retryInitialise()` **无 in-flight 守卫**，`_databaseOpened` 真时 `await _database.close()` 关掉在飞 init 正用的 DB 再起第二个并发 init，两 init 抢 `_database`/repos/`_isInitialised` → 半加载 repo 渲染空数据。
  - 根因数据流：
    1. `hibiki/lib/main.dart:344` 冷启动 `await appModel.initialise()`。慢冷启动（首启 / 慢存储 / 大库）下这个 init 只是**慢**、并未 hang。
    2. `hibiki/lib/main.dart:1309`+ 的 20s 加载看门狗（BUG-572/TODO-1260 引入）纯粹是 UI 逃生口——**不取消**那个在飞的 init。超 20s 翻 `_loadingTimedOut` 显示逃生页。
    3. 用户点「重试」→ `onRetry`（`hibiki/lib/main.dart:1327`+）调 `appModel.retryInitialise()`。修复前 `hibiki/lib/src/models/app_model.dart` 的 `retryInitialise()` **无任何 in-flight 守卫**：`_databaseOpened==true` 时直接 `await _database.close()` 关掉**首个 init 正在用的 DB**，再 `await initialise()` 起**第二个并发 init**。
    4. 两个 init 抢同一批可变字段（`_database` / `_prefsRepo` / `dictRepo` / `_isInitialised`），谁先 `notifyListeners()` 就用谁半加载的 repo → 主页渲染空数据。重启是单次干净 init → 数据回来。
  - 连带文案错误：`hibiki/lib/src/storage/app_paths.dart:90` `_resolveDataRoot()` 在 `!isDesktopPlatform` 时**直接 return null**——自定义数据根 + 2s 超时回退**是纯桌面逻辑**，移动端 documents/support 恒走 `path_provider` 默认路径。故看门狗文案「数据存储位置设在未连接网络盘 / 用默认位置启动」（`loading_slow_message`）在手机上既不适用又吓人（重试根本不换位置）。
- **[x] ① 已修复** —（分支 `worktree-bug-init-retry-race`）：
  - **桌面（主）**：`hibiki/lib/src/storage/app_paths.dart` 新增 `DataRootUnavailableException` + `AppPaths.resolve()` 预检——桌面配置了自定义根但 2s 探测不可达时**抛异常，绝不静默派生空默认根**（探测/读配置抽成 `_probeDataRootExists`/`_configuredDataRootPath`）。`hibiki/lib/src/models/app_model.dart` catch 该异常置 `_dataRootUnavailable`（不设 `_initError`）；`hibiki/lib/main.dart` 在裸 loading 分支前渲染「数据位置未响应」逃生屏：默认「重试」(`retryInitialise`，盘醒了用回真库) + **显式**「仍用默认位置启动」(`retryInitialiseWithDefaultRoot` → 置 `AppPaths.forceDefaultRootForSession`，仅本次进程、不动配置与原盘数据)。i18n 三 key `data_root_unavailable_title/message($path)/use_default_button`（17 语言）。用户已定调「保留逃生口但写清楚」。
  - **移动端（次）**：公开 `initialise()` 改**带 `_initInFlight` 守卫的同步包装**（复用在飞 future，绝不起第二个），init 体搬 `_initialiseOnce()`；`retryInitialise()` 在 `_database.close()` 前先短路在飞 init（await+return，绝不关它正用的 DB）。看门狗文案 `hibiki/lib/src/startup/loading_watchdog_view.dart` 移动端改显不提「默认位置」的 `loading_slow_message_mobile`；桌面保留掉线盘解释。
- **[x] ② 已加自动化测试** —（源码序列无法 host 单测真实驱动，沿 BUG-207/572 范式）
  - `hibiki/test/storage/app_paths_data_root_timeout_test.dart`（改契约）：配置根不可达→`resolve()` **抛 `DataRootUnavailableException`**（不静默回退、快速不 hang）；`forceDefaultRootForSession=true`→退回默认根；无自定义根→不抛；正常根→正常派生；源码守卫（探测走 `_probeDataRootExists` 的 `exists().timeout`、禁 `existsSync()`）。
  - `hibiki/test/startup/data_root_unavailable_escape_guard_test.dart`（新）：main.dart 逃生屏在 loading 分支前 + 接双按钮；app_model `retryInitialiseWithDefaultRoot` 置 force 开关、catch 只置 `_dataRootUnavailable` 不设 `_initError`。
  - `hibiki/test/models/app_model_init_retry_race_guard_test.dart`（新）：钉 `initialise()` in-flight 守卫 + `retryInitialise` 短路早于 `_database.close()`。
  - `hibiki/test/startup/loading_watchdog_view_test.dart`：移动端文案分支。
- **备注**：`flutter analyze`（8 项）+ `flutter test`（app_paths 5 / escape 2 / race 2 / view 5 / i18n+md3 全绿，合计 89）全绿。**待真机验收**：①桌面把数据位置设到可断开的盘、断开后冷启动 → 应见「数据位置未响应」屏（不再全空/不再静默默认），接回盘点「重试」数据回来；显式点「仍用默认位置启动」进空态、原盘数据不动、下次启动自动用回。②手机拖慢冷启动触发 20s 看门狗点「重试」→ 照常出全量数据。与本地不入库的 `docs/REGRESSION_BUGS.md` 区分。
