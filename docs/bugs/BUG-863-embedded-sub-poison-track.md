## BUG-863 · 内嵌字幕单遍抽取被一条毒轨整批击穿

> 原以工具自动取号建为 BUG-861，与并发分支 PR#190（Shift 悬停连续查词）撞号，改号为 863。

- **报告**：2026-07-16（用户：运行日志 `extractEmbeddedSubtitlesViaFfmpeg` ffmpeg exit -22）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/misc/desktop_audio_clipper.dart:1041`（单遍多轨命令）+ `hibiki/lib/src/media/video/video_subtitle_source.dart:261`（`subtitleFormatForCodec` fail-open）。
  - 抽取走单遍多轨命令 `-y -i in -map 0:s:0 out0 -map 0:s:1 out1 …`（BUG-104 优化，整容器只读一遍）。
  - `subtitleFormatForCodec` fail-open：未知/非图形 codec 一律当文本 → `.srt`，赌「顶多这一轨失败」。
  - 但 ffmpeg 在写任何数据包**之前**先初始化所有输出编码器。只要有一条文本类 codec（如 `eia_608`/字幕 caption）在 output-open 阶段无法转码，整条命令直接 `AVERROR(EINVAL) = -22`，打印 `Error opening output files: Invalid argument`，**一个包都没写** → `written` 为空 → 整批全丢，连同容器里正常的 `ass`/`srt` 轨一起没了。这是「明明有字幕、切内封却一条都出不来」的静默失败根源。
  - 1045 行原注释「一个坏轨仍能让其它轨写出」的假设只在**写包阶段**失败时成立；output-open 阶段的 EINVAL 发生在写包之前，击穿该兜底。
- **[x] ① 已修复** — `desktop_audio_clipper.dart` `extractEmbeddedSubtitlesViaFfmpeg`：单遍 `written.length < outputs.length` 时对每条仍缺失的轨用 `buildFfmpegSubtitleArgs` 逐轨重抽（沿用同一 size-scaled `timeout`，非单片 30s），毒轨只损失自己；单遍全成功零开销不进回退。（提交见 PR）
- **[x] ② 已加自动化测试** — `hibiki/test/utils/desktop_audio_clipper_test.dart` 新增组「毒轨逐轨回退 (BUG-863)」：注入 `_FakePoisonFfmpegBackend`（模拟 output-open 整批 EINVAL），断言 3 轨含毒轨 1 时结果为 `{0,2}`（好轨保住、毒轨只损失自己）、单遍 + 3 条逐轨共 4 趟；另断言无毒轨时单遍成功不触发回退（零开销）。
- **[x] ③ 增强·负缓存哨兵**（补合 `fix/embedded-sub-batch-einval` `901b0d977`，原以旧号 BUG-818 记录）——
  逐轨回退中一条轨 ffmpeg **确定性**非零、非超时退出（该 build 无解码器的 codec）时，在其输出旁写 `.unsupported` 哨兵（`kUnsupportedEmbeddedSubtitleSentinelSuffix`）；后续 prewarm 遇哨兵直接跳过，不再重读整（可能数 GB）容器、不再刷同一条 exit -22 错误日志。超时（`returnCode == null`）**绝不写**哨兵，保持 BUG-104 可重试。逐轨回退仍保留 develop 已落的批量超时门（`result.returnCode != null`，超时批次不逐轨重试以免把 1 次超时放大成 N 次）。同批仅当**全轨**为空才 `_reportFfmpegFailure`，被救回一部分不再刷错误日志。
  测试：`hibiki/test/utils/desktop_audio_clipper_test.dart` 新增组「per-track fallback (BUG-863)」（`_MinBuildFakeFfmpegBackend`：坏轨 → 好轨保住 / 单遍全好不回退 / 全坏空结果）；`hibiki/test/media/video/video_subtitle_source_test.dart` 断言确定性失败写哨兵后 manual 不再重抽、超时不写哨兵仍可重试。
- **备注**：日志同批还有一条 Google Drive 同步瞬时超时不重试，另见 BUG-864。
