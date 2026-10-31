## BUG-3926 · download-subtitle-retry-drops-anilist
- **报告**：2026-10-31（用户：订阅的《凶乱令嬢ニア・リストン》S01E04 没有自动下载日语字幕）
- **真实性**：✅ 真 bug。用户库实测：E04 下载任务的字幕行 `status=unavailable`、`error=provider request timed out`（10-27 21:49 记、10-31 14:50 最后一次重试仍同样）；而 Jimaku 条目 12710 自 10-28 起就有 E04 的日语字幕（ABEMA `ja[cc].srt`、LoliHouse `[JPN].ass`、NanakoRaws）。
  - 下载当时 Jimaku 还没有 E04，记 `unavailable` 本身正常；问题在之后的定时重试。
  - 根因 ①：重试 / 刮削后补字幕按**库内刮削身份**搜（`fushi/lib/src/media/video/subtitle/library_video_subtitle_backfill.dart:126-171`）。该作品刮削主源是 TMDB，落库身份只有 tmdb 312850 / imdb / tvdb，**没有 AniList**；下载任务（`identity_json`）明明记着 AniList 206949 / MAL 63382，补字幕链路不用。Jimaku 按 `tmdb_id=tv:312850`、按 TMDB 长标题 `凶乱令嬢ニア‧リストン 病弱令嬢に…`（中点是 U+2027）都搜不到条目（实测零结果），只有 `anilist_id=206949` 或 `凶乱令嬢ニア・リストン` 命中。
  - 根因 ②：零候选时只报 `failures.first.message`（`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:3629`、`fushi/lib/src/media/video/subtitle/video_subtitle_backfill.dart:196`）。Jimaku 正常应答但零命中不算 failure，于是界面只剩另一家来源（OpenSubtitles / SubDL，Jimaku 客户端不会抛 `TimeoutException`）的「超时」，真实原因被盖住。
- **[x] ① 已修复** — 新增 `downloadConfirmedReferenceForVideoPath` / `mergeDownloadConfirmedIdentity`（`download_confirmed_identity.dart`）：按文件路径找到产出它的下载任务，把任务确认身份里库内身份**缺的** id（AniList / MAL …）与标题别名补进补字幕身份；同命名空间 id 冲突即不合并，TMDB/IMDb 形态漂移不搬。`withDownloadConfirmedIdentity` 接进 `libraryVideoSubtitleTarget`（下载后缺字幕重试、控制通道补字幕）与 `AppModel._backfillSubtitlesForScrapedWork`（刮削后自动补）。零候选原因改为 `VideoSubtitleRegistry.describeEmptySearch` 逐来源列出（`jimaku: no match; opensubtitles: provider request timed out`），流水线与补字幕两处共用。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/download_confirmed_subtitle_identity_test.dart`（合并规则、库内目标带 AniList、冲突不选、逐来源原因）。
- **备注**：用户现存的 E04 行会在下一轮重试（≤6 小时、14 天窗口内）用新身份补上，无需手动处理。
