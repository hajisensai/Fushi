## BUG-4004 · 同步时未变的书和统计仍逐本往返、整份重下
- **报告**：2026-11-03（用户：开发者本人，应用内反馈 jHQpTfjrNB，Windows，云通道）
- **真实性**：✅ 真 bug（性能）。反馈附带的 `SyncRunReport.timing`（10 轮，36 本书）：总耗时 49–131 s；
  `readingData` 22–30 s（每本约 0.7 s）、`audiobook+videoFiles` 10–17 s、`cloudTombstoneScan` 3–7 s、
  `collections+tags+metadata` 4–6 s、`aggregate` 平时 1.4–2.6 s，偶发 35–70 s。书阶段每本 0.7 s 说明走的是
  **没有整树快照**的后端（WebDAV / OneDrive / FTP / SFTP，只有 Drive / Dropbox / 新 host 有快照）。
  沿真实路径（`SyncOrchestrator.run` → `SyncManager.syncAllBooks` → 各阶段）找到下列「远端一字未变也照付」的工作
  （行号为修复前 `develop` 2eb0face28）：
  1. **同一个书文件夹一轮列两次**：`sync_manager.dart:386` 先 `listSyncFiles(folderId)`（一次整目录列举），
     只留下 progress/statistics/audioBook 三个句柄、丢掉其余文件名；开了「上传书籍文件」时
     `sync_manager.dart:413-418` 只在有快照时才把文件名传下去，于是 `_exportContentIfMissing`
     （`sync_manager.dart:954-957`）对同一文件夹再 `listChildren` 一次。无快照后端每本每轮 2 次往返。
     根因是数据结构：`SyncFileTrio`（`sync_file_ref.dart:24`）不携带那次列举的文件名。
  2. **书阶段的逐本列举严格串行**：`syncAllBooks` 的 for 循环里一本列完才列下一本，N 本书 = N 个 RTT 的墙钟。
  3. **有声书包每本每轮 HEAD 1–2 次**：`sync_orchestrator.dart:2283-2285` 用 `findAsset` 探 `audiobook.fushiaudio`
     （没有再探 Hibiki 旧名），而答案就在书阶段刚列过的同一个文件夹回包里。
  4. **per-device 清单每轮整份重下**：删除墓碑合并清单 `sync_orchestrator.dart:1537`、合集清单
     `sync_orchestrator.dart:1225`、作品图谱清单 `sync_orchestrator/media_links.part.dart:56`、云视频目录清单
     `sync_orchestrator.dart:1814-1821`（还先多一次 `findAsset` HEAD，清单名其实就在刚列出的命名空间里）。
     N 台设备 = 每轮 N 次 GET × 4 类，远端版本（ETag / md5 / content_hash）没变也照下。聚合快照早有同类镜像
     （`aggregate_peer_snapshot_cache.dart`），其余四类没接。
  5. **未变的书每轮重写同步基线**：`sync_manager.dart:516-522` 两端一致（synced）时无条件 `setSyncBaseline`，
     即使读到的基线已是同一个值。
  6. **导入 / 导出一本书的统计整表扫描**：`sync_manager.dart:1114` `getAllReadingStatistics()` 再按书名过滤，
     每本 O(全表)。
- **[x] ① 已修复** — `6c8010d5be`。
  - `SyncFileTrio.fileNames` + 唯一装配点 `syncFileTrioFromFiles`（`sync_utils.dart`）：七个后端的
    `listSyncFiles` 与快照 `trioFor` 都交出同一次回包里的完整文件名（Drive 只取第一页，有下一页时交 null）。
    `_exportContentIfMissing` 直接用它判「远端有没有」，不再重列；列举方给不出完整清单时照旧自己列。
  - `BookFolderListingObservations`（`sync_remote_listing.dart`）：书阶段按 folderId 记下所见文件名，同轮有声书
    包阶段命中新名 / 旧名直接跳过；没看见的照旧实时 HEAD 确认后再决定上传（「没看见」绝不当「不存在」）。
  - `SyncManager._prefetchSyncFileLists`：无快照时把逐本列举改为并发 4 的预取，请求数不变、判定不变；只预取
    title→folderId 已缓存、本轮唯一占用该文件夹、未被推送否决的书，预取失败的那本照旧现列（错误在那里照常抛）。
  - `SyncOrchestrator._manifestMirror`（复用 `DirectoryAggregatePeerSnapshotCache`，`sync_cache/manifests/`）：
    四类 per-device 清单按资产 id + revision 命中镜像，合并语义不变（每轮仍全部折叠）；revision 为 null 的后端
    （FTP / SFTP）不缓存，行为同改动前。视频目录清单改从 `listChildren` 结果里取，去掉一次 HEAD。
  - synced 分支自动路径上基线已等于该值时不重写；手动路径照旧写。
  - 新增 `FushiDatabase.getReadingStatisticsForTitle`，统计只读这本书的行。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_round_trip_budget_test.dart`（11 例，计数即基准）：
  无快照后端 6 本未变的书 `listSyncFiles=6, listChildren=0, 探针=0, 写库基线=0`（修前 `listChildren=6`、基线写 6 次）；
  8 本书预取 `listSyncFiles=8` 且 `maxInFlight>1`（修前恒 1）；同名书不预取；不完整清单仍回落现列；
  导出统计 `getAllReadingStatistics` 调用 0 次且只导出本书行；有声书包命中列举所见 `findAsset=0`（修前 1–2）、
  旧名同样算有、未见时照旧确认不重传；合集清单稳态下载 0 次（修前每轮 2 次），对端改动后照下且折进新成员；
  删除墓碑合并清单稳态下载收敛到 0。
- **备注**：
  - 「修前」计数是按修复前代码路径推得（同一测试依赖新 API，无法原样跑在旧代码上）；用户真实网络下的墙钟前后
    对比未测，按反馈数据估算：书阶段 36 本 × 2 RTT 串行 → 36 RTT 并发 4，约 25 s → 3–4 s；有声书 / 清单阶段
    稳态各省去每项 1–2 RTT。
  - **未处理、需拍板**：`aggregate` 偶发 35–70 s 发生在对端快照有变化时——每台设备的聚合快照是整份 JSON，对端
    只多读了几分钟，本机也要整份重下、整份 materialize + 合并。根治需要改快照格式（按月 / 按族分片，或带
    增量日志），属于同步 wire 格式变更，未擅自做。
  - **未处理、需拍板**：通用 WebDAV 后端仍无整树快照（`Depth: infinity` 在很多服务器上被禁用，且有的服务器
    静默按 Depth 1 回答，凭回包形状无法与「全部书文件夹为空」区分，误读会按本地旧进度覆盖远端）。本次用并发预取
    缩短墙钟，请求数仍是 O(书数)。若要 O(1)，需要能力探测方案（例如先对一个已知非空的书文件夹做对照），
    属于后端契约取舍。
  - Google Drive 的 `listSyncFiles` 只取第一页（`google_drive_handler.dart`，>100 个文件时三件套可能不全），
    属既有问题，本次只让它在有下一页时不交出文件名清单；Drive 稳态走整树快照，不影响本反馈。
  - SRS sync2（native/fushi_fsrs）按任务要求未碰。
