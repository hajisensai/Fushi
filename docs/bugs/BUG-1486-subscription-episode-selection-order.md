## BUG-1486 · 订阅选集季号错误、重复下载且顺序按完成时间乱序
- **报告**：2026-08-10（用户：）
- **真实性**：✅ 真 bug。用户库中「无职转生Ⅲ」合集的 `sort_index` 实际是 `E04,E03,E02,E05,E06,E07,E01`：订阅的单集任务并行完成后，`video_download_pipeline_service.dart:_importMedia` 逐个调用 `importSplitPlaylist`追加成员，从未按季集号自动重排；详情页又直接按这个顺序显示选集。同时 `video_download_subscription_service.dart:_logicalItem` 自建正则，把 `Mushoku Tensei III: ... - 02` 记为 `S01E02`，而统一 `FilenameParser`/归档层记为 `S03E02`；订阅入队前也不查确认作品的已入库集，第 2–4 集因而重复下载，直到归档才报目标已存在。
- **[x] ① 已修复** — 资源标题、归档文件和订阅逻辑统一复用 `parseVideoFilename`，并让罗马数字季度支持 `III: 副标题`形式；订阅每轮只建一次已管理季集索引，同时检查同一 provider identity 的下载文件和规范作品合集，已存在集持久标为 `skipped`；下载流水线每次自动追加后按季、集、标题稳定重排，且不更改用户手动排序的 LWW 时钟。
- **[x] ② 已加自动化测试** — `filename_parser_test.dart` 覆盖 `Mushoku Tensei III: ... - 02` 与 `Re: Zero` 负向样例；`video_download_subscription_service_test.dart` 断言逻辑键为 `S03E02`并在确认本地集存在时不入队；`video_import_split_playlist_test.dart` 从真实乱序 `4,3,2,5,6,7,1` 验证自动整理为 `1–7`。
- **备注**：AniList `178789`、2026 年与 14 集的作品身份本来就正确；本缺陷属于订阅选集、去重与合集顺序，不是刮削到了其他作品。
