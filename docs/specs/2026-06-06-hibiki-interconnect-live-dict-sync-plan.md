# Plan · Hibiki 互联词典「直读对端」同步（废除 `__dictionaries__` 暂存，保持双向）

状态：**待用户审 + 真机验证**（后台环境无法验证 LAN/配对/多播）。关联：BUG-079（A 删除传播，已落地）、本文件 = B。

## 1. 背景与动机

当前词典同步对所有后端统一走「打包推送 + 拉取」经中转暂存目录 `__dictionaries__`：
- 客户端 `exportDictionaryPackage` → `<名>.hibikidict` → `putAsset` 到后端 `__dictionaries__/`；反向 `getAsset` 拉取导入（`sync_orchestrator.dart:278-361`）。
- 对 Hibiki 互联，host 是被动 WebDAV，`__dictionaries__/` 是它磁盘上的真实暂存目录，**和 host 实时词典资源目录 `dictionaryResourceDirectory` 是两个不同目录**。

后果（BUG-079）：union 永不删 + 暂存目录 → 任一设备删过的词典包永久留存 → 每次同步重拉大孤儿（幽灵 + 慢）。A 已用「删除传播」让暂存镜像实时词典缓解。

**B 的目标**：对 **Hibiki 互联（且仅互联）**，让词典同步**直接对端实时词典**收发，**彻底不经 `__dictionaries__` 暂存** → 结构上就不可能产生暂存孤儿；同时**保持双向**。云后端（GoogleDrive/WebDAV/Dropbox/OneDrive/FTP/SFTP）无「在线对端」，**继续走暂存 + A 的删除传播，不变**。

## 2. 核心约束（决定方案形状）

1. **orchestrator 后端无关**：`syncDictionaries` 用 `ensureNamespace/listChildren/getAsset/putAsset/findAsset/deleteAsset` 抽象。B 只能对互联开**一条专属词典路径**，不动其余 6 后端。→ 在 orchestrator 里按 `backend is HibikiClientSyncBackend`（或新增能力探测）分流到「live 词典同步」，否则走现有暂存路径。
2. **被动 host 必须变主动**：直读=客户端读 host 实时词典；要双向，客户端推来的词典 host 必须**主动导入进自己的 DB + 资源目录**（否则只能单向 host→client）。→ `HibikiSyncServer` 新增词典专属 HTTP 端点，并在 PUT 时调用 host 侧的词典导入逻辑。
3. **删除语义仍需显式**：纯 live 双向 union 仍分不清「对端删了 X」与「本端新增了 X」——删除会从对端被重新拉回。→ B 解决的是**暂存孤儿**（无暂存即无孤儿）；**删除传播仍依赖 A**（删本地→经端点 DELETE 对端）。二者正交。
4. **向后兼容**：旧版 peer 没有新端点 → 必须回退到 `__dictionaries__` 暂存路径，不能让新旧设备同步直接失败。→ 端点能力探测 + fallback。
5. **安全**：新端点必须沿用现有配对 token 鉴权（与 WebDAV 同一 `token`），拒绝未配对请求。

## 3. 设计

### 3.1 Host 端：`HibikiSyncServer` 新增主动词典端点（均带 token 鉴权）

- `GET  /api/dictionaries` → JSON：host 当前**实时**词典清单 `[{name, sizeBytes, contentHash}]`（从 host 的 `DictionaryMeta` 表 + 资源目录读，不是从暂存目录）。
- `GET  /api/dictionaries/<name>` → 流式返回 host 现 export 的 `<name>` 词典包（host 用与客户端相同的 `exportDictionaryPackage` 即时打包其实时词典；流式不入内存）。
- `PUT  /api/dictionaries/<name>` → 接收词典包，host **主动导入**（`importDictionaryPackage` 进 host 自己的 DB + 资源目录）；幂等：已存在同名则按 `contentHash` 决定跳过/覆盖。
- `DELETE /api/dictionaries/<name>` → host 删除其实时词典（DB + 资源目录），供 A 的删除传播在互联下生效。
- host 需要能访问词典导入/导出/删除逻辑：当前 `HibikiSyncServer` 不持有 `AppModel`。→ 经 `HibikiSyncServerController`（BUG-078 已让 AppModel 持有它）注入一个 `DictionaryHostService`（封装 export/import/delete + list，复用 `SyncAssetPackageService` 与 `AppModel.deleteDictionary`/import 路径）。**注意并发**：host 导入/删除自己的词典库需与 host 自身可能在跑的同步/查词串行（沿用 `runExclusiveWithSync` 或词典库级锁）。

