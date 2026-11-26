# 整库补字幕（缺目标语言字幕的集：内封 → 下载 → 原盘版本适配 → 生成）

- 状态：实现中（分支 `claude/fushi-subtitle-solution-624389`）
- 起因：用户 2026-11-26「把 fushi 里没对应语言字幕的都补上，该生成的生成、该下载的下载，特别是 BD 还没有好方案」。
- 用户拍板（同日）：
  1. 做进 app，再在本机库上实跑；
  2. 下载不到就**自动本地生成**，**不用 API key / 不跑 AI 校对**（额度不够）；需要校对时由 Claude 子代理在 app 外离线校；
  3. 顺序：**内封优先**；BD 多半是 TV 版改了改，大部分台词和 TV 版一样 → 拿 TV 版字幕套到 BD 上，比纯 ASR 质量高。

## 1. 现状与缺口（实测代码）

| 缺口 | 位置 |
|---|---|
| 没有任何「遍历视频库、判哪些集缺目标语言字幕」的入口；批量只有单合集面板 | `subtitle_collection_panel.dart` `_targets()` |
| 「已有字幕」只看有无，不看语言：目录里躺一份 `.zh.ass` 就判日语也有了 | `video_subtitle_backfill.dart` `_existingSidecars` / `subtitleSourceBlocksBackfill` |
| 原盘分集 `xxx.pNN.mpls` 是虚拟路径，`videoPathFileExists` 判假 → `failed: video file is gone` | `video_subtitle_backfill.dart` backfill 开头 |
| 原盘的指纹：`computeOpenSubtitlesMovieHash` 读的是 `.mpls` 字节，`fileSize` 是播放列表大小——两者对 OpenSubtitles 都是噪声 | `_request` |
| 集号只从文件名解析：`00001.p03` 解不出，多集原盘一律 `cannot tell which episode` | `libraryVideoSubtitleTarget` |
| 原盘 sidecar 写到 `BDMV/PLAYLIST/` 里（盘目录里塞字幕，且播放页 sidecar 发现不认这个目录） | `sidecarPathFor` |
| 下载对时只有「按内封文本轨对齐」；BD 只有 PGS，没有参照轨 → TV 版字幕原样落盘，版本差异（CM 黑场、加长镜头、OP/ED 不同）错位 | `embedded_reference_subtitle_sync.dart` |
| PGS OCR 只能播放时现跑当前轨 | `graphic_subtitle_track_ocr.dart` 唯一调用点在播放页 |

已有、可直接复用的能力：在线 provider 链（Jimaku / OpenSubtitles / SubDL / AJATT）+ 拒收校验；本地 ASR 生成管线（已支持 `.mpls` / DVD title 读媒体）；**ASR 参照重定时**（上游 `retimeSubtitles`：唯一单调文本锚点、分区时钟、推不出的段原样保留，正文不改）；PGS 抽轨 + OCR；刮削落库的逐文件集号绑定（`video_metadata_episodes.book_uid`）。

## 2. 方案

一个库级任务 `LibrarySubtitleFill`（引擎层编排，`packages/fushi_engine/lib/media/video/subtitle/library_subtitle_fill.dart`，无 Flutter 依赖，app 与 CLI 都能起），对每个视频条目按**目标语言**做一次判定，再走最便宜的可用路径：

```
判缺（按语言）──已满足──▶ skip
   │缺
   ├─ 内封文本轨是目标语言 ──▶ 选中该轨（登记 embedded:<n>），完事
   ├─ 内封图形轨（PGS/VobSub）是目标语言 ──▶ 离线 OCR 成 SRT 并登记
   ├─ 在线下载（身份取刮削结论）
   │     ├─ 有内封文本参照轨 → 既有「按内封轨对时」
   │     └─ 没有参照（原盘 / 无字幕 mkv）且下到了 → 本地 ASR 一遍 → 重定时（版本适配）
   │            命中率 ≥ 40% → 用重定时版；否则判「不是这个版本」→ 用 ASR 稿
   └─ 下不到 → 本地 ASR 生成（不校对）并登记
```

### 2.1 判缺（按语言）

`subtitleCoverageFor(book, target)`（纯判据 + 注入的 IO）：

1. `video_books.subtitle_source` 是 `off:` → 用户明确关了，**跳过不补**（尊重选择）。
2. `subtitle_source` 指向文件 → 语言 = 文件名语言标记（`sidecarSubtitleLanguageTag`）；没标就读正文判（`detectSubtitleContentLanguage`）。
3. 同目录 sidecar（含 app 托管目录里登记过的）逐个判语言，同上。
4. 内封轨（ffprobe）：文本轨语言对上 → `embeddedText(n)`；图形轨语言对上 → `embeddedGraphic(n)`。
5. 都不对 → `missing`。

目标语言：任务参数（默认取全局默认字幕语言链 `resolveSubtitleLanguageTarget`，用户在入口可改）。**不兜底成日语**。

