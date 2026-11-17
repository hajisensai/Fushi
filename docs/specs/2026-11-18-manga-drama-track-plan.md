# 漫画有声：广播剧 / 动画音轨匹配（实施计划）

对应设计 `2026-11-17-manga-audio-mode-design.md` §9 末段与实施顺序第 7 步：没有现成文本时间表的真人音频（广播剧 CD、动画视频），先 ASR 再匹配，一页 = 匹配器的一个 section（同 PDF 有声书），匹配不上的 cue 只播放不高亮。

## 数据流

1. 用户在制作页按播放顺序选若干音频 / 视频文件。
2. 逐个文件转录：设备端 ASR，经唯一装配入口 `createAsrTranscriptionService(audioProfile: mixedAudio)`（广播剧 / 动画带 BGM 与效果音）；产出 SRT → `SrtParser` → `MangaDramaCue`（带文件下标）。取消 = `requestPause`，识别任务目录保留断点。
3. 切 section：每页由若干「单元」按阅读顺序拼成正文——演出稿与当前 OCR 一致时用演出稿里会发声的行，否则每个 OCR 块一个单元（不要求先做 AI 标注）。
4. 匹配：有声书匹配器 `EpubCueMatcher.probeInIsolate`（与有声书导入同一入口，后台 isolate）。
5. 换回页与块：命中区间按单元区间表换成「页 + 块下标」；铺满音轨切段；同文件相邻、页与块相同的段合并。
6. 剪段：ffmpeg（与合成端同一个 `runMangaFfmpeg` / `buildMangaClipArgs`，视频 `-vn`，最后一段剪到文件末尾）。
7. 写清单并登记：`MangaRenderManifest(continuous: true)` → `registerMangaAudio`，与合成 / 有声书片段同一套 `Audiobooks` / `AudioCues` + 页段 sidecar，漫画卡与阅读器直接能播。

## 复用的现有模块

| 环节 | 模块 |
|---|---|
| ASR | `asr_host.dart` 的 `createAsrTranscriptionService`（算法在上游 `fushi-subtitles`，本仓不改） |
| 归一化 / 匹配 | `fushi_audio` 的 `AudioTextNormalizer`、`EpubCueMatcher` / `EpubSection` |
| 演出稿 / OCR 文本 | `MangaAudioScript.audibleLines`、`resolveMangaLineText`、`mangaPayloadOcrSignature`、`MangaAudiobookSourceService.loadPayload/loadScript` |
| 剪段 | `manga_audio_render_backend.dart` 的 `runMangaFfmpeg`（从合成后端抽出）、`buildMangaClipArgs`（`endMs` 改为可空） |
| 成品与登记 | `MangaRenderManifest`、`registerMangaAudio` |

不另写匹配器：引擎层只有「单元 → section」与「`CueMatch` → 页 / 块 / 段」两个纯函数。

## 匹配规则

- 单元归一化后不足 6 字（`kMangaDramaMinChars`）不进 section 正文；不足 6 字的转录 cue 即使匹配器给了位置也不高亮（与有声书音源同一条线）。
- 命中区间落在哪页的单元上最多取哪页；该页单元被覆盖 ≥1/3、或占区间一半才高亮。
- 页只往后走：命中页比当前页靠前的 cue 作废（计入「倒退作废」）。
- 未命中 / 太短 / 作废的 cue 仍是成品里的一段音频，块列表为空（只播放不高亮），挂在当前页。
- 音频铺满：每个文件第一段从 0 开始（片头音乐也播），cue 之间的音乐 / 效果音并进前一段，最后一段到文件末尾。零时长段并进下一段。

## 存储

- 成品目录 `<db>/manga_drama/<sha1(bookKey)>/`：清单 + `drama_NNNNN.m4a`，与合成成品 `<db>/manga_audio/` 分开，两者互换登记不互相清文件；重做时清掉不再引用的旧段文件。
- 清单键 `cont: true`：时间表不插页停留、`lead` 与句间停顿（`MangaTimingParams.continuous`）；旧清单不带该键，行为不变。
- 行身份 `drama-<i>`，不是演出稿行，补回 / 换种子找不到它们，按「没有这句」处理。

## UI 入口

- 作品页「⋯」里「有声书音源」旁边新增「广播剧 / 动画音轨」（只给本地卷）。
- 有声书音源页底部加同名入口。
- 运行中的任务归进程级任务表 `manga_drama_track_tasks.dart`（一卷至多一个；离开制作页不停，只有点「取消」才停；结束弹全局提示），制作页只观察。
- 制作页 `manga_drama_track_page.dart`：说明、单元来源提示、文件列表（添加 / 上移 / 移除）、发起 / 取消、分阶段进度、匹配统计（转录句数、可高亮、太短、倒退作废、段数、本卷文字覆盖率）。列表错峰入场 + 按压缩放，时长取 `fushiMotionDuration`。

## 限制

- 只支持本地卷（在线作品没有统一页坐标）。
- 需要本机 ASR 模型与 ffmpeg；缺一个就报对应提示，不降级。
- 登记会替换这一卷当前的有声成品（合成成品文件不动，重新生成 / 导入即可换回）。
- 短句、高噪声文本、改编差异大的素材上的真实匹配率没测过；单测只用假转录 + 真匹配器的小样本。
- 不做说话人区分；高亮粒度是单元（演出稿行 / OCR 块），不到字。
