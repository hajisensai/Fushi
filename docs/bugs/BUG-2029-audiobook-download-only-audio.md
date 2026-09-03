## BUG-2029 · 下载有声书只落孤立音频:成不了书且原因谎报
- **报告**：2026-09-02（用户：下载有声书不应该自带音频文件和对齐文件吗）
- **真实性**：✅ 真 bug（两处）。
  - 谎报原因：`fushi/lib/src/media/discovery/import/discovery_import_plan.dart:163-166`
    对 audiobook 单文件**无条件**返回 `audiobookMissingAudio`——哪怕那个文件就是
    m4b。真正缺的是字幕（本仓有声书是字幕对齐驱动：
    `fushi/lib/src/media/audiobook/audiobook_alignment_service.dart:125-126`
    `subtitlePath` 必填、`audioPaths` 可空）。
  - 无补救入口：CoreAudio/TMW 单卷走
    `fushi/lib/src/media/discovery/sources/core_audio_discovery_source.dart:450`
    `importAfterDownload: false`，任务正常完成但只落一个孤立音频，UI 不提示还差
    什么，文件烂在下载目录里。
- **非 bug 的部分（用户前提修正）**：不是「下载漏下了对齐文件」——TMW 种子里
  本来就没有。实测三个合集共 641 个文件：`1616763` = 278 m4b + 12 pdf、
  `2090741` = 258 m4b、`2091197` = 93 m4b，**零** epub/srt/txt/lrc。
  「顺便自动找 EPUB」亦不成立：① 找到 EPUB 仍缺字幕，照样成不了书
  （`discovery_import_plan.dart:229-233` `audiobookMissingSubtitle`）；
  ② 唯一声明 `DiscoveryMediaKind.novel` 的源是 nyaa（`app_model.dart:4396-4406`），
  从目录随机抽 11 个系列名搜 Literature 分类**命中 0**（唯一非零是宽泛匹配假
  阳性，用乱码串对照返回 0）。根治要接强制对齐（正文 + 音频 → cue），另行立项。
- **[x] ① 已修复** — `discovery_import_plan.dart` 删掉 audiobook 单文件特例，
  改为委托 `classifyDiscoveryDirectory(kind, [filePath])` 走同一套判据，缺什么报
  什么（孤立 m4b → `audiobookMissingSubtitle`，孤立 srt/epub → `audiobookMissingAudio`）；
  `video_download_jobs_panel.dart` 新增纯判据 `videoDownloadJobNeedsAudiobookPairing`
  与 `onPairAudiobook` 入口，`downloads_page.dart` 的
  `_pairDownloadedAudiobook` 把该任务真实落盘的音频预填进 `BookImportDialog`
  （`initialAudioPaths`），用户只需再给一个字幕即可成书。提交：见本分支。
- **[x] ② 已加自动化测试** —
  `fushi/test/media/discovery/import/discovery_import_plan_test.dart`
  「有声书:单文件永远不够料,但缺的那一样要报准」按 blocker 断言四种单文件形状
  （旧断言只查 `isA<UnsupportedPlan>()`，形状对、原因错，抓不到谎报）；
  `fushi/test/pages/video_download_jobs_panel_test.dart` 两条——纯判据五种任务
  形状 + widget 断言只有孤立音频任务露出补对齐入口且回调带对任务。两处均做过
  变异实测（退回旧行为后确认变红，还原后 sha256 一致）。
- **备注**：`DiscoveryImportBlocker` 的枚举注释写着「UI 层负责翻译成用户文案」，
  但全仓无任何 UI 消费它；导入失败时用户看到的是
  `video_download_pipeline_service.dart:3494` 抛出的
  `DiscoveryImportBlockedException(...)` 原始英文 `toString()`。本单只修正了
  blocker 的**取值**，本地化落地未做。
