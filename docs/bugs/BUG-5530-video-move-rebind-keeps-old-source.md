## BUG-5530 · 扫描搬家改指不改归属源、不迁路径关联列
- **报告**：2026-11-26（整库补字幕实跑时发现：用户把 241 集从 `D:\video` 挪到 NAS `V:\`，重扫 V: 源后旧行全部改指到 V: 路径，但 `source_id` 仍是 3「播放列表合集 D:/video/…」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/source_library/source_library_scanner.dart:3145-3154`（BUG-2979 的搬家改指分支）：
  1. 归属源用 `assignSourceIfNull(moved.bookUid, sourceId)`——旧行已有 `source_id` 时不改，行落在 V: 却归属 D: 的源。后果：移除旧源会按 `source_id` 连带删掉已经在新源下的集；按源的刮削设置 / 运行、按源统计都对不上。
  2. 改路径用 `updateLocalMediaPaths`（只写 `videoPath` / 字幕源），不是一次事务迁全部路径关联列的 `VideoBookRepository.applyMediaFileMoves`（`packages/fushi_engine/lib/media/video/video_book_repository.dart:973`）：`playlistJson` 各集 path、`cover_path`、`media_images.path`、`video_metadata_images.local_path`、字幕覆盖层 `source_key`、`video_file_specs` 等仍指旧路径。
- **[ ] ① 未修复** — 搬家改指改为：归属源无条件改成「新路径所在的源」（扫描中的 `sourceId`），路径迁移走 `applyMediaFileMoves(MovedMediaFiles({旧: 新}))`；播放缺失态手动「重新导入」（`video_fushi_page.dart` `_relinkMissingResource`）同样改走 `applyMediaFileMoves`。用户库里已改指的 241 行需要一次性把 `source_id` 3 → 24 校正（修复后重扫 V: 即可由同一判据修正，或在修复里对「路径不在归属源根下」的行重判归属）。
- **[ ] ② 未加自动化测试** — `source_library_scanner` 搬家用例：旧行 `source_id=A`、文件挪进源 B 的根，重扫 B 后断言 `source_id == B`，且 `cover_path` / `playlistJson` / 字幕覆盖层键跟着迁。
- **备注**：BUG-4055 选 B（视频源重扫保留暂缺行）不受影响。
