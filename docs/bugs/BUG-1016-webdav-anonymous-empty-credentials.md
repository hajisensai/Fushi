## BUG-1016 · WebDAV/FTP 匿名同步：空用户名密码被硬拦

- **报告**：2026-07-22（用户）
- **现象**：同步与备份 → WebDAV 后端只填服务器地址（`127.0.0.1:1919`），用户名/密码留空，点「测试连接」报 `连接失败: 缺少字段`。匿名 / 无鉴权 WebDAV 无法使用。
- **真实性**：✅ 真 bug。两处根因：
  - `hibiki/lib/src/sync/sync_settings_schema/backend_config.part.dart:79` — WebDAV `_testConnection` 硬校验 `url.isEmpty || username.isEmpty || password.isEmpty`，把用户名/密码也当必填，空账密直接报「缺少字段」。（`_saveCredentials` 64-66 已允许存空 → null，仅测试连接这一处一刀切。）
  - `hibiki/lib/src/sync/webdav_ops.dart:32-33,73` — `_authHeader` 恒构造为 `Basic base64('user:pass')` 并每请求必发；账密都空时发的是 `Basic base64(':')`，匿名服务器多半仍回 401。真正匿名请求应根本不带 `Authorization` 头。
  - 同类：`hibiki/lib/src/sync/ftp_sync_backend.dart:689` — `_connect` 硬要求 `_host && _username && _password` 全非 null，连"有用户名无密码"的服务器都拦，且与 `testConnection`（放行空账密）不一致 → 匿名 FTP 登录被 ops 层拦掉，「测试能过 / 实际同步失败」。
  - SFTP（密码/私钥二选一，key-only）与 Hibiki 互联（token 为设备身份，必填合理）不属本 bug，不动。
- **[x] ① 已修复** —
  - `backend_config.part.dart` WebDAV 校验改为只 `if (url.isEmpty)`；账密留空放行。
  - `webdav_ops.dart` `_authHeader` 改为 `String?`：用户名**和**密码都空 → null，`buildRequest` 据此跳过 `Authorization` 头（有任一凭据时字节完全不变）。
  - `ftp_sync_backend.dart` 新增 `@visibleForTesting static ftpLoginCredentials(user, pass)` 归一（空用户名→`anonymous`，空密码→`''`）；`_connect` 只要求 `_host != null`，`testConnection` 与 `_connect` 均复用该归一，消除不一致、支持匿名 FTP。
  - 提交：（见分支 worktree-webdav-anon-creds）
- **[x] ② 已加自动化测试** —
  - `hibiki/test/sync/webdav_ops_anonymous_test.dart`：进程内 HttpServer 断言——空账密 `testConnection()` 不带 `Authorization` 头且成功；有账密时带 `Basic ...`。
  - `hibiki/test/sync/ftp_anonymous_credentials_test.dart`：`ftpLoginCredentials` 单测——空/空→(`anonymous`,``)、有用户名无密码→(`user`,``)、全有→原样。
- **备注**：WebDAV 匿名路径已用进程内 mock 端到端验证。FTP 匿名 **live** 登录依赖 `FTPConnect` 库对 `user:'anonymous'/pass:''` 的行为，需真实匿名 FTP 服务器验收（外部系统，无法本地端到端）；纯凭据归一逻辑已单测覆盖。
