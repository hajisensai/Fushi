## BUG-1324 · 同步报告把鉴权失败压成一行字符串：UI 只剩「N 项失败」
- **报告**：2026-08-01（TODO-2462；PR#644 修 BUG-1311 时有意留下的清理条件）
- **真实性**：✅ 真 bug，独立缺陷。根因是**数据结构**：
  `hibiki/lib/src/sync/sync_orchestrator.dart:190` 的 `final List<String> errors`。
  逐维度 `catch (e) { report.errors.add('<label>: $e'); }`（全文 35 处）在 `$e` 被拼进
  字符串的那一刻，异常类型就死了；`SyncAuthError` 与网络抖动、404、JSON 解析失败同格。
  BUG-1311 点名的 `:527`（`_syncServiceConfigLive`）只是最稳定复现的那一处——host 对明文
  会话**必然**返回 403，于是每一轮同步都稳定产出一条
  `service config live sync: SyncAuthError: Authentication failed`。

  唯一的用户可见消费方是 `hibiki/lib/src/sync/manual_sync_ui.dart:37-39`：
  ```dart
  return r.errors.isEmpty ? done
      : '$done${t.sync_now_failed_suffix(count: r.errors.length)}';
  ```
  **只读 `errors.length`**。所以无论错误里写了什么，用户永远只看到「同步完成 · 无新增 ·
  1 项失败」——一句不含任何可操作信息的话。另一个消费方
  `sync_auto_trigger.dart:120-126` 把字符串扔进 `ErrorLogService`，用户看不到。
- **[x] ① 已修复** — 修数据结构，不给 `:527` 打特例补丁：
  - `sync_orchestrator.dart:191-197`：`SyncRunReport` 新增
    `final List<SyncAuthFailure> authFailures`，与 `errors` **并存**（日志行一字不变，
    信息只增不减）。
  - `sync_orchestrator.dart:240-268`：新增 `noteError(String label, Object error)`——
    字符串照旧 `errors.add('$label: $error')`，若它是 `SyncAuthError` 则**额外**在
    `authFailures` 留一份带 `kind` / `serverReason` 的值；`_addAuthFailure` 按
    (kind, message, serverReason) 去重（一次 401 会让一轮几百本书逐本失败，用户只需要
    知道「凭据被拒了」一次）。`mergeFrom` 同步合并并去重（option B 双通道）。
  - `sync_orchestrator.dart` 全文 **31 处** `report.errors.add('<label>: $e')` 机械改为
    `report.noteError('<label>', e)`，产出的字符串逐字节相同。
    **粒度判断**：改的是「每一个持有异常对象的 catch 点」，不是「所有 35 处」——
    剩下 5 处（`:800/:1064/:1926/:2123/:2180`）压根没有异常对象（「host 没有该端点」
    「本地文件不存在」这类自述性错误），没有类型可分流，保持原样。这条界线是
    「有没有异常」，不是「改到哪算够」，所以不会留下「为什么这个特殊」的问题。
  - `manual_sync_ui.dart:37-52`：`summarizeSyncReport` 在「N 项失败」后追加一句
    `friendlySyncAuthFailure(auth.kind, auth.serverReason)`（取去重后的第一条）。
    无鉴权失败时输出**逐字不变**。
  - 措辞与 BUG-1323 的异常路径共用 `sync_error_messages.friendlySyncAuthFailure`，
    同一件事不会在两条路径上说两种话。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_auth_error_kind_test.dart`
  的后两个 group（`BUG-1324 鉴权失败必须带类型活到 UI` /
  `BUG-1324 「N 项失败」不再是唯一一句话`，共 11 test）：
  - **契约护栏**：`noteError` 产出的日志行与改动前逐字相同
    （`'service config live sync: SyncAuthError: Authentication failed'`）；零失败与
    非鉴权失败时 `summarizeSyncReport` 输出逐字不变。
  - **不许扩大化**：`SyncBackendError` / `FormatException` 不进 `authFailures`。
  - 去重：200 条同因失败 → `errors` 200 条、`authFailures` 1 条；不同原因分别留一条；
    `mergeFrom` 双通道合并后仍去重。
  - **用户看到什么**：403 时摘要里出现 `HTTPS required for service config` 且
    **不含** `t.sync_err_auth_expired`；401 时摘要含 `t.sync_err_auth_expired`。
  - **变异实测两方向**见 PR 描述：把 `noteError` 里的 `if (error is! SyncAuthError)
    return;` 改成无条件 `return`（等价于回到裸 `errors.add`）→ 8 red；反向替换还原 → 全绿。
- **备注**：`SyncRunReport.errors` 的 `List<String>` 类型**没有**改成结构化列表——
  `sync_auto_trigger.logSyncReportErrors`、`summarizeSyncReport` 以及十余个测试
  （`sync_orchestrator_live_*.dart` 的 `expect(report.errors, isEmpty)` 等）都依赖它，
  换类型的收益全部可以由并存的 `authFailures` 拿到，代价却是一大片无关改动。
