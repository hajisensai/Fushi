## BUG-2004 · 下载管线对错命名空间身份强制刮削致歧义卡死，无身份反而直接完成
- **报告**：2026-09-01（用户：「强制我刮削，我无法指定他不刮削」；实证 Re:Zero E14 任务 needsAttention「匹配结果存在歧义，需要人工确认」）
- **真实性**：✅ 真 bug。修前判据（`video_download_pipeline_service.dart:3410` 与 `_scrapeMedia` :3489）：`metadataProvider/externalId` 非空即强制进 scrape——但解析层只认 AniDB 主源（tmdb 仅提示），anilist/bangumi 的 confirmedLookup 被 `VideoSourceScrapeCoordinator._resolveWork` 整条丢弃（:586-603），退化为拿本地化显示名对 AniDB 目录模糊搜 → 歧义 → needsAttention，且 `scrapeImportedWork` 不传确认回调（:96-106），管线内歧义**结构上不可能**被交互消解；而 `metadataProvider == null` 的任务反而跳过刮削直接完成。方向正好反了。
- **[x] ① 已修复** — 本分支：判据反转为唯一一条——`_confirmedAniDbId(job)`（identity_json 快照的 anidbId，回退 provider=='anidb' 的 externalId）非空才进 scrape，且 lookup 恒为 AniDB confirmed（直接命中、零模糊匹配）；无 AniDB 身份的任务 import 后正常完成，作品落进视频页待确认队列（P2）由自动补刮认领或用户手动指定。`_scrapeMedia` 加同判据防御分支（旧行重试不再卡死）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart`：新增「anilist-only 身份在 scrape 阶段直接完成（BUG-2004）」与「AniDB 身份以 confirmed lookup 进入刮削管线」两用例；三个既有用例的等待谓词按新契约改为 completed；「绝不按标题回退映射」用例改带 AniDB 身份后原样守住。
- **备注**：与发现确认时的就地身份解析（BUG-2003）配对：正常路径下歧义在下载确认那一刻就被消解，管线里根本不会出现。
