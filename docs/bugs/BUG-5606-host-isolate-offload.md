## BUG-5606 · 电脑当互联 host，iPhone 连过来同步时电脑界面一卡一卡
- **报告**：2026-11-28（用户：电脑 Fushi app 当 host，iPhone 连过来时电脑界面卡）
- **真实性**：✅ 真 bug。app 当 host 时 `FushiSyncServer` 由 `shelf_io.serve` 起在 UI isolate 上（`packages/fushi_engine/lib/sync/fushi_sync_server.dart` `_bindListener`），清单端点的读库结果映射、清单组装、JSON 编解码、gzip 与逐书同步文件探测都在这个 isolate 上做。用户规模库（3184 合集 / 85044 成员）实测 `GET /api/library/collections` 7 MB、单次 UI isolate 停顿 70～308 ms，`POST` 126～189 ms。
- **[x] ① 已修复** — 见下「修复」（分支 `pr/host-isolate-offload`）
- **[x] ② 已加自动化测试** — `fushi/test/sync/host_manifest_body_test.dart`、`fushi/test/sync/host_request_observer_test.dart`、守卫 `fushi/test/build/host_route_sync_io_guard_test.dart`；合并语义回归由 `fushi/test/sync/fushi_library_collections_test.dart` 全链路覆盖（现在走后台报文体路径）
- **备注**：client 侧（`interconnect_sync_backend.dart`）不在本次范围，还没发 `If-None-Match`；host 已带弱 ETag（`W/"…"`，见下「审查后修正」）、支持 304，client 接上即可省掉稳态的 7 MB 传输与解析。

### 根因

1. `fushi_sync_server/sync_state.part.dart` `_handleLibraryCollections` 的 GET 每次都调
   `LocalLibraryHostService.getCollectionManifest` → `loadLocalCollectionManifest`
   （`collection_sync_engine.dart`），逐合集 `getCollectionItems` + `getTagsForCollection`
   （2N 次 DB 往返，用户库约 6000 次）。drift 查询本身在 DB isolate，但每次往返的结果
   反序列化成行对象、清单组装、`canonicalJson()` 都在 UI isolate；没有缓存、没有 ETag，
   对端每轮同步都整份现算。
2. POST 在 UI isolate 上 `readJsonObjectBody`（`jsonDecode` 7 MB）→ `CollectionManifest.fromJson`
   → 合并（再读一遍本地清单）→ `canonicalJson()`；锁内 `reconcileEpubCollectionMemberKeys`
   与 `convergeCollectionsAfterSync` 各自全表读一遍合集。
3. `_gzipTextMiddleware` 在 UI isolate 上同步 `gzip.encode` 整个报文体（7 MB 约 +70 ms）。
4. `local_library_host_service/books.part.dart` `listBooks` 逐书同步探测文件
   （`resolveEpubCoverFilePath` / `resolveExtractedEpubRoot` / `hasExportableMangaContent`
   ——整份读 `manga.json` 并逐页 `existsSync` / `hasExportablePdfContent` /
   `hasAnyChapterDirSync`）；`exportBook` 经 `repackageExtractedEpub` /
   `repackageMangaBook` 在 UI isolate 上同步打整树 zip。
5. 漫画供图路径（`manga.part.dart`）逐页 `statSync` / `existsSync` / `listSync`，单卷页表
   同步读 + 解析，新开一章时同步扫整棵现取页缓存树；`local_audio.part.dart` 同步
   `existsSync`；导出缓存同步 `createTempSync`。

### 修复

- 新增 `host_manifest_bodies.dart`：合集 / 标签 / 作品图谱清单的读库、组装、合并、JSON
  编解码、ETag（SHA-256 前 128 位）都在 `AggregateSyncOwner`（同库后台连接的 isolate）
  里做，报文体经 `TransferableTypedData` 交回不拷贝。可选能力接口 `HostManifestBodyHost`
  （老 host 实现 / 测试 fake 不实现则走旧对象接口）。合集 POST 的落库仍在 host isolate
  （要回收封面文件，路径根与图片缓存是 host 进程的全局钩子），`reconcile` 与收敛判据在
  后台做，有可收敛项才在 host isolate 跑收敛。
