## BUG-3703 · 互联同步一轮要几分钟（局域网 / 全部客户端）
- **报告**：2026-10-23（用户：「fushi 同步书速度很慢，可能不只是书导致的，对比进度冲突不可能这么久的」；局域网下所有设备都慢，iOS 手机约几分钟）
- **真实性**：✅ 真 bug。真 host（44 书 / 99 视频）+ 真客户端 loopback TLS 装置逐阶段计数，配合对用户真实 host 端点直接计时，定位到稳态每轮都在重做的四处全量工作（TLS 连接复用、地址探测均正常，排除）：
  1. 合集清单永不收敛：`packages/fushi_engine/lib/sync/collection_sync_engine.dart` `_stampEntry` 给 publishedAt 为空的墓碑 / 删除每轮盖 now，而 host DB 不存 publishedAt（`loadLocalCollectionManifest` 不输出），`fushi/lib/src/sync/sync_orchestrator/collections.part.dart` 的「字节不等才 POST」恒成立 ⇒ 每轮整份清单（用户数据 7 MB）POST 回 host、host 整份合并 1.8 s。
  2. 统计聚合每轮整库重写：`packages/fushi_engine/lib/sync/aggregate_sync_service.dart` 写回判据 `!identical(merged, localSnapshot)` 恒真（`mergeSnapshots` 总返回新对象），用户真实快照（8699 条学习片段）稳态每轮约 1.85 万条 SQL；`upsertStudySegmentsIfNewer` 逐行查墓碑 + INSERT。
  3. 进度 sweep 逐条读写：`interconnect_playback_position_sync.dart` / `interconnect_book_progress_sync.dart` 的 `alignSynced` 已一致仍无条件写基线，位置 / 基线 / 播放偏好逐条读（视频稳态每个 15 条 SQL）。
  4. host 列表接口随合集规模退化：`local_library_host_service.dart` 主归属合集逐合集查成员、`book_series_grouper.dart` `groupAll` 整表读成员并逐合集线性扫（真实 host `/api/library/books` 每次 2.7 s）。
  另：用户 host 上 3145 个 playlist（8.4 万成员）是 2026-09-17/18 从 Emby 兼容服务器整库收养生成的远端条目（`dd1aaf9e2c` 起该路径默认关），已经用户确认经控制通道正常删除路径清除（写合集墓碑，各端随同步删除）。
- **[x] ① 已修复** — 合集只给远端没有的知识盖发布戳；聚合按内容（与 PUT 指纹同口径）判等、只写增量、片段批量写；进度 sweep 整轮一次读快照、已收敛条目跳过、不再写同值基线；host 列表复用 `getLocalPrimaryCollectionMembership()`、grouper 只取相关合集成员。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_library_collections_test.dart`（真 host 稳态零 POST）、`fushi/test/sync/aggregate_apply_delta_test.dart`、`fushi/test/sync/interconnect_progress_sweep_db_ops_test.dart`、`packages/fushi_engine/test/sync/local_library_host_collection_membership_test.dart`
- **备注**：修前修后（Windows / Mac 桌面，同规模数据）：聚合稳态 18468 条 SQL / 2.5 s → 20 条 / 0.4 s；视频进度稳态 1487 条 → 4 条；书 / 有声书进度 221 / 82 条 → 4 条；`listBooks` 约 900 ms → 33 ms，`listVideos` 约 335 ms → 22 ms。未在 iOS 真机实测。
- **后续（同 PR）**：
  - 复活缺口：schema v125 给 `collection_member_tombstones` 加 `published_at`，host 持久化并在清单里输出墓碑发布戳，「离线早移出、晚同步」的墓碑不再被基线更新的对端判成旧闻（`fushi/test/sync/fushi_library_collections_test.dart`「离线移出晚同步」组、`fushi/test/database/migration_v125_collection_tombstone_published_at_test.dart`）。
  - 书文件箱：host 在 `/api/capabilities` 公布 `webdav.treeListingLevels`，`InterconnectSyncBackend` 实现 `RemoteListingCapable`，书阶段一次有界 `Depth: infinity` 取代逐本 PROPFIND；老 host 不公布就照旧逐本，快照里查不到某本书的文件夹也回落逐本（`fushi/test/sync/interconnect_tree_listing_test.dart`、`packages/fushi_engine/test/sync/dav_tree_listing_host_test.dart`）。
  - `/api/library/videos` 偶发数秒：不是 `listVideos` 本身（真实库拷贝冷 60 ms / 热 13–16 ms），而是主 isolate 上对 rclone 网络盘的同步 stat，另立 BUG-3704。
