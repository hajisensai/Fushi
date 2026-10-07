## BUG-3068 · 自动补字幕把重制版/TV集/无关剧集的字幕装到电影上
- **报告**：2026-10-08（用户：哆啦A梦剧场版整库刮削后，自动补字幕装上的 sidecar 多处是别的作品）
- **真实性**：✅ 真 bug。用户库里的实例：
  1. 1986「のび太と鉄人兵団」← Jimaku `映画ドラえもん.新・のび太と鉄人兵団.はばたけ.天使たち.WEBRip.Netflix.ja[cc].srt`（2011 重制版）；
  2. 1985「のび太の宇宙小戦争」← Jimaku `…のび太の宇宙小戦争.2021.WEBRip…`（2022 重制版）；
  3. 1989「のび太の日本誕生」← Jimaku `…新・のび太の日本誕生.WEBRip…`（2016 重制版）；
  4. 2006「のび太の恐竜2006」← AJATT `映画ドラえもん.のび太の恐竜.WEBRip…`（1980 版）；
  5. 1997「ねじ巻き都市冒険記」← AJATT `anime_tv/doraemon-(2005).html` 的 `Doraemon (2018.05.18).srt`（TV 系列一集）；
  6. 1999「宇宙漂流記」← OpenSubtitles 2109485 `Pinky.And.The.Brain.S03E25.DVDRip.XviD-SAiNTS.srt`（毫不相干的剧集）。

  根因：**字幕候选的数据模型里没有作品身份，补字幕服务也从不核对作品**——「搜索词搜得到它」被当成了身份担保，而三家来源的搜索都担保不了：
  - `fushi/lib/src/media/video/subtitle/video_subtitle_backfill.dart:222-226`（修前）：搜索结果只按语言排序就取前 `maxCandidates` 条下载落盘，唯一的内容判据是时长校验；
  - `packages/fushi_engine/lib/media/video/subtitle/video_subtitle_provider.dart:54-117`（修前）：`VideoSubtitleCandidate` 只有文件名 / 集号 / 语言，来源知道的条目名、年份、电影/剧集、外部 id 全被丢掉，调用方无从比对；
  - Jimaku：`packages/fushi_engine/lib/media/video/jimaku_client.dart:612-620` AniList / TMDB 查不到时按标题模糊搜，「のび太と鉄人兵団」命中「新・のび太と鉄人兵団」条目；
  - AJATT：`fushi/lib/src/media/video/subtitle/ajatt_subtitle_provider.dart:207-216` 目录标题双向子串匹配（查询「映画ドラえもん のび太のねじ巻き都市冒険記」包含目录名「ドラえもん」），`:232-238` 分类过滤只分动画/真人、不分电影/剧集，于是 `anime_tv` 的 TV 系列进了电影的候选；
  - OpenSubtitles：`packages/fushi_engine/lib/media/video/subtitle/open_subtitles_client.dart:619-626` moviehash 档排第一、会撞车，而 `parseOpenSubtitlesSearchResponse`（修前 `:214-247`）只取了 `feature_details` 的季集号，把能认出「这是 Pinky and the Brain 的一集」的 `feature_type` / `parent_imdb_id` / `parent_tmdb_id` 全丢了；
  - 时长校验（`packages/fushi_engine/lib/media/video/subtitle/subtitle_timing_check.dart:47-52`，`≤ 时长×1.15+60s`）**结构上**分不开重制版（1986 版 98 分钟 / 2011 版 108 分钟），也不拒「只覆盖一半」的短字幕（那是有意保留 OP/ED 歌词轨）——它不是作品身份判据，不该靠收紧它来修，未改动。
- **[x] ① 已修复** — f9b73c7129：候选带上来源自述的作品身份 `SubtitleWorkClaim`（`video_subtitle_provider.dart`；Jimaku 条目名/日文名/AniList/TMDB 号段/`flags.movie`、AJATT 目录名与 `*_movie`/`*_tv` 分类与 `.kitsuinfo.json` 确认的 AniList id、OpenSubtitles `feature_details`（剧集取父级）、SubDL `results[0]`）；新增 `fushi/lib/src/media/video/subtitle/subtitle_work_identity.dart` 的 `checkSubtitleWork` 拿它与刮削出的目标身份比：种类矛盾（含发布名 `SxxEyy`）拒 → 外部 id 都有且全不等拒 →（电影）来源/发布名年份差一年以上拒 → 发布名带标题时必须等于目标某个标题（来源已用 id / 条目名确认时放宽为「不是目标标题的包含变体」），不带标题时看来源条目名。剧集只用种类与 TMDB/IMDb（季间 AniList 不同、文件名是系列名+集号）。补字幕服务在**下载前**执行，错作品不再占下载名额、不再吃 OpenSubtitles 配额。没有为「新・」「2021」写任何特例——它们只是让两个标题不相等的普通差异。
- **[x] ② 已加自动化测试** — f9b73c7129：`fushi/test/media/video/subtitle/video_subtitle_backfill_work_identity_test.dart`（真实 Jimaku / AJATT / OpenSubtitles provider + MockClient 桩出线上响应形状，走完整补字幕服务：上述 1–6 逐条拒收且不下载、不落 sidecar；AniList id 矛盾拒；对照 1992「雲の王国」同名 Netflix 文件照常装上）；`fushi/test/media/video/subtitle/subtitle_work_identity_test.dart`（发布名解析、每种证据单独生效、剧集目标不受标题/年份/AniList 影响）。变异实测 8 个变异（去掉作品核对 / 种类 / id / 年份 / 变体规则、改回包含即收等）全部被杀。
- **备注**：手动选字幕的界面（字幕对话框 / 工作台）仍列出全部候选由用户挑——核对只用于无人值守的自动落盘。**Follow-up（未在本修复范围内）**：下载流水线（`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart` 的 `_selectVerifiedSubtitle`）是另一条无人值守的自动落盘路径，本次**未接**作品核对（`checkSubtitleWork`），需另开任务接入。
