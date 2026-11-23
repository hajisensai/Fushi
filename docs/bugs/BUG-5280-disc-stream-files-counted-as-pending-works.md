## BUG-5280 · 逐个入库的原盘流文件（BDMV/STREAM/*.m2ts）被当成作品，挂满「待确认身份」
- **报告**：2026-11-23（用户：视频库提示「72 部作品还没确认身份」，问为什么 AI 不自动处理）
- **真实性**：✅ 真 bug。本机库实测（控制通道 `GET /api/admin/video/works?pending=true`）72 部待确认里 71 部是 `…/BDMV/STREAM/000NN.m2ts`：2026-08 BUG-4245 修复前，响け!ユーフォニアム 原盘下载目录被逐文件导入（179 行，无来源，全在用户清单合集「Hibike! Euphonium」里），盘结构在磁盘上完好。根因 `packages/fushi_engine/lib/media/video/metadata/video_source_work_planner.dart` `videoBookJoinsScrapePlan`（修前 :72-75）只排除特典 / 纯音频 / yt-dlp，盘内流文件不排除；`plan` 里 `parsed.episode == null && !discMember`（`isDiscMemberPath` 只认 `.mpls` / `.dvdtitle`）→ 每个 `.m2ts` 各成一部作品，标题是片段号「00002」，资料源与 AI 都无从识别，近期运行记录里也没有挂起原因。
- **[x] ① 已修复** — 新增纯函数 `isDiscStreamFilePath`（`disc/disc_format.dart`：`BDMV/STREAM/*.m2ts`、`BDMV/STREAM/SSIF/*.ssif`、`VIDEO_TS/*.VOB`），`videoBookJoinsScrapePlan` 据此把盘内流文件排出刮削计划（与 `video_scrape_scope.dart` 不进 `BDMV` / `VIDEO_TS` 同口径）。待确认数由同一计划器算，提醒条随之从 72 降到 1。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_source_work_planner_test.dart`「逐个入库的原盘流文件…不当作品计划」；`packages/fushi_engine/test/media/video/disc/disc_stream_file_path_test.dart`。
- **备注**：库里那 179 行「00000」卡片本身仍在（用户清单合集的成员，有观看进度），把它们换成正规盘合集（`DiscLibraryImporter` 导入盘根、回收流文件行）会改动用户库内容，未自动做，留给用户决定。
