# 视频日语字幕：多模型 ASR + LLM 校对管线接入方案

- 日期：2026-10-19
- 状态：方案（待审）
- 范围：视频（动画为主）的日语字幕自动生成；有声书路径不变
- 实验依据：本机离线基准 `C:\asr_bench`（脚本 `scripts/`，结论记录在 agent 记忆 `reference_ja_video_asr_benchmark_2026_10`），以及 2026-10-18～19 用同一套流程给《sin 七つの大罪》整部作品生成字幕的实跑

## 1. 背景：实测收益来自哪里

同一批 12 集带人工日文字幕的素材（K-ON 5 集 + 高木さん / 魔女の旅々 / 転生王女 / おにまい / メイドラゴン / SPY×FAMILY / 薬屋 各 1 集），按字数加权的读音 CER（fugashi 读音，参考字幕里的 OP/ED 与 >45 s 空档不计分），人名命中按 K-ON 的 317 处人名统计：

| 阶段 | 读音 CER | 人名命中 | 对应 Fushi 现状 |
|---|---|---|---|
| Kitsune 0.3B 滑窗（≈ app 现状量级） | 13.55% | 78/317 | 现有 `mixedAudio` 路径是 Parakeet + 15 s/3 s 滑窗，同量级（K-ON 上 14.4） |
| MOSS 分段 + Parakeet 单稿 | 10.60% | 94 | 无 |
| MOSS / Parakeet / Whisper-760M 三稿 medoid 融合 | 10.05% | 99 | 无 |
| + LLM 校对（三稿作候选 + 作品级专名表） | 8.84% | 277 | 无 |
| + 整作写法统一收尾 | 8.82% | 287 | 无 |

结论（排优先级用）：

1. **人名 / 作品用语几乎全靠「专名表 + LLM 校对」**（99 → 287/317）。这一步与 ASR 引擎无关，可以接在现有 Parakeet 滑窗输出后面，全平台可用。
2. **CER 最大的一块来自分段**：把滑窗换成 MOSS-Transcribe-Diarize 的分段（13.55 → 10.60）。MOSS 目前只有 audio.cpp 的 CUDA 构建，只能在带 NVIDIA 显卡的桌面 / 服务端跑。
3. 第三稿（faster-whisper-ja-760M）只再贡献约 0.5 个点，且依赖 CTranslate2（Python），接入成本最高，放最后、先调研。
4. 已实测**无收益**、本方案不做的：每集联网研究（CER 8.84 → 8.88，人名 277 → 275，属运行间波动）、LLM 二次整集复查、MOSS 热词提示、demucs 人声分离、多模态重听分歧句（详见记忆条目第三轮）。

## 2. 目标与非目标

目标：

- 视频页 / 合集页可以对一集或一整季生成日语字幕，产物是同名 `.ja.srt` 外挂字幕，播放页现有 sidecar 探测（`findSidecarSubtitle`）直接加载。
- 校对用用户自己配置的 AI 提供商（复用 `AiChatClient`），作品身份与正式角色名优先取自刮削数据。
- 长任务可暂停、可续跑；AI 额度用尽时显式报错停下，续跑从缓存继续。

非目标：

- 不做歌词全文校正（需抓取有版权的歌词全文）；唱段只加 `♪` 标记。
- 不发送音频或画面给 AI，只发 ASR 文本。
- 不改有声书的 ReazonSpeech `cleanSpeech` 路径。
- iOS 不新增受限能力（本功能不涉及 `StoreRestrictedCapability` 三类）。

## 3. 总体流程

