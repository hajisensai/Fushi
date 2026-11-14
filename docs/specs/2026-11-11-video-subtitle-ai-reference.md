# 视频字幕生成：把参考画面与用户选的参考字幕交给 AI（2026-11-11）

接 [2026-10-19-video-asr-llm-subtitle-pipeline.md](2026-10-19-video-asr-llm-subtitle-pipeline.md)、
[2026-11-04-video-subtitle-multisource-evidence.md](2026-11-04-video-subtitle-multisource-evidence.md)。

## 问题

字幕工作台（视频页「字幕」› 工作台）的「参考」区显示当前画面时刻和另一条字幕在播放点附近的行，
只给人看。所有者要求：参考资料要真正交给 AI。

查下来的现状：

- **其它语言字幕**：生成管线的 S3 校对早就在用视频旁边 / 内嵌 / 已登记的其它语言字幕
  （`他言語字幕(<lang>): …`）。缺的是「用户自己在播放器里挑的那一条」——从别处加载、或手动调过
  时间轴的字幕，管线不知道，仍按自己找到的来。
- **画面**：从来没发给过 AI。10-19 的 spec 把「不发送音频或画面」列为非目标，同意弹窗在 17 个语言里
  写着「不发送画面」。

## 方案

### 1. 参考画面（改掉 10-19 的非目标，仅画面，音频仍不发）

- AI 校对每批附上这一批对应时刻的静态画面，图片与校对请求同一条消息发出（`AiChatImage`，
  三家协议都已支持）。
- 取哪些时刻：`planReferenceFrameTimes`（纯函数）。每句取中点；空行不取；与上一张相隔不足
  `kSubtitleReferenceFrameMinGapMs`（4 s）的跳过；超过 `kSubtitleReferenceFramesPerBatch`（10 张）
  时按序号均匀抽稀并保留首尾。
- 怎么取：`ffmpegSubtitleFrameSource` 用现有的 `extractVideoFrameViaFfmpeg` 截一帧，缩到
  `kSubtitleReferenceFrameWidth`（768 宽）JPEG。只对本机视频文件取；网络路径、定位落在片尾之后
  都取不到，那一张就跳过，这一批照常校对（不报错、不重试）。
- 提示词：稳定前缀末尾加「補足規則(画面)」三条（画面里的文字 / 人物 / 场景只作判断人名、用语、
  同音异义的线索；不把画面文字当台词补进来；烧录字幕按同语言参考 / 翻译对待），普通话有对应译文。
  批正文末尾列出 `画像N [mm:ss.ss]`，与附图同序。**没开画面参考时提示词与改版前逐字相同**
  （提示缓存与已有批缓存都不受影响）。
- 一批的画面只取一次：补问没答到的行时沿用同一组。
- 缓存：`state.json` / `final.json` 记 `frames`。只在这次开着 AI 时比较，开关一变就从 S3 重跑；
  关着 AI 跑一遍不清已付费的批缓存。「只重跑写法统一」沿用上次的取值，不触发 S3 重做。
- 费用预估：把画面张数按每张 `kSubtitleReferenceFrameTokens`（600）计入输入 token，估价行显示张数。
  各家对图片的计费规则不同，按公开规则粗算 768×432 一张大约在 260～1100 token 之间，600 是折中值，
  不是实测。

### 2. 开关与知情（所有者 2026-11-11 拍板：默认开）

- 偏好 `video_subtitle_ai_frames`，**默认开**，设备本地、不同步。
- 真的发图要同时满足：开关开着、指派的提供商开了图片输入（`AiProviderConfig.acceptsImages`）、
  用户看过写明「会发画面」的说明（`video_subtitle_ai_frames_consented`）。
- 首次开 AI 校对的说明改写为如实列出会发的东西：识别文本、视频已带字幕里的台词、专名表，
  以及提供商能收图时的视频静态画面（可关掉「参考画面」）。同意即两样都记下。
- 在旧版说明（写着「不发送画面」）下同意过的用户：第一次真要发画面前补看一次。点「不发画面」
  就把开关关掉，任务照常按纯文字校对；不会在他们不知情的情况下开始发图。
- 提供商没开图片输入时不发画面，也不打扰用户；面板写一行说明（纯文字提供商是常态，不标成错误）。

### 3. 用户指定的参考字幕

- 开「生成字幕」时，视频页把播放器里正显示的主字幕与副字幕交给管线：cue 时刻加上当前调轴偏移
  （落到视频时间），语言由文本判定（判不出的不交）。
