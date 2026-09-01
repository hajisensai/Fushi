## BUG-2007 · 多部电影一个种子时仅最大文件算正片，其余被扔进 Extras 不入库不刮削
- **报告**：2026-09-01（刮削重设计调查；实证用户库「哆啦A梦剧场版」多部剧场版混装乱象）
- **真实性**：✅ 真 bug。三层：`video_download_organizer.dart`（修前 :106-113/:202-212）movie 形态只把体积最大的文件抬成正片，其余视频一律镜像进 `Extras/`；`_persistOrganizationIntent` 按路径含 `/Extras/` 标 `kind:'extra'`；import 只取 `kind=='video'` 且 movie 分支只入库 `files.first`——三处叠加，除最大那部外的剧场版**不入库、无作品身份、永不刮削**。
- **[x] ① 已修复** — 本分支：① organizer 新增并列正片判据 `_isStandaloneMovieCandidate`（不在特典目录/非显式附件、体量 ≥ 最大正片 1/4、无集号、能解析出标题），命中者各排各的电影目录；② import movie 分支逐部入库（首文件沿用 job.title，并列正片用整理后文件名）；③ scrape 阶段对「一 job 多作品」不再强绑单一身份——整批正常完成，作品交给 P2 待确认队列/自动补刮。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_organizer_test.dart`（并列正片/特典目录/小文件门槛四路）；`fushi/test/media/video/download/video_download_pipeline_service_test.dart`（「import 逐部入库」「多作品批次不强绑正常完成」两用例）。
- **备注**：既有「movie organizer chooses the largest video」用例原样通过（trailer 体量低于门槛仍进 Extras）；文件名解析器会剥「Movie」等发布噪音词，并列正片目录名取清洗后的主干。
