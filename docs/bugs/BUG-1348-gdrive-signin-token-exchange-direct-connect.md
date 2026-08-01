## BUG-1348 · 谷歌云盘桌面登录：token 交换裸直连不走代理，浏览器已授权但 app 超时
- **报告**：2026-08-01（用户：「我的谷歌网页版显示登入 返回软件显示超时」，并问是不是 API 限额）
- **真实性**：✅ 真 bug。用户日志 `hibiki_share_1785597048095939.txt` 记录 22:18–23:10 共 10 次 `SyncSettings.signIn` 全败，两种失败各有各的根因：
  - **8×** `ClientException with SocketException: 信号灯超时时间已到 (errno = 121), address = oauth2.googleapis.com, uri=https://oauth2.googleapis.com/token`，栈顶 `obtainAccessCredentialsViaCodeExchange` → `GoogleDriveAuth.authenticate (google_drive_auth.dart:198)`。
  - **2×** `SyncAuthError: Timed out waiting for authorization`，栈顶 `runDesktopOAuthLoopback (desktop_oauth.dart:78)`。
- **不是 API 限额**：Drive 配额/限流是 HTTP 403 `rateLimitExceeded` / 429，`sync_error_messages.dart` 有专门映射（`sync_err_quota` / `sync_err_forbidden`），永远不会显示成「连接超时」。何况失败发生在**登录阶段**，此时一个 Drive API 都还没调用过，只碰了 OAuth token 端点——那个端点不按用户配额限流。

### 根因（4 条，互相独立）

**① 桌面登录横跨两个网络栈，第二段是硬直连** —— `google_drive_auth.dart:204`（原）`final baseClient = http.Client();`

浏览器那半程走系统代理，所以用户看到「谷歌网页版显示登入」；app 这半程拿授权码换 token 用的是裸 `http.Client()`。Dart 的 `HttpClient` 默认 `findProxy` 为空，**连 `HTTPS_PROXY` 环境变量都不读**，更不读 clash/v2ray 写进 Windows 注册表 `HKCU\...\Internet Settings\ProxyServer` 的系统代理。于是这一段被钉死为直连 Google，在需要代理的网络下是**必然**失败，不是偶发抖动。`restoreDesktopAuth` / `refreshAuth` 走同一条裸路径，所以即便某次侥幸登录成功，重启后刷新 token 同样超时（用户会当成「又掉登录」）。

讽刺的是仓库里早有正确实现 `applyUpdateProxy()`（`update_checker_net.dart:272`，优先级 env > GUI 系统代理 > DIRECT，Windows 读注册表 / macOS `scutil` / Linux `gsettings`，另支持用户手填代理），但它住在 update_checker 库的 **part 文件**里——而结构守卫钉死了「part 文件不得自带 import」，同步层根本没法复用它。同一台机器上「更新检查能走代理、云同步不能」，这就是结构性缺口本身。

**② 同步层出站请求没有连接超时** —— `sync_http.dart` 有带 60s `connectionTimeout` 的 `syncHttpClient`，但 Google 这条路径没用它，吊到 OS 默认，Windows 上表现为 `errno = 121`（ERROR_SEM_TIMEOUT）。

**③ loopback 超时被错误分类成「登录已过期」** —— `sync_error_messages.dart:67`（原）

`SyncAuthError('Timed out waiting for authorization')` 的消息里带 "authorization"，被 `error is SyncAuthError && l.contains('auth')` 这条分支抢先捕获，映射成 `sync_err_auth_expired`。「浏览器回调没回来」被说成「凭据坏了」，把用户指向重新登录这条死路——而重新登录会再次走进同一个死胡同。判据用字符串猜类型，本身就是缺陷。

**④ redirect_uri 用 `localhost` 而服务器只绑 IPv4** —— `desktop_oauth.dart:37/46`（原）

服务器 `HttpServer.bind(InternetAddress.loopbackIPv4, port)`，redirect 却写 `http://localhost:<port>`。`localhost` 是个**名字**，得先过 DNS 解析（Windows 上通常先解析到 `::1`）和代理路由：全局模式且 bypass 列表不含 localhost 的代理会把回调转发给代理服务器，授权码永远回不到 app，5 分钟后死在超时上——正是日志里那 2 次。

### 修复

