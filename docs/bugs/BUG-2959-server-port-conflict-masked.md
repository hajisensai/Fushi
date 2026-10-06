## BUG-2959 · 服务端端口被占时只报drift Bad state No element
- **报告**：2026-10-06（本机试跑 `fushi_server serve` 时发现：本机 Fushi app 的互联 host 占着 38765 / 6881，服务端起不来，终端只有一段 `Unhandled exception: Bad state: No element`（drift `ServerImplementation._loadExecutor` ← `VideoDownloadSubscriptionService._drain`），退出码 255，看不出是端口问题）
- **真实性**：✅ 真 bug。`HeadlessHost.start()`（`packages/fushi_server/lib/src/headless_host.dart`）先 `downloads.start()` 起下载管线（订阅服务随之 `checkNow()` 开事务），再 `server.start()` 绑端口；绑端口抛 `SyncServerPortInUseException` 时已起的管线无人收回，`cli.dart` 的 `_serve` 返回 75 → `_Runtime.dispose()` 关库，在途的订阅事务撞上已关的 drift 连接，未捕获异常崩掉进程，`端口被占用` 那行连同正确退出码一起被吞。半途失败的启动没有回滚，是生命周期泄漏。
- **[x] ① 已修复** — `ce1368ad33`：`server.start()` 失败时走与 `stop()` 同一条拆卸路径 `_stopPipelines()`（停下载管线并等在途订阅检查落地、再关刮削）后重抛。原始失败路径实测：同配置下现在打印 `端口被占用: SyncServerPortInUseException: port 38765 is in use`，退出码 75。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/headless_host_start_failure_test.dart`（先占一个端口、配 qBittorrent 让管线必起，断言抛端口异常且 downloads / subscriptions / videoScrape 均已收回；变异实测：去掉回滚即红 `Expected: null, Actual: ServerDownloadHost`）。
- **备注**：
