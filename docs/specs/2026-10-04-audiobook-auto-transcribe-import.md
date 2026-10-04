# 有声书：下载后自动转录入库（2026-10-04）

## 问题

本仓有声书是字幕驱动的。下载回来的有声书只要缺字幕（CoreAudio/TMW 单卷 m4b、nyaa 音频包、
之后的 Audiobookshelf 条目——绝大多数真实形态），导入分类就判 `audiobookMissingSubtitle`，
文件烂在下载目录，用户得手动开导入对话框、选音频、点转录、守着弹层跑几个小时（弹层一关就暂停）。
另一个被忽略的分支：**有字幕 + 音频、没有正文**被判 `audiobookMissingText`，而书导入对话框
早就支持「只有字幕 → 独立字幕书」，根本不需要 ASR。

## 数据流（改后）

```
下载完成
  ├─ 导入执行器（importAfterDownload 任务：nyaa 包 / HTTP 直链 / ABS zip）
  │    classifyDiscoveryDirectory(audiobook)
  │      audio+subtitle+content → AlignAudiobookPlan            （不变）
  │      audio+subtitle         → SubtitleAudiobookPlan          （新：原 audiobookMissingText）
  │      audio                  → TranscribeAudiobookPlan(content?)（新：原 audiobookMissingSubtitle）
  │      无 audio               → audiobookMissingAudio          （不变）
  └─ 管线「只下载」有声书任务完成（CoreAudio 合集单卷；不能改成 importAfterDownload，
       它挂着同包多卷的种子槽位接力）→ onDownloadOnlyCompleted 端口 → 同一个执行器

TranscribeAudiobookPlan → transcribeAudiobook 端口
  app：开关开 + 本机支持 ASR → 入「转录后入库」队列，任务按 deferred 完成
       否则抛 audiobookMissingSubtitle（与改前逐字节同一行为）
  server：抛 audiobookMissingSubtitle（行为不变；服务端 ASR 另议）

AudiobookTranscribeImportQueue（引擎，纯 Dart，落盘 JSON，单并发，重启续跑）
  transcriber 端口（app：createAsrTranscriptionService，缺模型自动下载，语言 = EPUB dc:language
                    → 「上次转录语言」偏好 → ja）
  → SRT（+ tokens sidecar）
  → importTranscribedAudiobook：有正文 → 对齐导入（ASR 放宽阈值 kAsrSuggestedSimilarityThreshold）
                                无正文 → 独立字幕书
```

## 改动清单

- 引擎 `discovery_import_plan.dart`：两个新计划；有声书音频按 `compareAudioFilePath` 自然序
  （原字符串序让 `10.mp3` 排在 `2.mp3` 前——转录把多文件拼成一条时间轴，顺序错 = 正文错）。
- 引擎 `discovery_import_executor.dart`：`DiscoveryDomainImporters` 加 `importSubtitleAudiobook`、
  `transcribeAudiobook` 两个端口；`DiscoveryImportOutcome.deferred`。
- 引擎 `media/audiobook/standalone_subtitle_book.dart`：从 `BookImportDialog._importSubtitleBook`
  抽出的独立字幕书导入原语（对话框改调它，行为不变）。
- 引擎 `media/audiobook/audiobook_transcribe_import_queue.dart`：队列。
- 管线 `VideoDownloadPipelineService.onDownloadOnlyCompleted` 可选端口。
- app：转录端口实现、AppModel 装配、偏好 `audiobook_auto_transcribe`（默认开）+ 设置项、
  浏览 › 下载 页签的转录任务列表（进度 / 取消 / 重试 / 移除）、i18n。
- server：两个新端口装配（字幕书照常导入；转录挡下）。

## 不做 / 风险

- 不碰 CoreAudio 的「只下载」策略与合集槽位逻辑。
- 自动转录很重（CPU/GPU 数小时、模型数百 MB）：开关可关；关掉或平台不支持时行为与改前一致。
- 自动入库的同名书沿用 `DuplicatePolicy.skip()`：已在库则不重复入库。
- 服务端 ASR 自动转录不在本次范围。
