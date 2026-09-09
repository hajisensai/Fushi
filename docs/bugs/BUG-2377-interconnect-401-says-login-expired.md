## BUG-2377 · 互联对端 401 被误报为「登录已过期，请重新登录」
- **报告**：2026-09-09（用户：截图，同步与备份页，存储后端 = Fushi 互联）
- **真实性**：✅ 真 bug。用户点「立即同步」→ 上次同步「失败」→ toast「登录已过期，请重新登录。」
  互联的凭据是配对时对端发的 per-peer token，**应用里根本没有互联的登录入口**，
  这句话把用户指向一个不存在的操作。

  根因链（三段，缺一不可）：
  1. `fushi/lib/src/sync/webdav_ops.dart:167/246/404` —— `WebDavOps` 是**传输层**，
     对 WebDAV（用户名/密码）和互联（配对 token）一律抛默认的
     `SyncAuthError('Authentication failed')`（kind 默认 `credentials`，
     `sync_backend.dart:85`）。凭据模型的语义在这里丢失。
  2. `fushi/lib/src/sync/sync_error_messages.dart:75-77` —— 类型没了，文案层只能按
     字符串猜：`error is SyncAuthError && l.contains('auth')` → `sync_err_auth_expired`
     「登录已过期，请重新登录。」这是 OAuth 后端的措辞。
  3. 同文件 `:39-43` —— 另一条相邻缺陷：互联未配对时抛的
     `'Fushi server credentials not configured'` 命中 `contains('not configured')`
     → 返回 null → **裸英文原文直接上屏**。

  用户侧的真实事件是：对端把本机从已配对列表里删了（`FushiServerController` 删后清
  server 端 token 缓存，被删设备下一次请求立刻 401），或对端重置/重装后 token 换了。
  正确的可操作项是**重新配对**。

  破坏性那一半此前已由 BUG-1578 修掉（`shouldSignOutChannelOnAuthError` 对互联通道
  返回 false，故配对配置没有被 401 清空）——本单只剩文案/语义错配。

- **[x] ① 已修复** — 根因修在**凭据语义的归属**上，不是在文案文件里加分支：
  - `sync_backend.dart` 新增两个类型化语义 `SyncAuthFailureKind.pairingRejected` /
    `pairingNotConfigured`（沿用 BUG-1323/1348/1693 立下的「判据是类型，不是字符串」）。
  - `webdav_ops.dart` 的 `WebDavOps` 新增 `unauthorizedKind`（默认 `credentials`，
    WebDAV / 网络媒体源库行为逐字不变）：传输层只转达，**凭据语义由后端拥有者声明**。
  - `interconnect_sync_backend.dart` 全部 5 处 `WebDavOps` 构造点声明 `pairingRejected`；
    2 处「未配对」抛出点改带 `pairingNotConfigured`。
  - `interconnect_post_transport.dart` 的 401（远程查词/制卡 token）同样带 `pairingRejected`。
  - `manual_sync_ui.dart` 的穷举 switch 登记两个新值为**不登出**；
    `sync_error_messages.dart` 的 `friendlySyncAuthFailure` 按 kind 分派到新文案。
  - 新 i18n key `sync_err_pairing_rejected` / `sync_err_not_paired`，17 语言均为真翻译。
  - 提交：见本分支 `fix(sync): type interconnect auth failures`。

- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_auth_error_kind_test.dart`
  新增 group「BUG-2377 互联没有「登录」这回事」：
  - 行为层：同一个 401，WebDAV 仍是 `credentials`/「登录已过期」（不回归），互联变
    `pairingRejected`/「重新配对」；403 不被 `unauthorizedKind` 抢走；未配对不再摔裸英文。
  - 文案层：两条新文案断言不含「登录/登入/sign in」。
  - 登出层：两个新 kind 均不得触发登出。
  - 源码守卫：互联后端的 `WebDavOps(` 出现次数必须与 `unauthorizedKind:` 声明次数**相等**
    （新增构造点漏声明就红）；POST 传输层带类型；文案层的类型分派必须排在 `contains('401')` 之前。
  - `oauth_proxy_and_browser_timeout_test.dart` 的 `SyncAuthFailureKind.values` 穷举登记表
    补上两个新值（该守卫本就是为拦「新 kind 被默默归错边」而写）。
  - 验证：`flutter test test/sync test/i18n --no-pub` → 2584 条通过，exit 0。

- **备注**：`sync_err_not_configured`（「此构建未配置谷歌同步凭据」）是 Google 专用文案，
  不能复用给互联未配对——故另立 `sync_err_not_paired`。