```
视频 ──ffmpeg──▶ 16 kHz 日语音轨
   │
   ├─ S1 分段 ──────── MOSS（CUDA 桌面/服务端） | 现有滑窗（其余平台）
   ├─ S2 识别稿 ────── Parakeet 按分段识别（+ MOSS 自带正文作第二稿；第三稿待 P4）
   ├─ S0 专名表 ────── 刮削身份/角色名 → web_knowledge 抓百科 → AI 整理 → 校验（每作品一次）
   ├─ S3 LLM 校对 ──── 每批 30 句、前后 3 句上下文、多稿候选、专名表；只改正文不改时间
   ├─ S4 写法统一 ──── 按读音/1 字差/已知误写抽可疑行 → AI 逐行判定（含唱段 ♪ 标记）
   └─ S5 显示后处理 ── 多句长条按句末拆分，切点取 token 时间；短片段整段判定是否纯歌曲
         ▼
   <视频名>.ja.srt（+ transcript.tokens.jsonl）
```

### S0 作品身份与专名表（每作品一次，可编辑）

在 asr_bench 里踩过的两个坑决定了这一步的设计：

- 只给标题时，AI 把「sin 七つの大罪」查成了铃木央的《七つの大罪》（同名作品）。
- 把 ASR 原文当参考喂给 AI 时，它会把误识写法当正式写法，还会自相矛盾（「レヴィ」「レビィ」互列为对方的误写）。

数据源优先级：

1. **刮削数据（权威，免查）**：作品日文原名（`video_metadata_works.originalTitle`）、AniDB `kanjiTitle`（`anidb_file_identities`）、角色与声优（`VideoMetadataCreditRepository.forCollection` / `forBook`）。
   - 现状缺口：角色日文原名在入库时被丢掉。模型 `VideoMetadataCharacter.originalName` 存在，但 `video_metadata_characters` 表没有这一列，`video_metadata_database_store.dart` 只写 `name`；MAL provider 也没读 Jikan 的 `name_kanji`。
   - 改法：schema 加一列 `original_name`；MAL provider 读 `name_kanji` 写入。只在 AniDB / MAL / TMDB 白名单内取数（`docs/agent/anime-scraping.md`），不引入 AniList。
2. **百科页面**：用 `packages/fushi_engine/lib/ai/web_knowledge.dart` 按日文原名抓 MediaWiki（ja.wikipedia）/ ANN 页面正文。不依赖提供商的联网工具，所以任何 AI 提供商都能用。
3. **AI 整理**：把 1+2 交给 `AiChatClient`，输出 `[{ja, reading, kind, misrecognitions}]`。提示词要求写法只取自资料，不取自 ASR。

生成后做两道程序校验，不过就带反馈重做，仍不过则停下让用户处理：

- **身份校验**：表中人名有多少真的出现在本季 ASR 文本里（按正式写法、读音或已知误写匹配）。实测查错作品的表是 2/40，对的表是 14/21，阈值取 35%。
- **矛盾校验**：某条的正式写法出现在另一条的误写列表里，或带「要確認」之类注记。

刮削数据缺失时（未刮削、远程媒体服务器条目），退回到「标题 + ASR 抽样仅用于确认作品身份」的做法，并在 UI 上提示建议先刮削。

存储：新表 `video_subtitle_glossaries`（以合集 / 作品为键，存 JSON、来源指纹、`userEditedAt`）。用户可在 UI 增删条目，对应交接包里的「用户名单」。用户编辑过的条目在重新生成时保留。

### S1 分段

- **MOSS 后端（Windows / Linux + NVIDIA）**：audio.cpp CLI 跑 MOSS-Transcribe-Diarize Q8_0 GGUF。按约 5 分钟在最安静的 400 ms 处切块；某块撞到输出 token 上限就在块内最安静处二分后重跑。输出带说话人标签的句级时间轴。
  - 接入方式参照上游 `AppleTranscribeRunner`（非 ONNX 后端的先例）。
  - 进程统一经 `HelperProcessRegistry` 启动、登记、退出清理，与 ffmpeg 同一套。
  - 可执行文件与模型按清单固定版本和哈希下载，复用 `AsrModelStore` 的下载与缓存。
  - 驱动要求与现有 CUDA 13 判据一致（`gpu_acceleration.dart`：R580+、sm_75+）。
