## BUG-1323 · webdav_ops 把 401/403 压成同一个 SyncAuthError：403 被谎报成登录过期还触发登出
- **报告**：2026-08-01（TODO-2462；PR#644 修 BUG-1311 时有意留下的清理条件）
- **真实性**：✅ 真 bug，独立缺陷。根因 `hibiki/lib/src/sync/webdav_ops.dart:259-262`：
  ```dart
  if (statusCode == 401 || statusCode == 403) {
    throw SyncAuthError('Authentication failed');
  }
  ```
  401（凭据不被接受）和 403（凭据**已被接受**，服务端按策略拒绝这一次请求）是两件不同
  的事，被压成同一个异常 + 同一句常量字符串；`context` 参数在这条分支里连带丢掉，
  响应体（服务端唯一说明「为什么」的地方）从来没被读过。同文件另有两处独立的
  401∨403 合并：`webdav_ops.dart:91`（`testConnection`）、`:131`（`propfindChildren`）。
  这层被 **webdav + interconnect（28 处 `checkStatus`）+ media/source_library（2 处）**
  共用，故一处压平污染全部 HTTP 同步路径（ftp/sftp/OAuth 系不经此处）。

  **两层用户可见后果**：
  1. **文案说谎**：`hibiki/lib/src/sync/sync_error_messages.dart:61-63` 的
     `error is SyncAuthError && l.contains('auth')` 对 `'authentication failed'` 恒真，
     于是 403 被渲染成 `t.sync_err_auth_expired`「登录已过期，请重新登录」，把用户引去
     反复重配一个根本没问题的凭据——BUG-1311 的原始症状。
  2. **毁会话**：`hibiki/lib/src/sync/manual_sync_ui.dart:178-193` 的
     `on SyncAuthError catch` **无条件** `backend.signOut(repo:) + clearCache() +
     clearFolderCache()`。一条服务端策略（如 host 对明文会话返回
     `403 HTTPS required for service config`，`hibiki_sync_server.dart:2197-2199`）
     就能把用户一个好端端的会话踢下线。
- **[x] ① 已修复** —
  - `hibiki/lib/src/sync/sync_backend.dart:37-48`：新增 `enum SyncAuthFailureKind
    { credentials, forbidden }`；`SyncAuthError` 加 `kind`（默认 `credentials`）与
    `serverReason` 两个字段 + `isForbidden` getter。
    **粒度判断：加字段而不是拆新异常类**——仓库里 20 处 `on SyncAuthError` /
    `is SyncAuthError` 全是 rethrow / 短路 / 登出语义（`ftp_sync_backend.dart` 13 处、
    `sftp_sync_backend.dart:526` `_guarded`、`interconnect_sync_backend.dart:72/98`
    探测短路、`sync_manager.dart:204`）。拆新类会让它们**静默停止捕获** 403，把
    「短路/上报」悄悄变成「吞掉/继续轮询」——那是把错误吞得更深，正好反向。
    另外 `hibiki/test/sync/pull_to_sync_wiring_guard_test.dart:99` 源码扫描守卫硬断言
    `manual_sync_ui.dart` 里必须有字面量 `on SyncAuthError catch`，改名即 CI 红。
    默认值让 30 余处既有抛出点（OAuth / 未配置 / FTP/SFTP 协议层）行为逐字不变。
  - `webdav_ops.dart:294-317`：`checkStatus(int, String, {String? serverReason})`
    401 → `credentials`（消息逐字不变）、403 → `forbidden` + `'Server refused (403):
    $context'`（把以前丢掉的 context 带回来）+ `serverReason`。可选具名参数 ⇒ 既有
    33 处调用点一行不改。
  - `webdav_ops.dart:44-64`：新增 `readSyncErrorBody(HttpClientResponse)`——**永不抛**
    （读原因失败绝不能盖掉原本要报的错）、**截到 300 字**（错误体可能是整页 HTML）、
    **5s 超时**（挂死的流不许拖住整轮同步）。
  - `webdav_ops.dart:117-131`（`testConnection`）、`:158-170`（`propfindChildren`）：
    403 分支改为读响应体当 `serverReason`。401 的判定仍**先于**任何流读取——反过来的话
    一个畸形错误体就能把鉴权失败盖成 `FormatException`。
  - `interconnect_sync_backend.dart:707-717`（BUG-1311 的现场 service-config GET）与
    `:775-782`（通用 `_listRemote`）：错误路径读体后传 `serverReason`。
  - `sync_error_messages.dart:6-14`：**类型分支放在 `_friendlyClause` 最前**，403 不再
    落进底下的字符串猜测；新 `friendlySyncAuthFailure(kind, serverReason)` 让异常路径与
    报告路径共用同一套措辞。新增 i18n `sync_err_forbidden` /
    `sync_err_forbidden_detail`（经 `tool/i18n_sync.dart --add`，17 语言 + `dart run slang`）。
  - `manual_sync_ui.dart:60-70`：抽出纯函数 `shouldSignOutOnAuthError(SyncAuthError)
    => !error.isForbidden`，catch 块改调它。403 不再登出；提示照常给，只是不动会话。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_auth_error_kind_test.dart`
  （27 test 全绿）。关键在于**钉住用户在两种情况下分别看到什么**，而不是只断类型：
  - 起真 `HttpServer` 回 403 + 响应体，断言 `testConnection()` / `propfindChildren()`
    把 `HTTPS required for service config` 原样带回；401 仍是 `credentials` 且消息逐字不变。
  - `friendlySyncError`：401 → `t.sync_err_auth_expired`（逐字未变）；403 有原因 →
    `t.sync_err_forbidden_detail(reason:)` 且 **`isNot(equals(t.sync_err_auth_expired))`**；
    403 无原因 → `t.sync_err_forbidden`。
  - 「403 的分流按类型走，不靠消息里有没有 auth 字样」：故意用 message
    `'authentication context: refused'`——把类型分支删掉它就会被字符串层抓成「登录已过期」。
  - `shouldSignOutOnAuthError`：credentials → true（TODO-836 契约不回归）、forbidden → false。
  - 负向：Google Drive 的 `insufficient_scope`（不经 `checkStatus`，kind 保持默认）仍走
    `t.sync_err_scope_upgrade`；404/5xx/2xx 契约不变。
  - **变异实测两方向**见 PR 描述：把 403 分支还原成 `401 || 403` 合并 → 6 red；
    删掉 `_friendlyClause` 的类型分支 → 3 red；`shouldSignOutOnAuthError` 改成
    `=> true` → 1 red；逐条反向替换还原 → 27 全绿。
- **备注**：**未做**的部分——`checkStatus` 的 33 个调用点里有 18 个在调用前已
  `await res.drain()`，它们的 403 仍拿不到服务端原文（只拿到状态码 + context，仍比改动前
  多）。把它们全改成「错误路径先捕体再 drain」需要逐个动上传/删除路径的流处理，与本缺陷
  无关且风险不成比例；本轮只做了本来就把体读出来的 GET 路径。`checkStatus` 保持同步签名
  （改成 `Future<void> checkStatus(HttpClientResponse, ...)` 会强制 33 处 `await` 并波及
  `media/source_library/source_file_system.dart` 两个 sync 层之外的调用方）。
