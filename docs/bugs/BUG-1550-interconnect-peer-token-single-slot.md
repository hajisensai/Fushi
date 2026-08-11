## BUG-1550 · 互联配对第二台对端后整体瘫痪：per-peer token 只有一个全局槽 + 401 株连全部候选
- **报告**：2026-08-11（用户：「互联有问题」「互联所有地方我感觉都有点问题」，无具体症状，由 TODO-2803 系统性体检沿代码路径查出）
- **真实性**：✅ 真 bug。凭据的**基数**与地址的基数不一致。
  - `fushi/lib/src/sync/sync_repository.dart:725`（改前）——所有对端地址共用一个偏好键
    `sync_hibiki_client_token`，而 `sync_hibiki_client_urls` 是一个**列表**。
  - `fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart:651`（改前）——配对成功
    只写这个全局键（`setFushiClientToken`）。LAN 发现里点谁配谁，每次都往地址列表
    `addFushiClientUrl` **append** 一条（`:1284`），所以列表里可以是**不同的 host**。
  - `fushi/lib/src/sync/fushi_sync_server.dart:901` `_issuePeerTokenOrFallback`——host 侧
    TODO-961 M1b 的 per-peer token 按 client 的稳定 `deviceId` **逐台派发**，A 的 token 在
    B 上根本无效。于是配对 B 就把 A 的凭据从唯一的槽里覆盖掉。
  - `fushi/lib/src/sync/interconnect_sync_backend.dart:47`（改前）——`resolveReachableFushiCandidate`
    对候选探测里的 `SyncAuthError` 是 **rethrow**，注释白纸黑字写着「所有候选共用一个
    token，一次拒绝即全部失败」。A 的地址排在列表前列、A 依然在局域网里可达，于是拿着
    B 的 token 撞 A 得 401 → 整条互联链路（书库/视频/进度/查词/制卡）全部瘫痪，B 永远轮不到。
  - `fushi/lib/src/sync/interconnect_post_transport.dart:105`（改前）同一形状：401 直接 `throw`，
    后面的候选一个都不试。
- **症状预测**：配对第二台设备后，互联整体报鉴权失败 / 远端库空白；第一台也再连不上；
  用户唯一的出路是手动把旧地址删掉——而这条线索完全不在 UI 上。
- **[x] ① 已修复** — 凭据下沉到地址行：`FushiClientUrl.token`（additive wire 字段，
  `sync_hibiki_client_urls` 已在 `deviceLocalPrefKeys` 设备本地清单里，不随备份出设备）；
  新增 `interconnectTokenFor(candidate, fallbackToken)`（行内优先、回落全局）、
  `SyncRepository.setFushiClientTokenForUrl` / `clearFushiClientUrlTokens`；
  `resolveReachableFushiCandidate` 与 `InterconnectPostTransport.post` 改为「记下 401、
  继续问下一台，全部失败才抛 `SyncAuthError`」；`InterconnectSyncBackend` 用选中候选的
  凭据建 `WebDavOps`（新增 `_activeToken` 镜像判断换台重建）、候选 token 进
  `_sessionSignature`、`_hasAnyCredential` 取代「全局 token 非空」判据；
  `FushiRemoteMiningClient.hasTarget` / `InterconnectMangaOcrClient` 三处同步改按候选取凭据。
  行上没有 token 的老配置一律回落全局键，升级路径逐字不变。提交见文末。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_peer_credential_test.dart`（新增，
  wire 往返 / 选择优先级 / 「配对 B 不覆盖 A」/ 手贴 token 清行内残留）、
  `fushi/test/sync/fushi_client_resolver_test.dart`（新增「一台被拒不挡下一台」「各用各的
  token」「无凭据候选跳过」，并把旧的「立即 rethrow」用例改写成新语义）、
  `fushi/test/sync/interconnect_post_transport_test.dart`（同上三条）。
  变异实测：把 resolver 的 `authError = e` 改回 `rethrow`、把 `setFushiClientTokenForUrl`
  砍成只写全局键、把 transport 的 401 改回 `throw` —— 三处各自转红（见提交说明），
  反向替换还原。
- **备注**：本条只修「凭据基数」这一根因。同一体检查出但**未修**的相邻问题另记：
  `restoreAuth` 的会话失效粒度、远端清单/封面请求缺超时、v1 `/api/pair` 绕过 PIN 强制、
  编辑地址保留旧指纹且无清除入口、`hostFingerprint` 回执解析后无人消费。