- **其余平台**：保留现有 `AsrSlidingWindowSegmenter`（15 s / 3 s）。也可以把任务转给已配对的电脑（现有 `VideoRemoteJobKind.transcribe` 通道）。

### S2 识别稿

- 上游新增「按给定分段识别」的 API：输入音频 + 分段列表，输出每段文本和 token 时间。Parakeet（现有 nemoCtc ONNX）在 MOSS 分段上逐段识别。
- MOSS 的正文作为第二稿，不额外计算。
- 双稿时 medoid 融合没有意义（两稿距离对称），所以不融合：以 Parakeet 为主稿，MOSS 稿作为候选交给 S3。**双稿 + LLM 的效果尚未实测**，是 P2 的验收项。

### S3 LLM 校对

沿用基准里的规则（`C:\asr_bench\scripts\llm_fix.py`），移植到 `fushi_engine`：

- 每批 30 句，附前后各 3 句只读上下文；每句给主稿、候选稿和专名表。
- 规则要点：只修误识；保留口癖、方言、重复；不确定就保持主稿；人名统一到专名表写法；不得推测性地替换成专名；音乐、杂音幻听可清空。
- 输出 `{id: 修正文}`。**回复必须覆盖本批全部 id 才写缓存**，缺 id 或解析失败就重试，最终失败就报错。
  - 基准里踩过的坑：额度耗尽时 CLI 返回的报错被当成「没有修改」写进缓存，30 段静默通过。
- 时间轴永远沿用 S1，LLM 只改文字。
- 新增 `AiFeature.subtitleProofread`，用户在 AI 设置里为它单独指定提供商。并发度和每分钟请求数沿用 `AiProviderConfig.requestsPerMinute` 与 key 轮换。

### S4 整作写法统一

对应基准里的 `consistency.py`：

1. 先从行里抹掉所有正式写法，再找残留的可疑写法，防止子串误报（「ルシファ」⊂「ルシファー」）。可疑写法包括：与专名表读音相同但写法不同的词、和片假名名字只差 1 个字的词、专名表里已知的误写。
2. 用启发式找出疑似唱段：连续 ≥6 条短行、同一说话人、间隔 <0.8 s。
3. 只把被标出的行连同前后 2 行交给 AI 判断：属于表中人物就统一写法；是唱段就加 `♪`；其余保持不变。

实测（K-ON 等 12 集）：人名 277 → 287/317，CER 不变。

### S5 显示后处理

- 超过 7 s 或 40 字、且含多句的条目，在句末（。！？…）拆开。切点取下一句第一个 token 的开始时间减 0.1 s；没有句末但仍过长的，在最长的词间停顿（≥0.35 s）处切。
  - 实测（12 集、约 250 个切点）：切点与人工字幕边界的中位误差从「按字数比例」的 0.37 s 降到 0.30 s；超过 7 s 的条目从 60 条降到 32 条。
  - 基准用的是 760M 的词级时间戳。Fushi 里改用 Parakeet 已经产出的 `transcript.tokens.jsonl`，**需要重测**。
- 不按词时间裁掉条目首尾的静音：实测时间轴 IoU 从 0.773 降到 0.755。
- 短视频（<5 分钟）整段交给 AI 判断是 `song` / `dialogue` / `mixed`，`song`（NC OP/ED、MV）不导出。只用按行规则抓不住片头曲，因为英日混唱，行长不规则。
- 标点统一为全角（！？）。

### 产物与加载

- 写 `<视频名>.ja.srt`（UTF-8）与 tokens sidecar；已存在就不覆盖，改写 `<视频名>.ja.asr.srt`，并通过 `video_books.subtitleSource` 登记。
- 任务目录沿用 `<数据根>/asr_jobs/<hash>/`，新增各阶段产物：`segments.moss.json`、`drafts.json`、`proofread/<batch>.json`、`consistency.json`、`final.json`，用于续跑与排查。

## 4. 平台矩阵