- 合集清单缓存 `HostManifestBodyCache`：按 `collectionManifestSourceTables` 的表写入作废
  （跨 isolate 写入经 `backgroundConnection` 的表更新转发同样生效），作废即退订、重算
  途中作废不进缓存。GET 带 `ETag` + `Cache-Control: no-cache`，`If-None-Match` 命中回 304。
- `loadLocalCollectionManifest` 改批量：`getAllCollectionItems` + 新增
  `getTagsForAllCollections` 各一趟，按合集 id 分组（2N 次往返 → 2 次）。
- gzip 报文体 ≥256 KiB 时在一次性 isolate 里压。
- `listBooks` 的逐书探测整批进 `host_background_io.dart` 的 `probeHostBooks`（一个后台
  isolate 跑完）；`repackageExtractedEpub` / `repackageMangaBook` 内部走 `Isolate.run`；
  封面 / PDF / 页图改用异步形态（`resolveEpubCoverFilePathAsync`、
  `hasExportablePdfContentAsync`、`MangaStorage.resolvePageFilePathAsync`）；漫画单卷页表与
  现取页缓存清理进 `Isolate.run`；其余 `statSync` / `existsSync` / `listSync` 改异步。
- 慢请求观测 `host_request_observer.dart`：处理耗时 ≥1 s 或事件循环延迟 ≥100 ms 的请求
  记 `FushiSyncServer.requests: slow <方法> <路由> status=… <耗时>ms loopLag=…ms`；每
  10 分钟一行各路由次数 / 累计耗时（看对端请求频率）。计时器只在有请求在飞时挂着。
- 源码守卫 `host_route_sync_io_guard_test.dart`：host 路由处理文件里禁止 `*Sync(` 调用与
  已知内部同步 IO 的判据 / 打包函数。

### 实测（每 10 ms ping `/api/ping` 量 host 事件循环最长停顿；fushi_server 跑用户库副本）

| 请求 | 修复前 maxPing | 修复后 maxPing |
|---|---|---|
| GET collections（明文，冷 / 热） | 103 / 78 / 70 ms | 19 / 2 / 2 ms（首次现算 737 ms 墙钟在后台，之后命中缓存 12～25 ms） |
| GET collections（gzip） | 140 / 168 ms | 2 / 2 ms |
| GET collections + If-None-Match | （无 ETag） | 304，2～4 ms |
| POST collections（明文 / gzip） | 175 / 126 / 189 / 144 ms | 15 / 15 / 20 / 13 ms |
| GET books | 17 / 7 ms | 7 / 6 ms |

报文体字节数前后一致（明文 7037911、gzip 1557612）。

### 审查后修正

1. **长轮询误判慢、计时器常驻**：`GET /api/srs/changes` 按设计挂 25 s，观测器把它当在飞
   请求，50 ms 周期计时器因此常驻 UI isolate（client 一直挂着长轮询）、每条长轮询记一行
   slow、期间别的请求造成的 loopLag 也记到它头上。修：`isHostSuspendingRequest`
   （`GET /api/srs/changes`、`GET /api/assistant/sessions/<id>?wait=N>0`）判为挂起类，
   只进频率汇总（键标 `(hold)`），不进在飞集合——计时器只在有普通请求在飞时跑，loopLag
   只归普通请求。测试：`host_request_observer_test.dart`「长轮询挂着…」「isHostSuspendingRequest…」。