### 2.2 原盘下载链路修复（`video_subtitle_backfill.dart` / `library_video_subtitle_backfill.dart`）

- 存在性改判 `hasLocalMediaFile`（原盘成员换成背后的 `.mpls` / 盘根判）。
- 集号：**先取刮削落库的逐文件绑定**（`getVideoFileEpisodeRows([bookUid])` 的季 / 集），没有再退回文件名解析。原盘的协调器集号覆盖本来就写在这张表里，所以 Disc 2 第 1 集是第 7 集，与库里展示一致。普通文件也受益（绝对集号 / 手动绑定）。
- 指纹：原盘成员不算 moviehash、不报 fileSize（只给 fileName 也无意义，整块 `fingerprint: null`）。
- 时长校验：原盘时长走 `probeVideoFacts`（ffprobe 经 Bluray 后端可读 mpls），失败退刮削时长，与普通文件同一条。
- 落盘位置：原盘成员 → app 托管字幕目录 `<videoSubtitlesDir>/<bookUid>/<语言>.<ext>`，并登记 `subtitle_source`；普通文件照旧落 sidecar。

### 2.3 原盘版本适配（TV 版字幕 → BD）

用户的观察是对的：BD 与 TV 版台词绝大部分相同，差别是剪辑（CM 断点、加长 / 修正镜头、OP/ED 版本）。整体平移修不了，**逐句重定时**修得了：

1. 下载拿到 TV 版字幕（已过语言 / 时长校验）；
2. 对 BD 跑一遍本地 ASR（同一套生成管线的识别阶段，不校对；转录稿缓存，后面若要回退 ASR 稿直接复用，不识别第二遍）；
3. `retimeSubtitles(TV 字幕, ASR 转录)`：锚点之间分区推时间，正文一个字不改；
4. 命中率 `≥ kRetimedSubtitleLowMatchRate (0.4)` → 落重定时版并登记；`< 0.4` → 判定「这份字幕不是这一集 / 这个版本」，改用 ASR 稿。
5. 报告里写命中率与中位修正量，供用户抽查。

> 后续（上游 `hajisensai/fushi-subtitles`，不在本仓改算法）：BD 新增台词（重定时后没有字幕覆盖、ASR 有语音的区间）用 ASR 句补洞；TV 独有台词（长段无锚点）剔除。登记为上游待办，见 §5。

### 2.4 离线 PGS OCR

把播放页的「边抽边识别」拆出离线入口：抽整轨（`readGraphicSubtitleTrackInBackground`，`sourceComplete = true`）→ `recognizeGraphicSubtitleCuesLive` 按时间顺序全识别（`positionMs` 恒 0）→ `buildGraphicSubtitleSrt` 落托管目录并登记。OCR 引擎不可用（模型没下）时该集退到下载 / 生成，不让整批失败。

### 2.5 生成

`AppVideoSubtitleService.resolveBook` + `start(..., proofread: false)`，一集一个 job、串行（ASR 吃满 GPU，并发没收益）；产物照旧经 `VideoBookSubtitleSink` 登记。

### 2.6 入口与可观测

- 视频库顶栏动作「补齐字幕」（平铺，放不下进 ⋯）→ 设置面板：目标语言、范围（整库 / 当前合集）、允许生成（默认开）、只预览（dry-run 列清单）。
- 任务面板：按作品分组列每集的判定与结果（已满足 / 内封 / OCR / 下载 / 下载+适配（命中率）/ 生成 / 失败原因），可取消；动效按 UI 硬规则。
- ctl 路由 `POST /api/admin/video/subtitle-fill`（+ `op_descriptions_video.dart` 描述），CLI `fushi_cli video sub-fill [--language ja] [--collection <id>] [--dry-run] [--no-generate]`。写操作可撤销：任务报告记下每个新写的文件与登记前的 `subtitle_source`，`--undo <jobId>` 还原。

## 3. 不做 / 边界

- 不调用 AI provider（无 key 也要能跑完）。
- 不覆盖已有目标语言字幕；不碰 `off:`。
- 不翻译（AI 翻译字幕在功能黑名单）。
- iOS 合规：在线字幕源在 iOS 上已有既有判据，编排层只消费 registry，不另判平台。

## 4. 测试

- 判缺：sidecar 语言标记 / 正文嗅探 / 内封文本 / 内封图形 / `off:` / 登记文件语言不对，纯函数表驱动。
- 原盘目标：虚拟分集路径的存在性、集号取绑定表、指纹为空、托管目录落盘 + 登记。
- 编排：假端口跑完整决策树（下载命中 → 适配高命中 / 低命中回退 ASR；下载不到 → 生成；OCR 不可用 → 下一档；取消）。
- 适配：用真实 SRT 对构造「插 CM 段」的转录，验证命中率与逐句修正（算法本身由上游测，本仓测装配）。

## 5. 待办登记

- 上游：BD 版本合并（补 BD 新增句、剔 TV 独有句）。
