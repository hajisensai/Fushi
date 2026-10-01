## BUG-2835 · BD 整包 CDs 曲目在全部视频里逐条铺满
- **报告**：2026-10-01（用户：VCB-Studio「无职转生 S2」BD 整包，`CDs/` 下 14 张专辑约 150 条 flac 在「全部视频」逐条出现）
- **真实性**：✅ 真 bug，PR #1850（`bce7770d67`，纯音频按「无画面视频」进视频库）引入。
  - 系列模式归组走 `groupVideosIntoPlaylists` 按文件名系列名分组（`packages/fushi_engine/lib/media/video/video_folder_group_coordinator.dart` series 分支）；曲目文件名 `24. 悲愴.flac` 没有系列名、各自成组，单文件组不建合集 → 每首都是独立散片。
  - 目录模式按来源根第一级子目录归组（同文件 `videoSourceFolderPath`）→ 14 张专辑糊进一个「CDs」合集。
  - 即使建了目录合集，系列模式下 `fushi/lib/src/media/video/video_folder_collection_policy.dart:35-38` 也会把带 `sourceFolderPath` 的合集从主归属里摘掉。
  - 「全部视频」逐条平铺整库、系列筛选默认「全部」（`home_video_page.dart` `_seriesFilter`），散片和合集成员一起铺开。
  - 潜伏：季分组键 `collectionGroupKeyForFilename` 对曲目没解出集号，只是因为刮削器的剥扩展名表不认 `.flac`（`filename_parser.dart` `_stripExtension`），不是有意判据。
- **方案（用户 2026-10-01 拍板）**：
  1. 音频按**所在目录**成辑（一张专辑一个合集），与分组模式无关；键用 `sourceFolderPath` = 专辑目录，合集名剥掉发售日前缀与尾部规格标签；主归属策略对音频成员同样不看分组模式。
  2. 季分组键遇纯音频直接归特典组。
  3. 「全部视频」系列筛选默认「非系列」并记住上次选择；映射未就位时不退回「全部」；有搜索词时不套这个档位。
  4. 「全部视频」新增类型（视频/音频）、正片/特典、来源三个本地筛选。
  - 番剧合集挂「音乐」入口另开，不在本条。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：
