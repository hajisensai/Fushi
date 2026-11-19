# 漫画有声模式：接手说明（2026-11-17）

给接着做这件事的 agent。设计本身看 [2026-11-17-manga-audio-mode-design.md](2026-11-17-manga-audio-mode-design.md)，这里只写「现在到哪了、下一步做什么、哪些坑已经踩过」。做完一步就更新本文件对应小节，全部做完后删掉本文件。

## 一句话现状

设计已定稿；引擎层（spec 实施顺序第 1 步）已实现并开 PR；应用外用真实模型跑通了第 1 卷片段和第 2 卷整卷。**app 里现在还不能播**，第 2～7 步都没开始。

## PR 与分支

| 内容 | PR | 分支 / 提交 | 状态 |
|---|---|---|---|
| 设计 spec + 本文件 | [#3640](https://github.com/hajisensai/Fushi/pull/3640) | `claude/relaxed-wilson-01b4f9` | 未合并，CI 没看过 |
| 引擎层（第 1 步） | [#3656](https://github.com/hajisensai/Fushi/pull/3656) | `feat/manga-audio-script-engine`，`bd5ae5dd0c`，基于 develop `f25fcb3819` | 未合并。3 个测试文件复跑过：退出码 0、执行 47 个；全量 analyze 无问题（实现代理报告）。PR CI 没看到结果 |

两个 PR 都**不要自己合并**，用户当轮说「合并」才合。引擎层的 worktree 在 `.claude/worktrees/manga-audio-engine`，claim 在主 checkout 的 `.worktrees/coordination/claims/1117-manga-audio-script-engine.json`（状态 pr-open）。

## 引擎层已有什么（#3656）

都在 `packages/fushi_engine/lib/tts/manga_audio/`，纯 Dart，`tts_cast.dart` 一行没动：

- `manga_audio_script.dart`：演出稿模型 `MangaAudioScript`、JSON 往返、原子写存储（`<sha1>.manga-script.json`）、OCR 签名过期判定、声音逐级回落解析（作品默认 → 角色 → 角色 × 类型）。
- `manga_audio_validate.dart`：本地校验（丢弃的行连同原因返回，不抛异常）、按块下标从 OCR 拼台词文本。
- `manga_audio_timeline.dart`：按页时间表，默认值都在 `MangaTimingParams`。
- 测试在 `packages/fushi_engine/test/tts/manga_audio/`。

实现时定下、spec 没写的几点：

- 没有扩 `TtsCast`，而是新建并列类型（理由已写回 spec §1）。角色表、来源、旁白 / 不明复用 `TtsCast` 的定义。
- 最后一句之后的停顿 = 600 ms + 该句的一拍。
- 情绪词表 10 个、数值范围在 `MangaScriptLimits`，都是初稿，可以改。
- 时间表输入页码乱序或混进「不读」的行会抛 `ArgumentError`（算调用方的错）。

## 下一步：按 spec「实施顺序」往下做

1. ~~引擎层~~（#3656）
2. **漫画播放**：阅读器接演出稿。复用 `MangaReadAloudHost`（取页文字、高亮句组、翻页、喂学习时钟）和 `MangaReadAloudBar`；音频与 cue 走 `Audiobooks` / `AudioCues`，播放走 `AudiobookSession`；高亮要支持一句对应多个块；无台词页也有页段。新 UI 按仓库 `CLAUDE.md` 的 UI 硬规则带动效，快捷键只做键盘。
3. 已有有声书当音源（文本对文本匹配 `AudioCue.text`，6 字以下的短句不匹配）。
4. 声音指派表 + 声音包 / 批量 worker。
5. AI 看图标注（角色表 → 逐页 → 场景复核），本地校验用引擎层那套。
6. AI 操作目录路由（`ctl_tts_routes.dart` 必须同时写 `op_descriptions_tts.dart`）、小说、制卡。
7. 广播剧 / 动画音轨。

第 2 步依赖 #3656。#3656 没合并前，从它的分支开新 worktree 往上叠，不要把引擎层代码复制一份。

## 应用外流水线（不入库）

第 2 卷整卷的全部脚本和产物在 `D:\APP\irodori\eval\manga_vol2\`，第 1 卷片段在 `D:\APP\irodori\eval\manga_trial\`。这是验证设计用的参考实现，产出的演出稿字段与 spec 一致，将来 app 内的实现应当能读同样的结构。

环境：

- 合成：`D:/APP/irodori/repo/.venv/Scripts/python.exe -X utf8`（底模 `D:/APP/irodori/models/v4-large/model.safetensors`，LoRA `D:/APP/irodori/release/shukura/lora`，参考音频 `release/shukura/refs/<miyagi|sendai>`）。
- 评分 / 拼接：`D:/APP/irodori/prep/.venv/Scripts/python.exe -X utf8`；ffmpeg 在 `D:/APP/ffmpeg/bin/ffmpeg.exe`（没有 ffprobe）。
- 显存只够一个模型实例，合成不能并行跑两份。
- 书库在 `D:/APP/HIBIKI_date/documents/fushi_books/`，**只读**；第 2 卷目录名含 `e0914585`，第 1 卷含 `31aa2836`。

脚本（都在 `manga_vol2\`，按顺序）：

| 脚本 | 作用 |
|---|---|
| `dump_blocks.py` | 把 OCR 块按 17 页一段导出给标注者，写 `chunks.json` |
| `anchors.py` | 底模无参考生成 12 条「锚点声音」（`anchors/a10..a21.wav`，带基频） |
| `merge.py` | 合并 `chunks/pages_*.json` 和 `chunks/restore.json`，逐句校验，写 `script.json` + `merge_report.json` |
| `restore_more.py` | 对第二轮仍留空的页按句补标（幂等，改写 `chunks/restore.json`） |
| `generate.py [seed]` | 整卷合成，可断点续跑，输出 `cand/<稳定名>_s<seed>.wav` |
| `score.py` | anime-whisper 回听算字错率，写 `picks.json` |
| `double_stats.py` / `bad_stats.py` / `other_stats.py` / `lens.py` | 只打印统计数字的检查脚本 |
| `assemble.py` | 按页段拼接，写 `scene.wav/mp3`、`cues.json`、`segments.json`、`viewer.html` |

重跑整卷：`merge.py` → `generate.py 0` → `score.py` → `assemble.py`。改了演出稿只需重跑这四步，已有音频不会重录。

第 2 卷当前产物：446 句（切句后 467 条音频），0 条合成失败，成品 30 分 38 秒，150 页里 108 页有台词、42 页是无台词页段。`scene.mp3` 160k 约 35 MiB，`scene_96k.mp3` 是发给用户的 21 MiB 版本。

## 已经踩过的坑

- **OCR 块顺序不是阅读顺序**，必须由标注者看图重排。
- **音频文件名用「页码 + 块下标 + 片段序号」**（`common.Line.id`），不要用行序号：演出稿增删句子后序号会整体错位。
- **模型单条上限 30 秒**：卷末小说那种整段文字在 `common.split_long` 里按句末切成 ≤70 字。
- **不挂 LoRA 的声音在短句上会把这句念两遍**（首轮 49 条里 19 条，挂 LoRA 的 0 条）。原因是时长预测对短文本偏长。修法在 `generate.manual_seconds`：20 字以内的非 LoRA 句子按 `0.55 + 0.15 × 字数` 秒直接给定时长。app 内的批量 worker 需要同样的处理。
- **ASR 回听对 5 字以内的句子不可靠**（会虚报重复），只用来查长句。
- **多种子挑选收益很小**，固定种子 + 单句重生成即可（用户已同意，不让用户逐句选）。
- 子代理标注时会比交代的更保守地整页略过；要求里写明「按句判断、不按页判断」，并核对它交回的略过清单。
- 往终端打印日文会撞 GBK 编码错误，脚本一律写成文件用 `-X utf8` 跑；统计脚本只打印数字和块号。
- 本机内存紧张时首次加载模型可能 `MemoryError`，重跑即可。

## 用户已经拍板的

- 目标是**离线整体效果最好**；实时朗读是另一种模式，不在这里做。
- 气泡之间要有停顿（切换基础值 + 每句一拍）；一页只有一句或没有台词也不能被跳过（按页分段，有最短停留）。
- 种子固定一个，不让用户生成时逐句选。
- 有真的有声书时优先用有声书的音频。
- 生成时可以指定模型 / 声音；正经文字或大段正文可以用另一个声音。
- 气声组 / 干净组参考音频差别不大，先不区分。
- 被略过的页要按句补回来（已补）。

## 没验证的、留给接手者或用户的

- 配角音色是按基频挑的锚点（舞香 a17、亜美 a11，映射在 `voices_other.json`），没人听过。
- 第 2 卷有 20 句标注者标了「说话人不确定」（`script.json` 里 `sure:false`）。
- 4 条极短句回听长度偏长，判断是 ASR 误差，没有人耳确认。
- 无台词页要不要垫环境音、漫画台词对小说有声书的命中率，都没试。
- 两个 PR 的 CI 结果都没看到。

## 内容边界

两位主角是高中生。做第 2 卷时，凡是句子本身在下达或承受舔、咬、留吻痕这类身体行为的（指令、进行中的反应），没有做成有声；同一场里的普通对话、争执、心声照常配。具体留空的页和块记在 `merge_report.json` 的 `omitted_pages` 与 `chunks/restore.json` 的 `still_omitted` 里。接手者按句判断即可，不要再整页略过。

另外，对话里不贴漫画台词原文，演出稿只存「页码 + 块下标」，台词文本运行时从用户自己的 OCR 里取。
