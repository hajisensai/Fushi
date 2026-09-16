## BUG-2565 · 删视频/合集勾选「同时删除本地文件」时，同目录的外挂字幕文件不会被删除
- **报告**：2026-09-16（用户：「视频里删合集，勾选删除视频和本地文件后，视频文件会被正常删除，但是字幕文件不会被删除」）
- **真实性**：✅ 真 bug —— `packages/fushi_engine/lib/media/video/video_local_files.dart:69`
  的 `localVideoFileCandidates` 只收 `videoPath` + 播放列表各集两类路径，字幕从来
  不进候选；`video_book_repository.dart` 的删除尾活（`_deleteVideoBooksAndReclaimAssetsUnlocked`
  里 `if (deleteLocalFiles)` 那一段）就是拿这张候选表去删盘的，于是**字幕在任何
  入口、任何勾选组合下都删不掉**。
  另一半在回收侧：`VideoStorage.deleteBookAssets` → `_deleteOwnedAsset` 明确只删
  **落在 app 自有目录内**的文件（`video_subtitles/`），这条纪律本身是对的（用户
  原件绝不能被静默回收），但它意味着下载管线放在视频旁的 `<同名>.<lang>.srt`
  （`video_download_pipeline_service` 的 sidecar 落地）、来源库扫描挂上的用户原件、
  刮削补的 sidecar 全部不归它管。两侧一合，就是用户看到的现象：视频没了，旁边
  一堆 `.ja.srt` / `.zh.ass` 变成孤儿。
  四条视频删除路径（单删 / 批删 / 合集右键 / 合集详情）都收口在
  `deleteVideoBooksWithDecision`，所以是同一个洞，合集入口只是最容易撞上的那个。
- **[x] ① 已修复** — `packages/fushi_engine/lib/media/video/video_local_files.dart`
  新增 `sidecarSubtitlesForDeletedVideo`（纯函数，复用 `video_sidecar.dart` 的
  `listSidecarSubtitles` 判归属）+ `localVideoSidecarSubtitleCandidates`（按磁盘实况
  扫，每个目录只列一次），仓库层在算完视频候选后追加字幕候选。
  三道护栏：① 候选只从**已过护栏、确定要删**的视频文件派生——视频本身被别的行
  引用而保留时，它的字幕一条都不碰；② 新增 `referencedLocalSubtitlePaths` 把幸存行
  的主/副字幕指针也纳入护栏（用户给 B.mkv 手动挂了 A.ja.srt 的情形）；③ 同目录
  存在 stem 更长的**邻居视频**时，它认领的字幕归它（`ep01.mkv` 删除不得带走
  `ep01.5.srt`——对 `ep01` 而言 `.5.srt` 里的 `5` 正好长得像语言标记）。
  字幕与视频一起过 `LocalVideoFileDeleteHooks`，所以删盘前照样先放播放器句柄、
  先在下载后端标 skip。
  顺带补上同一条链路上的两个缺口：`secondarySubtitleSource` 的 app 副本此前从不
  回收（永久遗留在 `video_subtitles/`），护栏集也只收主字幕（删 A 会把幸存行 B 的
  副字幕一起删）——`VideoStorage.deleteBookAssets` 新增 `deletedSecondarySubtitlePath`，
  `collectReferencedAssetPaths` 主副两条指针都收。
- **[x] ② 已加自动化测试** — 两层：
  - `fushi/test/media/video/video_local_files_test.dart` 新增两组（纯函数归属判据 +
    真实临时目录的候选收集）：带/不带语言标记的同名字幕都收、别的集与非字幕不收、
    大小写不敏感、邻居 stem 更长时字幕归邻居（邻居同批被删时并集仍完整）、目录
    不存在返回空表不抛。
  - `fushi/test/media/video/video_book_repository_test.dart` 新增端到端组（真文件 +
    真 DB）：勾了就连字幕一起删且别的集一个不动、没勾则一个都不删、视频被别的行
    引用时视频与字幕都保留、幸存行挂着的字幕被护栏挡住、播放列表各集的字幕也跟着走。
- **备注**：同一 PR 还按用户追加要求给删除确认框加了「同时删除统计数据」可选勾选
  （默认不勾、也不进「记住这些选择」），落地走已有的
  `FushiDatabase.deleteVideoStatisticsForIdentity`（会立 study_segment / statistics
  两级墓碑，否则下一轮聚合同步会把对端还留着的段灌回来，见 BUG-2215）。那是新增
  能力不是 bug，不单独立档；测试在
  `fushi/test/media/video/video_delete_statistics_test.dart` 与
  `fushi/test/sync/delete_local_files_dialog_test.dart` /
  `fushi/test/media/collection_context_dialog_test.dart`。