2. **gzip 与明文共用强 ETag**（违反 RFC 9110 §8.8.3）：清单 ETag 改为弱的
   `W/"<SHA-256 前 128 位 hex>"`（`hostManifestEtag`），`If-None-Match` 本就按弱比较
   （`ifNoneMatchHits`：逗号列表、忽略 `W/`、`*` 命中）；gzip 中间件对可压缩响应一律加
   `Vary: Accept-Encoding`。只有三个清单 GET 带 ETag：`/api/library/collections`、
   `/api/library/tags`、`/api/library/media-links`（POST 不带）。不发 `If-None-Match` 的
   老 client 行为不变。测试：`host_manifest_body_test.dart`「ETag 是弱的、gzip 与明文共用…」。
3. **合集清单缓存的作废表**：
   - `galgames` 不影响清单（合集成员只做书键换算，游戏键原样透传）却被读、被登记。
     `CollectionBookIdentityIndex.load` 加 `withGames`，合集清单 loader 与卷序
     （`loadBookSeriesRuleOrder`）传 `false` 不再读 `galgames`，作废表里去掉它；录 SQL 的
     测试同时钉住「loader 读的表都已登记」与「不读 galgames」。
   - `video_download_jobs` / `video_download_subscriptions` 下载进行中写得勤（租约每 40 s
     续期、阶段推进），清单却只依赖「哪些合集由下载管理」这一小块投影。改为投影依赖
     （`collectionManifestProjectedTables` + `collectionManifestProjection`）：这两张表的
     写入只把缓存标成待核对，下个读者在 host isolate 读一次投影（几十个 int），不变就继续
     用缓存，变了才重算；读投影到重算结束之间来过这两张表的写入则结果不进缓存（防 ABA）。
     测试：`HostManifestBodyCache` 两条投影用例 + 真库用例（续租不重算、任务挂到新合集才
     重算，结果与 loader 逐字节相同）。
   - `epub_books` 留在直接作废表里：清单只用它的 uid / bookKey / sourceMetadata，但它没有
     高频写入（阅读进度不在这张表，写入来自导入 / 刮削 / 元数据编辑），而按列收窄要在每次
     写入后重读全表这三列比对，代价与重算时读它那一步相当，省不下什么。
4. **client 不发 `If-None-Match`**（审查第 8 条，补完第 2 条）：host 带了 ETag，client 的
   三条清单 GET 却每次全量下载、全量解析。修：`InterconnectSyncBackend._getManifestConditional`
   （`getRemoteCollectionManifest` / `getRemoteTagManifest` / `getRemoteMediaLinkManifest`
   共用）按路由在内存里缓存上一次带 ETag 的 200 与解析出的清单，下次带 `If-None-Match`，
   304 直接返回缓存的那个对象（不下载、不解析）。失效同能力表：配对身份（配置签名 + 选中的
   host 身份 / 凭据 / 指纹）变了不带旧 ETag；连不上 / 超时 / 非 2xx·304 / 解析失败清缓存；
   老 host 不带 ETag 不缓存、每次全量；同一路由在飞时并发请求合并。304 复用同一对象，所以
   三种清单的 `fromJson` 产出的集合字段一律不可变（`List.unmodifiable` / `Map.unmodifiable`），
   调用方改不动缓存。这一路走 `WebDavOps` 的 `HttpClientRequest`（同步编排用的
   `InterconnectSyncBackend` 不经 `InterconnectHostChannel`），所以没有复用 `send(headers:)`，
   头直接设在请求上。同时把 host 端两份 `If-None-Match` 匹配（清单的 `ifNoneMatchHits`、
   能力表的 `interconnectEtagMatches`）与 ETag 生成合成 `fushi_engine/sync/http_etag.dart`
   的 `ifNoneMatchHits` / `weakContentEtag`；能力表 ETag 也改成弱的（能力表 JSON 同样会被
   gzip 中间件压缩，强 ETag 同第 2 条违规；弱比较下老 client 缓存的强形式照样命中）。
   测试：`interconnect_manifest_etag_test.dart`（真 `FushiSyncServer` 304 复用 + 不可变 +
   host 改了回 200；假 host 看请求头：带 / 不带 If-None-Match、老 host、换 host、失败清缓存、
   并发合并）。