- **[x] ① 已修复** — commit `<pending>`
  - 代理层从 `update_checker_net.dart`（part）提取为独立库 `hibiki/lib/src/utils/net/app_proxy.dart`，`applyUpdateProxy` → `applyAppProxy`。这是全应用唯一的出站代理真相源，更新检查 / 云同步 / torrent 下载共用。
  - 新增进程级 `appUserProxyReader`，`AppModel._initialiseOnce()` 偏好装载后接到 `prefsRepo.updateCustomProxy`。同步层单例拿不到 `AppModel`，靠沿调用链穿 `userProxy` 参数迟早会漏一处（漏一处 = 一条不走代理的暗路，本 bug 即是）。
  - `sync_http.dart` 新增 `createSyncHttpClient()`（独占）/ `obtainSyncHttpClient()`（共享惰性单例）/ `resetSyncHttpClient()`，两个工厂都装 `applyAppProxy` + `kSyncConnectionTimeout`。`syncHttpClient` 顶层同步单例删除——它是同步构造的，而代理解析要跑 `reg query`/`scutil`/`gsettings`，这正是它当年没有代理的原因。Dropbox / OneDrive / PKCE 共 15 处调用点改走异步取用。
  - `google_drive_auth.dart` 三处（`authenticate` / `restoreDesktopAuth` / `refreshAuth`）改用 `createSyncHttpClient()`。
  - `SyncAuthFailureKind` 加第三态 `browserTimeout`；`desktop_oauth.dart` 超时改抛带类型的错误；`sync_error_messages.dart` 把「有类型的鉴权失败」整体提到字符串猜测区之前一次分派掉。
  - `runDesktopOAuthLoopback` 加 `host` 参数（默认仍是 `localhost`，Dropbox 注册了 `http://localhost:9004`、Entra 注册了 `http://localhost`，不能动）；Google 传 `127.0.0.1`（Google 桌面客户端接受任意回环 redirect，无需在 Console 预注册精确 URI）。
  - 文案：新增 `sync_err_browser_timeout`（17 语言）；`sync_err_timeout` 补「请检查网络或代理设置」（用户就是因为这句话没给方向才来问是不是限额）；设置项「自定义更新代理」→「自定义网络代理」，副标题写明作用于更新检查 / 云同步 / 下载（持久化 key `update_custom_proxy` 冻结不动）。

- **[x] ② 已加自动化测试** — `hibiki/test/sync/oauth_proxy_and_browser_timeout_test.dart`（11 例）
  - 行为层：`appUserProxyReader` 设值后 `applyAppProxy(client)` 对 `https://oauth2.googleapis.com/token` 解析出 `PROXY host:port`（即「代理配置能否到达同步层」这条真链路）；显式 `userProxy` 仍优先；非法值 fail-open 不切网。
  - 行为层：`friendlySyncError(SyncAuthError(..., browserTimeout))` == `t.sync_err_browser_timeout` 且 ≠ `t.sync_err_auth_expired`；三种 kind 各说各的话；真正的 401 仍说「登录已过期」（无误伤）。
  - 源码守卫：`google_drive_auth.dart` 无裸 `http.Client()` 且恰好 3 处 `createSyncHttpClient()`；`sync_http.dart` 两个工厂都装代理 + 超时且有 `resetSyncHttpClient`；loopback 超时带 kind；类型分派排在字符串猜测之前（比位置前先剥注释，否则会命中解释历史错误的注释本身）；Google 用 `127.0.0.1`。
  - `update_checker_structure_guard_test.dart` 调头守新不变式：代理实现**禁止**回流 part。
  - 6 个守卫全部做过变异实测（逐条改坏 → 见红 → 反向替换还原），无一假绿。

- **备注**：
  - WebDAV / FTP / SFTP 未接代理，有意为之——它们指向用户自建服务器（常在局域网或自有域名），强行套代理反而会断掉本来通的连接。
  - `host: '127.0.0.1'` 的前提是本仓 Google client 为 **Desktop app** 类型（`_placeholderClientSecret` 命名、`google_oauth_secret.dart` 文档均如此表述）。万一真机验证出现 `redirect_uri_mismatch`，把那一行删掉即回退到 `localhost`（默认值），其余修复不受影响。
  - 用户机器上代理是否放行回环地址无法从本机验证；根因 ① 的修复不依赖这一点，根因 ④ 是把「依赖 DNS + 代理 bypass 两个外部条件」降级成「只依赖服务器自己绑的那个 IP」。
