## BUG-3538 · 移动下载后库里外挂字幕路径被改到没有字幕文件的新位置
- **报告**：2026-10-19（内部审查：上一轮修 e90c6d581c 时子代理标出，原为推测）
- **真实性**：✅ 真 bug（代码路径核实）。「移动」入口 `DownloadRelocateService.moveTorrent`
  （`fushi/lib/src/media/torrent/download_relocate_service.dart:89-93`，修前）把「旧 save_path → 新 save_path」
  当成目录前缀交给 `VideoBookRepository.migrateMediaPaths`
  （`packages/fushi_engine/lib/media/video/video_book_repository.dart:619`），后者对
  `video_books.subtitleSource` / `secondarySubtitleSource` 走 `remapMediaPath` 的 `p.isWithin(from, current)` 分支
  （`packages/fushi_engine/lib/media/video/video_path_migration.dart:59`）——凡落在旧保存根下的字幕都被改到新根。
  但引擎（libtorrent `move_storage`，`native/fushi_torrent/fushi_torrent_ffi.cpp:1447` `ht_move_storage` → `h.move_storage`，:1465；qBittorrent `setLocation`）
  只搬**种子自己的文件**，Fushi 下载后放在视频旁的字幕 sidecar 不在种子里、原地不动 → 库里字幕列指向一个
  没有文件的位置，播放时外挂字幕丢失。仓库自己的注释（`video_book_repository.dart:607-608`，修前）已写明
  「字幕 sidecar 不在 torrent 里、引擎不搬」，却只对任务表生效、库三列仍按前缀改。
- **[x] ① 已修复** — 3ab3df74c9：重映射判据改为「文件是否真的被引擎搬走」。
  `video_path_migration.dart` 新增 `MovedMediaFiles`（逐文件全等，`p.canonicalize` 比较），
  `remapVideoBookPaths` 只认它；`moveTorrent` 在动引擎前从后端 `listFiles` 现取种子文件列表，逐文件登记
  旧 → 新本机路径；`VideoBookRepository.applyDownloadRelocation` 取代按前缀的 `migrateMediaPaths`。
  种子自带的字幕文件（在 `listFiles` 里）照常跟着改。
- **[x] ② 已加自动化测试** — `fushi/test/media/torrent/download_job_path_relocate_test.dart`
  「移动整个种子：只改种子自己的文件，sidecar 字幕不动…」（真 Drift 库 + 真服务，断言 sidecar 字幕列不变、
  种子内 `.ass` 跟着改）；`fushi/test/media/torrent/download_relocate_service_test.dart`
  「MovedMediaFiles / remapVideoBookPaths」组与「同机移动：逐文件登记…」。
- **备注**：库侧只是不再把字幕改错；字幕文件本身仍留在旧目录（与引擎行为一致，播放可用）。是否让 Fushi 在
  移动时把自己下载的 sidecar 一起搬走是产品决定，未做。