| 运行位置 | S1 分段 | S2 识别 | S0/S3/S4 AI | 说明 |
|---|---|---|---|---|
| Windows + NVIDIA（达 CUDA 13 门槛） | MOSS | Parakeet（CUDA）+ MOSS 稿 | ✓ | 完整管线 |
| Linux 服务端 + NVIDIA | MOSS | Parakeet（FFI ORT）+ MOSS 稿 | ✓ | `fushi_server` 任务 |
| 其他桌面（无 N 卡、macOS） | 滑窗 | Parakeet（DirectML/CPU） | ✓ | 也可转给配对主机 |
| Android / iOS | 滑窗或转给配对主机 | 同左 | ✓ | 本地 CPU 慢，默认建议转给主机 |

附带修复：`packages/fushi_server/lib/src/host_bindings.dart` 的 `createServerAsrTranscriptionService` 把 `audioProfile` 写死为 `cleanSpeech`，导致服务端的视频转写永远走不到 Parakeet。改成由任务参数传入，视频默认 `mixedAudio`。

## 5. 任务模型

- **单集**：扩展现有 `AsrHostJobRunner`（kind `asr`）的参数，或新增 kind `video_subtitle`。阶段进度上报 S1 → S5，取消走 `HostJobCancelToken`。
  - 恢复：各阶段产物落盘即视为完成；LLM 批结果逐批缓存。现在服务端 ASR 任务结束时会 `discard`、没有断点续跑，这一点要改。
- **整季**：从合集取全部成员（`libraryVideoSubtitleTarget` 的作品解析逻辑），专名表每作品生成一次，各集依次排队。只缺失的集才处理，已有 `.ja.srt` 的跳过。
- **额度 / 网络错误**：任务进入「暂停：AI 请求失败（原因）」，保留缓存，用户在额度恢复后点继续。

## 6. 改动清单

### 上游 hajisensai/fushi-subtitles（算法；七处 git 依赖须一起重钉 sha）

- `asr_core`：「按给定分段识别」API（输出每段文本 + token 时间）；分段器抽象，新增 MOSS 外部 CLI 实现（注入进程启动器，不在上游直接依赖 Fushi 的 `HelperProcessRegistry`）；MOSS GGUF 与 audio.cpp 运行库写进模型清单（固定版本 + 哈希）。
- `asr_subtitles`：多句长条拆分（token 时间对齐 + 停顿兜底），连同第 3 节 S5 的参数与测试。

### `packages/fushi_core`

- schema v118 → v119：`video_metadata_characters` 增加 `original_name`；新表 `video_subtitle_glossaries`。按现有迁移阶梯与 schema 守卫一起改。

### `packages/fushi_engine`（纯 Dart，遵守 engine 纯度守卫）

- 新目录 `lib/media/video/subtitle/asr_proofread/`：
  - `subtitle_glossary_builder.dart`（S0，含身份 / 矛盾校验）
  - `subtitle_proofreader.dart`（S3，批处理、全 id 覆盖校验、批缓存）
  - `subtitle_consistency_pass.dart`（S4）
  - `subtitle_clip_classifier.dart`（S5 的纯歌曲判定）
  - `video_subtitle_pipeline.dart`（编排 S0 → S5、阶段缓存与续跑）
- `ai/ai_feature.dart`：新增 `subtitleProofread`。
- `asr/asr_host_job_runner.dart`：接入新管线与阶段进度。
- 刮削：MAL provider 读 `name_kanji`，store 写 `original_name`。

### `fushi/`（app）

- 装配：`asr_host.dart` 注入 MOSS 后端（只在 Windows + CUDA 可用时）。
- 视频页：现有「语音转写生成字幕」面板增加「AI 校对」开关、提供商选择、费用预估（按字数估 token）、专名表入口。
- 合集页：新增「整季生成日语字幕」，显示每集进度与跳过原因。
- 专名表编辑页：列表增删改（正式写法 / 读音 / 说明）。
  - UI 按仓库规则：带动效（`FushiEntranceScope` 等）、MD3 与 Apple 两套设计系统、顶栏动作走 `adaptiveOverflow`、分段选择用 `adaptiveSegmentedButton`。
