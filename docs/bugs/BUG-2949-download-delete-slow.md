## BUG-2949 · 下载任务删除文件极慢
- **报告**：2026-10-05（用户：「下载里面选择删除文件……是删除的巨慢无比」）
- **真实性**：✅ 真 bug。根因 `packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart` 的 `deletePersistedVideoDownloadJob`：删完盘上文件后对**每一集**入库行单独调 `deleteVideoBookAndReclaimAssets`。这个单条入口每次都要全表读一遍 `media_images` 和 `video_books`（回收护栏）、开一个独立事务、再排一次 `VideoCoverMutationGate` 互斥锁（刮削正在写封面时还得等它）。一季 24 集的种子就是约 48 次全表扫描 + 24 个事务，耗时按「集数 × 库大小」增长；批量删 M 个任务再乘 M。库页删除早在 BUG-2754 改成了批量入口 `deleteVideoBooksAndReclaimAssets`，下载任务删除这条路没跟上。（排除项：libtorrent `remove_torrent` 是异步投递，不阻塞；`compactAfterVideoDeleteBestEffort` 在 BUG-2754 之后只做 checkpoint，空闲页超过 25% 才 VACUUM。）
- **[x] ① 已修复** — 先收集本任务被删文件对应的 bookUid，再一次调 `deleteVideoBooksAndReclaimAssets`（一个事务，全表各读一次，压缩一次）。失败语义不变：批量入口抛错时仍在删任务行之前抛出。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart`「deleting a multi-episode job removes every imported library row」（三集全部删除，库外的行不受牵连）；源码守卫 `fushi/test/pages/video_delete_reclaim_entry_guard_test.dart` 的 download-job deletion 入口改为钉住批量入口 `deleteVideoBooksAndReclaimAssets`。
- **备注**：没有在真机上计时；速度提升是从算法复杂度推出来的（O(集数×库) → O(库)）。