- 引擎侧 `SubtitleEvidenceWithPinnedTracks` 把它们作为 `pinned` 证据轨并入证据：
  - **只收与目标语言不同的**。同语言的那条很可能就是管线自己上次的产物，喂回去会自我强化。
  - 同语言里 `pinned` 压过自动找到的轨；他言語名额排最前。
  - 该视频有指定轨时证据缓存键多一段指纹，换了字幕 / 调了时间轴会重新收集。
- 指定轨不再对时间轴（用户已经调好的就是准的）。

### 4. 哪些入口带画面

| 入口 | 画面从哪来 | 开关 |
|---|---|---|
| 视频页「生成字幕」管线（保存字幕文件） | 本机视频文件 | 「参考画面」偏好 |
| 视频页本机转录（不保存字幕文件）的「AI 校对」 | 本机视频文件（转录稿时间轴就是视频时间） | 同一偏好；`AsrTranscriptProofreader.frames` |
| 互联远端 host 任务（`video_subtitle`） | host 上那份视频 | 提交方带 `frames=true`；host 的提供商能收图才生效（capability `framesAvailable`）；老 host 不认参数、照常纯文字 |
| ctl `video subtitle-gen` / `fushi_cli video subtitle-gen` | 本机视频文件 | `--frames` / `--no-frames`，缺省取偏好；没看过说明时缺省不带，明说 `--frames` 要 `--consent-ai` |
| `fushi_server subgen` 与 server 当 host | 服务端上的视频文件 | 配置 `ai:` 段的 `images: true`（新键，默认 false，WebUI 有开关）；subgen 可 `--no-frames` |

有声书 / 音乐的转录稿校对不带画面（没有画面）。

### 5. 界面

- 工作台在「参考」卡与工具之间新增「交给 AI 的参考」区：
  - 「参考画面」开关（与生成面板共用同一偏好与知情流程），下方说明或原因
    （没指派提供商 / 提供商不收图 / 视频不在本机——最后一种锁死开关）。
  - 「其它语言字幕」一行：有副字幕时写明这条会按调好的时间轴交给 AI；没有时说明旁边 / 内嵌的会
    自动使用，以及怎么把别处来的也交上去。
  - 一行说明这两样何时生效。
  - 当前视频没有可用的本机生成管线（远端视频、平台不支持）时整区不显示。
- 生成面板（本机与互联两个）的 AI 校对下新增「参考画面」开关。

## 实测与未验证

- 真 ffmpeg 取帧（Windows，本仓 `docs/static-assets/screenshots/fushi-readme-anki-mining-demo.mp4`，
  4K H.264）：单帧约 0.3～0.5 s，768×432 JPEG 约 15～17 KB；字幕大小的日文清晰可读，注音大小的
  小字勉强。定位落在片尾之后、文件不存在、网络路径都返回「取不到」，不抛错。
- **没做成的**：真实模型上「带画面 vs 不带画面」的质量与费用对照。本机只配了一家纯文字提供商，
  没有能收图的可用；每批 10 张 / 768 宽 / 相邻 4 s 仍是初值。
- 没在真机上看过新界面。

## 不做 / 后续

- 不发送音频。
- 不生成译文：其它语言字幕只是校对同语言识别稿的依据（「给单语字幕加 AI 翻译」在黑名单里）。
- 用户指定的参考字幕只进本机管线：本机转录路径的校对器没有证据概念，互联远端任务没有把轨上传给
  host 的通道。远端视频的工作台也因此不显示「交给 AI 的参考」区（画面开关在互联生成面板里有）。
- 比 768 窄的视频会被放大到 768（复用的取帧函数只接受目标宽度）；常见片源都更宽，未处理。

## 测试

- `subtitle_frame_reference_test.dart`：取帧计划、取不到跳过、S3 附图与清单、没开时提示词逐字
  不变、补问沿用同一组、普通话写法、开关变化的缓存行为、指定轨进 S3 且同语言不收、缓存键、费用预估。
- `asr_transcript_proofreader_test.dart`：转录稿校对的画面与清单、取不到的批、没开时不带。
- `video_subtitle_host_job_runner_test.dart`：`frames` 参数、`framesAvailable`、只在能收图时带。
- `video_subtitle_generate_sheet_test.dart`、`remote_video_subtitle_sheet_test.dart`、
  `video_subtitle_studio_sheet_test.dart`：开关、知情流程（首次说明 / 旧用户补看 / 不发画面）、
  原因提示、任务选项。
- `ctl_video_subtitle_routes_test.dart`：`frames` 缺省 / 显式 / 知情。
- `fushi_server`：`subgen_commands_test.dart`（`images: true` 才带、`--no-frames`）、
  `admin_ai_settings_test.dart`（`images` 配置项）。
