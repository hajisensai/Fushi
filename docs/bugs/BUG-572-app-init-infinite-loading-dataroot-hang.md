## BUG-572 · App 偶发无限加载：自定义数据根掉线盘早期同步 IO 永不返回
- **报告**：2026-07-07（用户：）（TODO-1260）
- **真实性**：✅ 真 bug。根因是**某启动早期 await 的 Future 永不完成**（真 hang，不返回也不抛异常），而 `AppModel.initialise()` 顶层 try/catch 只接异常、接不住 hang，loading 分支又是**无超时**的裸转圈，唯 hang 无逃生 → 表现为「偶发无限加载」。最可能触发点：桌面自定义「数据存储位置」指向网络盘 / 移动盘，盘掉线时启动早期对该根做同步 IO 永不返回。
  - P0 主根因：`hibiki/lib/src/storage/app_paths.dart:113`（旧）`_resolveDataRoot` 用同步 `dir.existsSync()` 探测 data_root——盘掉线时这个阻塞式 `stat` 在**主 isolate** 上卡到 OS 层超时（Windows 对断链网络盘可达数十秒 / 不返回）。
  - 连带风险点：`hibiki/lib/src/models/app_model.dart` `_rebuildDictPathsCacheAsync`（对每本词典资源目录 `Directory(p).exists()`）与 `initialise()` 里 `Future.wait([thumbnailsDirectory.create ...])`——都派生自数据根，盘掉线时同样会 hang。
  - 结构缺陷：`hibiki/lib/main.dart:1204` loading 分支为无超时无逃生的 `CircularProgressIndicator`。
- **[x] ① 已修复** — 三层根治（提交见分支 todo1260-init-timeout）：
  1. `hibiki/lib/src/storage/app_paths.dart` `_resolveDataRoot`：同步 `existsSync()` → 带 2s 超时的异步 `dir.exists().timeout(2s, onTimeout: ()=>false)`（外加 try/catch）。超时 / 不存在都退回 `path_provider` 默认根。**数据安全**：pref 里自定义根路径原样保留、原盘数据一字节不动，仅本次启动改用默认根让 app 能开，盘恢复后下次启动自动用回自定义根（无迁移、无覆盖）。
  2. `hibiki/lib/src/models/app_model.dart`：新增 `_initIoTimeout=12s` + `_guardInitIo()`，把 `_prepareRuntimeDirectories()`（AppPaths.resolve）、运行时目录创建 `Future.wait`、`_rebuildDictPathsCacheAsync()` 三处对数据根的关键 await 叠超时。超时抛带步骤名的 `TimeoutException` → 顶层 catch → `_initError` 错误屏（有 Retry），把无限 hang 变可重试错误。
  3. `hibiki/lib/main.dart` + 新 `hibiki/lib/src/startup/loading_watchdog_view.dart`：loading 看门狗（20s）。裸转圈超时后改渲染 `LoadingWatchdogView`（说明文案 + 重试按钮），点重试复位看门狗 + `retryInitialise`。消除「无 escape」结构缺陷。
  4. 日志打点（`hibiki/lib/src/utils/misc/error_log_service.dart`）：新增 `init_step_breadcrumb.txt` 同步步进面包屑（`markInitStep`/`clearInitStep`），`initialise()` 每个高风险步骤前同步落盘、DONE 清空；下次启动读到残留折成 `AppInit.hangRecovered` 写进 error_log.txt，让 hang 可定位到卡在哪一步（存活用户强杀）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/storage/app_paths_data_root_timeout_test.dart`：坏 / 掉线数据根 → resolve() 在超时上限内快速退回默认根不 hang（wall-clock 断言）+ 正常根不误伤 + 源码守卫（禁止回归到阻塞式 `existsSync()`、强制 `exists().timeout(...)`）。
  - `hibiki/test/utils/misc/error_log_init_step_breadcrumb_test.dart`：`markInitStep` 同步落盘 / `clearInitStep` 清除 / 残留折成 `AppInit.hangRecovered` / 无残留不误报。
  - `hibiki/test/startup/loading_watchdog_view_test.dart`：未超时只转圈无重试 / 超时显示说明 + 重试按钮 + 点击触发 onRetry。
- **备注**：真机验收口径 = 桌面把数据存储位置设到一个可断开的盘（如 U 盘 / 网络盘），断开后冷启动 app，应在 2s 内退回默认根正常进主界面（不再无限转圈）；若仍卡，20s 后出现「重试」逃生口；下次连回盘启动自动用回自定义根。与本地不入库的 `docs/REGRESSION_BUGS.md` 区分。
