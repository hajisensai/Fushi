## BUG-2760 · AI 下载多集合集包被判电影：整套进 Extras 只导入一集
- **报告**：2026-09-28（用户：AI 下载「スーパーの裏でヤニ吸うふたり」后库里只有一集，走电影详情布局）
- **真实性**：✅ 真 bug。用户生产库（只读核对）：任务 `cf17ea03…` 身份 `{"providerId":"tmdb","mediaId":"1749852","mediaKind":"movie",…}`（同作品 AniDB 实为 19479，TV），资源是 12 集合集包 `[Karin] Yanisuu - 01..12 [ABEMA Early Release][WEB-DL 1080p AVC-8bit AAC] [CRC].mkv`；`job_files` 一个 `kind=video` → `<title> (2026)/<title> (2026).mkv`，其余 11 个 `kind=extra` → `<title> (2026)/Extras/<原名>`。
  根因链（develop `3d5d1608ed2` 行号）：
  1. `packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart:2313-2323` 只按 `job.mediaKind` 选 `VideoOrganizationKind.movie/episodic`，身份 kind 是唯一判据；
  2. `packages/fushi_engine/lib/media/video/download/video_download_organizer.dart:182-192` movie 形态根本不解析集号，`:106-113` 把最大文件抬成正片，其余走 `:202-229` 进 `Extras/`（`_extraSegments` `:531-542`）；`_isStandaloneMovieCandidate`（`:480-488`）要求解析不出集号，`:479` 注释自认「带集号的误标剧集不在修复范围」——正是这条缺口；
  3. `_importMedia`（pipeline `:3391-3516`）只收 `kind=video`，只有 tv 走 `importSplitPlaylist` 建合集（`:3417`），movie 逐文件独立入库，最大文件用 `job.title` 命名（`:3490-3493`）→ 库里「一部电影」= 第 N 集；
  4. 上游：AI 状态机 movie 身份直接定 download（`fushi/lib/src/media/video/acquisition/video_acquisition_reducer.dart:713-716`），`video_acquisition_resource_picker.dart:131-136` movie 只取代表条，从不看资源是不是合集包/逐集发布；
  5. 身份来源：`fushi/lib/src/media/video/discovery/video_discovery_service.dart` 的弱匹配合并里，集数未知的 anime 条目聚合类型 = 未知（`_aggregationKind`），不与电影冲突，同名同年的 TMDB 电影身份把正在放送的 TV 动画整组带成「电影」（`build()` 里 movieAggregation 让电影身份当主项）。
  集号解析器 `parseVideoFilename` 对 `[Karin] Yanisuu - 12 [...]` 能解出 12，不是问题所在。
- **[x] ① 已修复** — `255a8aadeba`（分支 `claude/video-dl-movie-episodic`）：
  - 整理器（根因层）：新增纯函数 `looksLikeEpisodicPack(List<String> fileNames)`（`video_download_organizer.dart`），保守判据：特典（目录/NCOP/PV/Trailer）与带电影提示（`劇場版`/`Movie`）的文件不参与，其余每个视频都必须解析出集号且 ≥2 个不同集号。`plan()` 在 movie 请求命中时改按 episodic 整理（`Season 01/<title> (year) - S01Exx`），并在 `VideoOrganizationPlan.kind` 上报实际形态；删掉 `_isStandaloneMovieCandidate` 的「不在修复范围」缺口注释。
  - 管线：`_organizeDownload` 见计划改判为 episodic 时先 `_reclassifyMovieJobAsEpisodic` 把任务 `media_kind` 改 tv（`discovery_category` movie→tv；旧行无身份快照则按改判前形态补写一份），再落文件计划 → 导入走 `importSplitPlaylist` 建合集、`_episodeTitle` 逐集命名，字幕阶段也按剧集逐集配。
  - 身份安全：`_mediaReference` 在「快照 kind ≠ 任务 kind」时丢弃 TMDB/IMDb id（TMDB /movie 与 /tv 是两个 id 空间），provider 为 tmdb 的退成 `unknown` → 不再拿 `/tv/1749852` 去刮一部别的剧，任务 import 后完成、交给媒体库自动识别；MAL / AniDB 等不分形态的 id 保留。
  - AI 选资源：`_planMovieDownload`（picker）——代表条是合集包（`isLikelyBatchVideoRelease`）时照旧整包下但标 `usesBatch`（摘要如实说合集），落地由整理器改判；代表条本身是单集、组里 ≥2 个集号的逐集剧集卡给不出电影计划（null → 下一张），不再拿一集冒充电影。
  - 发现合并：`_aggregationKind` 对集数未知但 `airingStatus == airing` 的 anime 条目判为 tv（电影不存在「放送中」状态），与同名同年 TMDB 电影不再弱合并；状态也未知时维持 BUG-1531 口径。
- **[x] ② 已加自动化测试** — `255a8aadeba`：
  - `fushi/test/media/video/download/video_download_organizer_test.dart` 组「movie identity holding a multi-episode pack (BUG-2760)」：12 个 `[Karin] Yanisuu - NN …` 全部 `Season 01/S01E01..12`、无 Extras、`plan.kind == episodic`；真电影 + NCOP/PV 仍是正片 + Extras；无集号正片 + `Bonus Clip - 01/02` 仍按电影；`looksLikeEpisodicPack` 负例（同集两版本 / 单片 / 柯南剧场版 Movie 01..03 / 特典目录编号文件）。
  - `fushi/test/media/video/download/video_download_pipeline_service_test.dart`「a movie job holding a multi-episode pack is reclassified to tv …(BUG-2760)」：TMDB 电影身份 + 3 集包从 organize 跑到完成 → 任务 tv、有 collectionId、全部 `kind=video` 且在 `Season 01`、书名 `Show - S01E01..03`、未拿电影 TMDB id 去刮（撤掉管线修复时该用例卡在 scrape needsAttention，已验证）。
  - `fushi/test/media/video/acquisition/video_acquisition_resource_picker_test.dart`：movie 身份下合集包卡 → `usesBatch`；逐集剧集卡 → null。
  - `fushi/test/media/video/discovery/video_discovery_service_test.dart`：放送中、集数未知的 anime 不被同名同年电影吞并；状态未知仍合并。
- **备注**：
  - 存量不迁移（用户删掉重下）。
  - 相关观察（不在本任务修）：详情页左上「竖版封面框里一张横向截帧、上半截帧下半模糊」是 `fushi/lib/src/media/video/cover_ui/portrait_cover_image.dart` 的**设计行为**（竖槽里横图 → 主色底 + 放大模糊垫底 + 前景 `contain`，Kazumi 式统一竖版），不是详情页布局缺陷；之所以出现截帧，是这条被误判成电影的条目没有刮到海报（电影身份刮削/海报链未产出），只能回退到视频截帧。本修复后该类任务改判为剧集、交给自动识别，拿到海报后即恢复正常。截图里前景偏上而非居中的具体原因未在真机核实。
  - 后续项：① AI picker 在电影身份下没有「优先真电影卡、合集包殿后」的两趟排序（改 `_findPlan` 会破坏「换一个」游标的单调性，未做）；② 发现合并对「集数与放送状态都未知」的 TV 动画仍可能被同名同年电影弱匹配带偏（BUG-1531 反面约束，缺可用信号）；③ 身份本身仍是错的 TMDB 电影 id——改判后丢弃了它，但 UI 在下载前没有提示「资源看起来是剧集」。
