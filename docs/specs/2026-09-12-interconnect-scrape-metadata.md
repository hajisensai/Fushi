# 互联刮削元数据：host → 客户端同步（7c）、客户端触发 host 刮削（7a）、客户端代刮回写（7b）

日期：2026-09-12。交接编号 #7。相关：BUG-2463（wire 已输出但客户端未写的三个字段，已单独修）。

## 0. 现状（沿真实代码路径核过）

- 互联 wire 上视频条目只有一个 DTO `RemoteVideoInfo`（`packages/fushi_engine/lib/sync/fushi_library_host_service.dart:1504-1546`），由 host 从 `VideoBooks` 单表 materialize（`local_library_host_service/videos.part.dart:23` 只查 `allVideoBooks()`）。`packages/fushi_engine/lib/sync/` 对 `VideoScrapeMeta` / `CollectionScrapeMeta` / `MediaImages` / 13 张 `VideoMetadata*` 表 grep **零命中**；客户端 `fushi/lib/src/sync/` 同样零写入。
- 合集清单端点 `GET/POST /api/library/collections`（`CollectionManifest`，`collection_manifest.dart:237-249`）只带 name / collectionType / members / tombstones / tagNames，**不带** `MediaCollections.coverPath` 与任何刮削字段。
- 所以「host 刮好的元数据有的没同步」的真相是：**刮削元数据整块不在 wire 上**，不是个别列漏项。BUG-2454 / PR#1420 / PR#1423 零 schema 变更，与此无关。
- 刮削落库的唯一入口是 `VideoMetadataDatabaseStore.apply(localWork, VideoMetadataWork)`（`video_metadata_database_store.dart:138`）：它处理 v99 字段锁、旧投影表、成员集号绑定。**客户端落库必须复用它**，不另写第二套写入。
- 领域模型 `VideoMetadataWork`（`video_metadata_models.dart:639`，含 Season / Episode / Id / Credit / Person / Character / Image / Extra）**没有 JSON 编解码**，也没有「从 DB 行反向装载」的函数（provider 拿到模型 → apply 写库，是单向的）。
- host 侧刮削能力面：`VideoSourceScrapeTaskController`（`video_source_scrape_task.dart:381`）的 `searchManualCandidates(source, workTitle, workStableKey, query)` 与 `rescrapeWorkWithLookup(source, workTitle, workStableKey, lookup)`；合集 → 作品单元由 `planScrapeWorksForCollection(db, collectionId)`（`video_library_scrape_sweep.dart:58`）给出，一个合集可能对应多个 `book:<uid>` 单元（BUG-2433）。
- 身份：`VideoMetadataLookup{provider, externalId, mediaKind, episodeGroupId}`；host 已确认的主身份由 `VideoMetadataDatabaseStore.confirmedLookup(localWork)` 读 `VideoMetadataProviderIdentities.isPrimary`。

## 1. 数据结构（先定这个）

### 1.1 作品自然键 `MetadataWorkKey`

跨端唯一、不依赖自增 id：

```json
{ "collection": { "name": "...", "collectionType": "collection" } }   // 合集级作品
{ "bookUid": "..." }                                                   // 单条目作品
```

与 `CollectionManifestEntry` / `RemoteVideoInfo.id` 同域，客户端本地必然能解析（合集经 `/api/library/collections` 同步；bookUid 是 host 的 `VideoBooks.bookUid` = 客户端下载后的 bookUid）。

### 1.2 作品 wire 形态 `MetadataWorkEntry`

```json
{
  "key": <MetadataWorkKey>,
  "updatedAt": 1700000000000,          // host VideoMetadataWorks.updatedAt
  "lockedFields": ["title", "cover"],  // host 字段锁（只读镜像，客户端不据此加锁）
  "lookup": { "provider": "mal", "externalId": "1234", "mediaKind": "tv", "episodeGroupId": null },
  "work": <VideoMetadataWork JSON>
}
```

`work` = `encodeVideoMetadataWork(VideoMetadataWork)`（新增 `video_metadata_wire.dart`，与 `decodeVideoMetadataWork` 互逆；`rawPayload` 不上 wire）。图片只带 `remoteUrl` / kind / language / 尺寸（host 的 `localPath` 是缓存，客户端沿用现有「无 localPath 用 remoteUrl」回落，见 `media_collection_detail_page.dart:341-344`）。

host 从 DB 反向装载：新增 `loadVideoMetadataWork(db, workRow)`（`video_metadata_work_loader.dart`），逐表读 Seasons / Episodes / ProviderIdentities / Terms / Credits+People+Characters / Images / Extras 拼回 `VideoMetadataWork`。守卫：`apply → load → encode → decode → apply` 往返测试。