- i18n 新 key 一律用 `fushi/tool/i18n_sync.dart --add` 添加。

### `packages/fushi_server`

- `audioProfile` 参数化（见第 4 节）；新任务参数（AI 校对开关、专名表）；WebUI 显示阶段进度。

## 7. 隐私与费用

- 只有 ASR 文本和专名表会发给用户选定的 AI 提供商。功能默认关闭，首次开启时说明会发送什么。支持本地 Ollama / LM Studio 预设。
- 密钥沿用现有 `ai_providers` 偏好，不同步、不导出（`pref_redaction_policy.dart` 的凭据红线）。
- 用量参考（实测，Claude Sonnet，《sin 七つの大罪》31 段约 5.5 小时）：校对约 148 万缓存写入 + 48 万缓存读取 + 12.6 万输出 token；专名表每作品约 $0.1–0.15。交接包用 DeepSeek 的自测为每分钟视频约 ¥0.01–0.02（估价，未对账）。
- **非 Claude 提供商的校对效果未实测**。P1 验收要至少在 DeepSeek 与一个本地模型上重测（本地模型可能达不到上表收益，UI 上不承诺效果）。

## 8. 分期与验收

基准集固定为第 1 节的 12 集；`C:\asr_bench` 的打分脚本作为离线验收工具（结果附在 PR 里）。

| 期 | 内容 | 平台 | 验收 |
|---|---|---|---|
| P0 | 服务端 `audioProfile` 参数化 | 服务端 | 视频任务走到 Parakeet |
| P1 | S0 专名表（含刮削角色日文名）+ S3 校对 + S4 写法统一 + S5 拆分，接在现有滑窗输出后 | 全平台 | 12 集人名命中 ≥ 2.5× 现状；读音 CER 不劣化；额度中断后可续跑 |
| P2 | MOSS 分段 + Parakeet 按分段识别 + MOSS 稿作候选 | Win/Linux + NVIDIA | 校对前读音 CER ≤ 10.6%；校对后 ≤ 9.0%、人名 ≥ 280/317 |
| P3 | 整季批处理、纯歌曲判定、合集页 UI | 全平台 | 一部完整作品端到端（含 OP/ED 跳过、已有字幕不覆盖）；真实视频页加载验证 |
| P4 | 第三稿调研（760M 转 whisper.cpp GGUF / ONNX，或其他可在 Dart 侧跑的模型） | 桌面 | 三稿融合对比双稿的收益 ≥ 0.4 个点才落地 |

按仓库规则：涉及播放 / 字幕加载的改动，声明修好前要在真实设备上复测原始路径并留证据。

## 9. 风险与待定

- **许可证**：MOSS-Transcribe-Diarize 权重、audio.cpp、Parakeet ja、faster-whisper-ja-760M 的许可证与再分发条件，接入前逐一确认。分发方式按「首次使用时下载」设计，不随安装包附带。
- **CUDA 依赖**：audio.cpp 目前只用了 CUDA 13 构建；DirectML / Vulkan 版本是否可用未调研，决定了 MOSS 能否覆盖 AMD / Intel 显卡。
- **角色名质量**：AniDB 角色名多为罗马音；MAL `name_kanji` 的覆盖率未统计。缺失时由百科页补，仍不足就靠用户编辑专名表。
- **写法拿不准的情况**：例如《sin 七つの大罪》的爱称「レヴィー / レヴィ」，资料互相矛盾（插入歌名写「レヴィのレシピ」，台词发音是长音），程序无法判定。UI 要让用户一键改正后整作重跑 S4（只花 S4 的费用）。
- **长期成本**：校对费用随提供商价格变化，任务开始前显示预估，结束后显示实际 usage。usage 缺失不能记为 0。