### 3.2 Client 端：互联专属 live 词典同步

在 `syncDictionaries` 顶部分流：
```
if (backend supports live dictionaries)   // 探测 GET /api/dictionaries 是否 200
    await _syncDictionariesLive(report);  // 新路径，不碰 __dictionaries__
else
    await _syncDictionariesStaged(report);// 现有暂存路径（云后端 + 旧 peer）
```
`_syncDictionariesLive`：
1. `GET /api/dictionaries` 拿对端实时清单；本地 `getAllDictionaryMetadata` 拿本端清单。
2. 计算 `toPull = 对端有∧本端无`、`toPush = 本端有∧对端无`（union，删除交给 A）。
3. `toPull`：逐个（**有界并发 batch，顺带修 BUG-079 的 E「慢」剩余部分**）`GET /api/dictionaries/<name>` → `importDictionaryPackage` 本地。
4. `toPush`：逐个 `PUT /api/dictionaries/<name>`（host 主动导入）。
5. 进度 emit 用干净名（已对齐）。
6. 全程**不创建、不读写 `__dictionaries__`** → 无暂存、无孤儿。

### 3.3 与 A 的关系
- A（已落地）：删本地词典 → 删远端。互联下「远端」从「删暂存包」改为「`DELETE /api/dictionaries/<name>`」（A 的 `deleteRemoteDictionaryAsset` 需在互联走端点而非 `deleteAsset(__dictionaries__)`——B 落地时一并适配）。
- B：消除暂存孤儿 + 提供 live 双向通道。
- 合起来：删除即时双向生效、无暂存孤儿、无幽灵、不慢。

## 4. 影响范围 / 风险

- **改动面**：`hibiki_sync_server.dart`（新端点 + host 词典服务注入）、新 `DictionaryHostService`、`hibiki_client_sync_backend.dart`（能力探测 + 端点客户端方法）、`sync_orchestrator.dart`（`syncDictionaries` 分流 + live 实现）、`app_model.dart`（A 的传播在互联走端点）、i18n（若有新文案）。
- **风险**：① host 变主动 = 接收端导入有副作用（写 host 词典库），需鉴权 + 并发串行 + 失败隔离，**误用可污染 host 词典库**；② 向后兼容回退必须稳，否则新旧设备同步炸（违反 Never break userspace）；③ 大文件流式 import/export 的内存与中断处理；④ **我无法后台真机验证 LAN/配对/导入**。
- **不破坏**：云后端词典同步完全不变；互联其它资产（书/有声书/本地音频）不在本计划内。

## 5. 测试策略
- 单元：端点 handler（鉴权、list/get/put/delete 行为，用临时目录 + 内存 DB）、`_syncDictionariesLive` 的 diff（toPull/toPush 计算，纯函数化）、能力探测 fallback。
- 集成（**需真机/双设备，待用户**）：手机↔电脑互联，跑 live 词典双向同步、删除双向传播、与旧版 peer 的 fallback、断网中断恢复。

## 6. 分阶段落地建议
1. Phase 1：host `GET /api/dictionaries` + `GET /api/dictionaries/<name>` + client 能力探测 + `_syncDictionariesLive` 的**只拉不推**（先单向验证通路，低风险）。
2. Phase 2：`PUT`（host 主动导入）补齐**双向**。
3. Phase 3：`DELETE` + A 在互联走端点（删除双向传播）。
4. 每阶段单测 + 真机验证后再进下一阶段。

> 决策点（请用户确认后再实现）：是否接受「host 变主动导入」这一架构升级（B 的前提）；以及是否按上述分阶段推进。
