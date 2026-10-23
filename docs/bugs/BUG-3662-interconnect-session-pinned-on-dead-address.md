## BUG-3662 · interconnect-session-pinned-on-dead-address
- **报告**：2026-10-23（用户：反馈 XVEF3huDTF，Android 3.0.1-debug.20685「Fushi 同步速度变慢，要 8-9 分钟才能同步完」）
- **真实性**：✅ 真 bug。日志：host 从 192.168.3.18 换到 .32（01:11 用 .32 重新配对），01:21 那轮同步的报告里 `prune root spill (list root)` 仍打向 .18，且以 OS 级 `errno = 110`（已建立连接的 TCP 重传超时，分钟级）失败；截图 01:18 停在「同步阅读数据 (11/15)」，到 01:21 才结束，单本 ~45 s。两处根因：
  1. `fushi/lib/src/sync/interconnect_sync_backend.dart` `_buildProvisionalOps`（restoreAuth 时建在候选[0]上的暂定句柄）不带 `onConnectivityError`；`_ensureResolved` 选中的地址若就是候选[0]，原样沿用该句柄不重建。会话一旦落在第一条地址上，它掉线后没有任何东西把会话置脏，整轮每本书、每个请求都继续打向死地址各等一次超时（BUG-1693 的故障切换在这条路径上从未生效）。`_sendBounded` / `_readBodyBounded` 的超时也从不通知置脏。
  2. `fushi/lib/src/sync/webdav_ops.dart` 自有的小请求（PROPFIND / MKCOL / JSON GET / PUT 字节 / HEAD / DELETE —— 同步每本书的文件箱读写）没有请求级封顶，只有 60 s connect 上限；连接建立后对端掉线要等到 OS 级 TCP 超时。
- **[x] ① 已修复** — 会话句柄收敛为唯一构造点 `_sessionOps`（暂定与解析后共用，都带 `onConnectivityError` 与 `requestTimeout`）；`WebDavOps` 新增可选 `requestTimeout`（connect / 响应头 / 响应体各阶段封顶，超时按连接类失败上报，云 WebDAV 不传、语义不变）；`_sendBounded` / `_readBodyBounded` 的失败经 `WebDavOps.reportConnectivityFailure` 置脏会话。另：`SyncOrchestrator.run` 记分阶段耗时与最慢的 5 本书，整轮 ≥ 30 s 时写诊断日志 `SyncRunReport.timing`（原日志只有错误，看不出慢在哪一步）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_request_timeout_test.dart`「XVEF3huDTF 文件箱小请求封顶 + 掉线后换路」组（停摆 host：文件箱 PROPFIND 在超时内失败；落在候选[0] 的会话超时后下一次操作重新选路；`_sendBounded` 超时同样置脏；变异实测：暂定句柄去掉回调后两条变红）；`fushi/test/sync/sync_run_report_timing_test.dart`。
- **备注**：未在真机复测。单本 ~45 s 是否全部来自这条路径没有逐请求证据（客户端日志只记错误）；新版的 `SyncRunReport.timing` 诊断行能直接给出答案，若仍慢请附新日志。
