# 视频字幕生成：普通话音频（2026-11-04）

接 [2026-11-04-video-subtitle-multisource-evidence.md](2026-11-04-video-subtitle-multisource-evidence.md)。

## 问题

AI 字幕管线（识别 → S0 专名表 → S3 校对 → S4 写法统一 → 歌曲判定 → S4s 歌词 → 拆分 → 导出）只认日语：
识别器写死 `AsrLanguage.japanese`、音轨只挑 `jpn`/`ja`、导出 `.ja.srt`、全部提示词是「日本アニメ」口径、
任务目录与专名表键只按视频 / 作品分。中文剧 / 电影 / 国漫、以及普通话配音的日本动画都用不了。

上游 `fushi-subtitles`（锁定 `8ecd2061`）已有 `AsrLanguage.mandarin` 与 `kAsrMandarinPack`（X-ASR zipformer
中英带标点），MOSS 分段器本身中文原生，不需要改上游算法。本仓只改装配与 UI。

## 方案

一个枚举 `VideoSubtitleLanguage { japanese('ja'), mandarin('zh') }`
（`packages/fushi_engine/lib/media/video/subtitle/asr_proofread/subtitle_language.dart`）贯穿全管线，缺省日语：

| 方面 | 日语（原有，逐字不变） | 普通话 |
|---|---|---|
| ASR 语言 / 模型包 | `japanese` | `mandarin`（模型按语言各自下载） |
| 挑音轨 | 第一条 `jpn`/`ja`，否则第一条 | 第一条 `zho`/`chi`/`cmn`/`zh`/`zh-*`，否则第一条 |
| 导出后缀 | `.ja.srt` | `.zh.srt`（`--suffix` 仍可覆盖） |
| 任务目录 | `videoSubtitleJobId(video)` | 同上 + `.zh` |
| 专名表键 | `workKey` | `workKey:zh` |
| 作品名 | 日文原名 → AniDB 汉字标题 → 显示标题 | 原名是中文（有汉字、无假名）用原名，否则显示标题 |
| 提示词 | 现有日语常量 | `subtitle_prompts_zh.dart` 同结构中文版（占位符 / 分隔标记相同） |
| 歌词搜索后缀 | `歌詞` | `歌词` |
| S4 可疑写法 | 片假名名字编辑距离 1 | 3 字以上汉字名同长差一字 |

中文提示词要点：输出说出来的普通话；保留语气词（嗯 / 啊 / 那个）、方言与重复；不做简繁转换，
繁体同语言字幕只作证据；他语言字幕（如配音动画的日语字幕）只作提示、不照抄。专名表 `reading`
列留空——不做拼音（功能黑名单：不做机器推断注音）。

### 选语言

- 面板（`video_subtitle_generate_sheet.dart`）新增「音频语言」分段（`adaptiveSegmentedButton`，日语 / 中文）。
  初值按第一集音轨标签猜（`guessVideoSubtitleLanguage`）：有中文标签且没有日语标签 → 中文，其余 → 日语；
  用户可改。改语言会重查模型是否就绪、已有字幕（`.<tag>.srt`）与费用估算。
- 操作目录 `video.subtitle.generate`、远程宿主任务参数、`fushi_cli`、`fushi_server subgen` 都接受
  `language: ja|zh`（缺省 ja），不认识的值 = 400 / 用法错误。

## 已知限制

- 歌词校验按文字比对：页面是繁体、识别稿是简体时可能被拒（只是少补歌词，不会写错）。
- 远程宿主面板、专名表 ctl 路由仍只走日语。
- 声优表（作品资料里的配音演员）仍只取 `ja`。
- 新 i18n key 除 en / zh-CN 外其余语言先用英文。

## 测试

- `fushi/test/media/video/subtitle/asr_proofread/subtitle_language_test.dart`：语言映射、任务目录 / 专名表键
  （日语不变）、作品名、挑音轨与猜测、各阶段提示词按语言选、歌词搜索词、汉字近形名、任务参数解析。
- `video_subtitle_generate_sheet_test.dart`：只有中文音轨默认中文、可改回日语；日中双音轨默认日语。
- `packages/fushi_server/test/subgen_commands_test.dart`：`--language` 解析与 `.zh.srt` 输出。
- 待真机：中文剧集（中文音轨）与日中双音轨动画各跑一遍完整管线（含 AI 阶段）。