### 1.3 端点

| 方法 | 路径 | 用途 | 批次 |
|---|---|---|---|
| GET | `/api/library/metadata` | 全部作品 `MetadataWorkEntry[]`（`?since=<ms>` 只回 updatedAt 更新的） | 7c |
| POST | `/api/library/metadata/candidates` | `{key, query}` → `[{lookup, work}]`（host 跑 `searchManualCandidates`） | 7a |
| POST | `/api/library/metadata/scrape` | `{key, lookup}` → host 跑 `rescrapeWorkWithLookup`，同步返回 `{ok, entry?}` | 7a |
| PUT | `/api/library/metadata` | `{key, lookup, work, replaceIdentity}` → host `store.apply` 落库 | 7b |

`/api/capabilities` 加 `videoMetadata: true`；旧 host 404 → 客户端静默跳过（不报错、不阻塞其余同步）。

## 2. 覆盖保护（7a / 7b 共用）

1. **字段锁**：`store.apply` 已保留 host 锁定字段旧值，7b 回写天然受保护；7a 走 host 自己的刮削链，同理。
2. **手动指定 ID 不静默换源**：7b `PUT` 时 host 先 `confirmedLookup(localWork)`；已有主身份且 `(provider, externalId)` 与入站 `lookup` 不同 → 除非 `replaceIdentity: true`，返回 409 `{conflict: "identity", current: <lookup>}`；客户端弹确认后重发。7a 由用户在候选里明确选身份，本身就是显式换源。
3. **单源语义**：AniDB 身份不传兜底（沿 CLAUDE.md），wire 只搬运，不在同步层做任何换源。
4. **7c 方向**：host 是刮削权威。客户端只在「本地无作品行」或「host `updatedAt` 大于本地 `updatedAt`」时 apply；本地字段锁照旧由 apply 保护（用户在客户端锁的字段不被 host 覆盖）。

## 3. 客户端

- `InterconnectSyncBackend`：`getRemoteVideoMetadata({since})` / `searchRemoteMetadataCandidates` / `requestRemoteScrape` / `putRemoteVideoMetadata`。
- 同步编排 `sync_orchestrator/metadata.part.dart`：拉 `/api/library/metadata`，逐条按 §1.1 解析本地目标（合集按 `(name, collectionType)`；bookUid 直接查 `VideoBooks`），构造 `VideoSourceScrapeWork`（source 允许为空——见 §5 风险）并 `store.apply`。
- 7a UI：合集右键 / 详情页管理菜单「在 host 上刮削」→ 复用 `showVideoSourceScrapeManualBindingDialog` 的候选搜索 UI，但候选来源换成远程端点；选定后 `POST /scrape`，回来触发一次 7c 拉取刷新。
- 7b UI：「本机刮削并回写 host」→ 本地 provider registry 搜候选（沿用本地 UI）→ `fetchWork(lookup)` 拿完整 `VideoMetadataWork` → `PUT`；409 → 确认换源对话框 → `replaceIdentity: true` 重发。

## 4. 分批与验证

- 批 1（7c）：codec + loader + `GET /api/library/metadata` + 客户端 apply。往返守卫测试、host 端点测试（fake service）、客户端 apply 测试（内存 DB）。
- 批 2（7a）：candidates / scrape 端点 + 客户端远程候选 UI。端点测试 + 409/404 降级测试。
- 批 3（7b）：`PUT` + 覆盖保护 + 客户端回写 UI。字段锁 / 身份冲突测试。
- 真机：客户端与 host 各一台，host 刮完一部，客户端同步后详情页出现简介/评分/分集名；客户端在 host 上重刮一次；客户端代刮回写一次。缺口如实记录。

## 5. 风险

- `VideoSourceScrapeWork.source` 是非空 `SourceLibraryRow`，客户端下载的视频没有来源库；`apply` 实际不读 `source`，批 1 通过为客户端 apply 构造一个只含 collection/members 的工作单元解决（不改 `VideoSourceScrapeWork` 类型，避免波及计划器）。
- 一个合集在计划器里可能是多个 `book:<uid>` 单元（BUG-2433）：7a 的 `candidates` / `scrape` 请求带的是 `MetadataWorkKey`，host 端按 `planScrapeWorksForCollection` 解析；多单元时返回 409 `{conflict: "ambiguousWork", works: [...]}`，客户端按本地同款 `_pickCollectionScrapeWork` 让用户选后带 `bookUid` 重发。
- Wire 体积：全库 works 一次拉。先按 `since` 增量；images / credits 可能大，批 1 先全量，实测超 1MB 再拆端点。
