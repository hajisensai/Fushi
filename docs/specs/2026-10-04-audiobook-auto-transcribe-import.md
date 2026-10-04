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

## 有意的行为变化（审查后确认）

- **开关只管 ASR**。「字幕 + 音频、无正文 → 独立字幕书」与「素材库身份键命中字幕 → 直接
  入库」不依赖设备端转录，开关关掉也照常发生；关掉之后**只**是不再排转录（只有音频的包
  照旧以 `audiobookMissingSubtitle` 挡下 / 只下载任务照旧留给「配对」）。
- 服务端同样受益于前一条：「字幕 + 音频、无正文」的包以前挡下，现在入库成字幕书。
- 有声书音频改自然序（`Part 2` 在 `Part 10` 前）。
- 正文 EPUB 已在库：**入队前**就以 `audiobookBookAlreadyInLibrary` 挡下（与齐料包同一
  原因码与补救文案），不先跑几个小时转录再在入库那步失败
  （`isDuplicateDiscoveryAudiobookContent` 与导入器同判据）。
- 旧版种子服务（`AnimeDownloadService`）的入库端口改回传 `DiscoveryImportOutcome`：
  移交转录（deferred）记为已完成，不再被 0 条新增误判成 import failed。
- 关库（迁移 / 恢复 / 换数据根）前关闭转录队列：在跑的入库等它写完，在跑的转录在
  检查点暂停、任务回到排队，下次启动续跑。

## 已知限制

- 「只下载」任务的完成钩子不落盘：钩子执行中进程被杀，不会补跑（文件仍在，任务面板
  的「配对」入口可手动补救）。钩子在管线里同步执行，素材库配齐时的对齐导入会占用
  管线，与齐料包的导入阶段同一性质。
- 没有公共目录的整包（文件直接落在下载根目录）书名取下载目录名或第一份文件名。
- Audiobookshelf：下载用的 access token 一小时过期，同一轮下载断线续传会 401（重试会
  重新物化地址；ABS 打包 zip 本身也不支持续传）。

## 不做 / 风险

- 不碰 CoreAudio 的「只下载」策略与合集槽位逻辑。
- 自动转录很重（CPU/GPU 数小时、模型数百 MB）：开关可关；关掉或平台不支持时行为与改前一致。
- 自动入库的同名书沿用 `DuplicatePolicy.skip()`：已在库则不重复入库。
- 服务端 ASR 自动转录不在本次范围。
