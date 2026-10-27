## BUG-3816 · 下载整理：多作品合集包续作目录无季号撞名整任务失败
- **报告**：2026-10-26（用户反馈 kg41f2PGdC，Windows：下载「向山进发」VCB-Studio 合集包，整理报 `organization target collision: 向山进发 (2013)/Season 01/向山进发 (2013) - S01E01.mkv`，本作 `[..] Yama no Susume [Ma10p_1080p]/[..][01]..mkv` 与续作 `[..] Yama no Susume Next Summit [Ma10p_1080p]/[..][01]..mkv` 抢同一目标，整条任务 needsAttention）
- **真实性**：✅ 真 bug。根因两层：
  1. 季号只看文件名：`packages/fushi_engine/lib/media/video/download/video_download_organizer.dart:207-213`（修前）`parseVideoFilename(_segments(file.name).last)`，季号 `parsed.season ?? request.defaultSeasonNumber`。合集包把季 / 续作放在各自目录里、文件名只写 `[01]`，目录上的季信息（`Season 2/`、`S02`、`2nd Season`、尾部裸数字，即 `parseVideoPath` 已有的 BUG-1543 规则）整理器一条都不看，全部落进默认季。
  2. 撞名即整任务失败：同文件 `:259-262`（修前）第一处目标冲突直接抛 `FormatException`，`video_download_pipeline_service.dart` `_organizeDownload` 把它转成 `VideoDownloadPipelineActionRequired`——包里只要有一部「季号写不出来」的续作（`Next Summit` 没有任何季号 token），本作也整理不了。
  - 实测（本 worktree 跑 `FilenameParser`）：`Yama no Susume [01]`、`... Second Season [01]`、`... Third Season [01]`、`... Next Summit [01]` 四个文件名与目录名的 `season` 全为 null（英文序数词 `Second/Third Season` 目前解析器也不认）。
- **[x] ① 已修复** — 本条提交（分支 `worktree-agent-a31007b195567c055`，message 尾行 `Feedback: kg41f2PGdC`）：
  - 整理器新增 `_packSeasonLayout`（`video_download_organizer.dart`）：正片分布在 ≥2 个父目录时，父目录名走与 `parseVideoPath` 同一判据给季号（文件名季号 > 目录季号 > 任务默认季）；单目录种子不取目录季号，旧行为不变。
  - 季号仍判不出的目录 ≥2 个且集号重叠时，按「系列名是否为其余目录系列名的**真词前缀**」找唯一基础作品（`yama no susume` ⊂ `yama no susume next summit`）。基础作品沿用默认季；其余目录标 `VideoOrganizationFilePlan.siblingWork`，按源目录结构镜像落位到 `<作品>/<源目录>/<原文件名>`（与 BUG-2007 并列正片同口径，源路径唯一 ⇒ 目标唯一，绝不覆盖）。找不出唯一基础作品（同系列不同版本目录）时什么都不改，撞名照旧显式失败——不猜季号。
  - 取舍：**不做**「Next Summit = 第 4 季」之类的标题→季号映射（硬编码且对 AniDB 主源根本不成立：AniDB 里续作是另一部 aid）；续作的规范身份交给媒体库的自动识别 / 人工确认。
  - 管线：并列作品行仍是 `kind: 'video'`（`video_download_job_files.kind` 有 CHECK 约束，不为此改 schema），用「剧集任务 + video + 无集号」编码（`isVideoDownloadSiblingWorkRow`；受管剧集任务里认不出集号的正片此前一律进 Extras，这个组合不可能出现过）。导入阶段 `_importSiblingWorks` 按源目录各建一个合集、不进任务合集；字幕阶段跳过（任务身份不是它的身份）；刮削只认任务合集（`downloadJobWork` 按 `collectionId` 选）。删除对账照旧把它算作任务的视频产物：只删本作不会整任务连文件删掉同种子里的续作。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/video/download/video_download_organizer_test.dart` 组「multi-directory packs (kg41f2PGdC)」：用户原包形态（本作 + Next Summit + SPs 特典）不再撞名、续作成并列作品且目标唯一；`Season 1/`、`Season 2/` 目录给季号；单目录种子不被发布根尾数改季；同系列两版本目录仍显式撞名失败。
  - `fushi/test/media/video/download/video_download_pipeline_service_test.dart`「a pack with a sibling work imports it as its own collection, outside the job collection (kg41f2PGdC)」：真管线 import 阶段，任务合集只含本作两集，续作按目录单独成合集，全部行标 imported。
- **备注**：未真机复测（纯整理计划 / DB 行为）。英文序数词季目录（`Second Season` / `Third Season`）仍不被 `native/fushi_compute/src/parse/media_name.rs` 识别，这类目录在本修复下归为「并列作品」而不是第 2/3 季；若要把它们并进同一合集按季排，需在 Rust 解析器加序数词规则（另开）。
