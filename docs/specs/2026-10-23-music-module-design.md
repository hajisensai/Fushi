# 音乐模块设计（Music）

状态：方案稿（2026-10-23），决策已于 2026-10-24 拍板（§15），D6 待确认。

## 0. 一句话

做一个**以歌词为中心**的音乐模块：本地 / 服务器 / 光盘三种来源进同一个曲库，
mpv 单引擎播放（无损、无缝、ReplayGain、独占 / bit-perfect 输出），
歌词统一成一条**音节级时间轴**，用 Flutter 原生渲染出 Apple Music 级逐字歌词，
**兼容卡拉 OK 字幕**（ASS `\k` 系列等打轴字幕的逐字擦色，特效 ASS 可原样渲染）；
能自动识别原曲、配上 MV；DVD（与蓝光同一套原盘菜单体验）/ 蓝光 当作「演唱会 /
MV 合集」播放；所有歌词都能点词查词、制卡，和 Fushi 其它模块一个口径。

**范围澄清（所有者 2026-10-24）**：卡拉 OK 指的是**兼容已打好轴的卡拉 OK 字幕**，
不做卡拉 OK 制作与演唱功能——不做打轴编辑器、自动打轴、人声分离 / 伴唱、
升降调、麦克风评分、录音。

## 1. 目标与非目标

### 目标（按优先级）

1. **音质**：FLAC / ALAC / APE / WavPack / TAK / TTA / DSD（DSF / DFF）/ 高解析 PCM
   全格式；无缝播放；ReplayGain（track / album）与缺标签时的 EBU R128 现扫；
   Windows WASAPI 独占、macOS CoreAudio 独占（hog mode）、Android 14+ USB
   bit-perfect；界面上给出完整「信号路径」并如实标注是否 bit-perfect。
2. **歌词与卡拉 OK 字幕**：吃下所有主流行级 / 字级 / 音节级歌词与卡拉 OK 字幕
   格式（§5.1），统一成一个模型；逐字高亮、擦色、对唱分声部、和声 / 背景人声、
   注音（ruby）、翻译、罗马音；ASS 卡拉 OK 特效可「原样渲染」。
3. **刮削**：声纹识别（AcoustID）+ MusicBrainz 为主、VGMdb / 动画曲目为辅；
   识别「原曲」（翻唱 → 作品 → 原唱录音），自动挂 MV（本地文件或在线）。
4. **光盘**：DVD-Video 原盘菜单与蓝光**同一套体验**（复用已有原盘菜单链路）、
   音频 CD 镜像 / CUE+整轨、CD+G 卡拉 OK 盘。
5. **学习闭环**：歌词点词查词、整句 / 片段制卡（音频 + MV 截图）、AB 循环、
   变速不变调、听歌时长进学习统计。

### 非目标（v1 不做，写清理由）

- 不做在线音乐流媒体平台（网易云 / QQ 音乐 / Spotify）的**播放**接入：版权与
  账号体系不可控。歌词 provider 另议（见待决策 D3）。
- 不做 SACD ISO 直读（FFmpeg 不支持，需 sacd_extract 一类外部工具）；DSF / DFF
  文件支持。
- 不做蓝光 BD-J 以外的新菜单引擎：BD-J 已由既有链路承担。
- 不做卡拉 OK 制作 / 演唱：打轴编辑器、自动打轴、人声分离、原唱 / 伴唱切换、
  升降调、麦克风评分、录音一概不做（范围澄清见 §0）。没有逐字时间的歌词按行级显示。
- 不做 DSP 均衡器全家桶 v1（只做 ReplayGain、预放大、限幅；EQ / 卷积放到 P5，
  且开启即退出 bit-perfect）。

## 2. 参考软件与取舍

| 参考 | 学什么 | 不学什么 |
|---|---|---|
| Apple Music / AMLL（Apple Music-like Lyrics） | 逐字浮起、对唱左右分栏、`x-bg` 背景人声小字、弹簧滚动、非当前行模糊；TTML 作为富歌词交换格式 | WebView 渲染 |
| Lyricify / foobar2000 + ESLyric | 多源歌词搜索 + 手动选择 + 偏移微调 + 本地缓存 | 灰色源默认开 |
| Aegisub / 字幕组卡拉 OK 特效 | `\k` `\kf` `\ko` 语义与 templater 产物的正确显示（作为**渲染**参考） | 打轴编辑功能 |
| Roon / Audirvana | 信号路径可视化、bit-perfect 判定 | 付费服务器架构 |
| USB Audio Player Pro / Neutron / Poweramp | Android 高解析与 USB DAC 直出、无缝、ReplayGain | 自写 USB 驱动（改用 Android 14 官方 bit-perfect API） |
| MusicBrainz Picard / beets | AcoustID 声纹 → MusicBrainz 录音 / 作品 / 关系；写回标签可选 | 默认改用户文件 |
| Plexamp / Symfonium / Navidrome | 服务器曲库客户端体验；OpenSubsonic 协议生态 | — |
| VLC / Kodi / PotPlayer | DVD 菜单、按章节分轨 | — |

## 3. 现状盘点（决定能复用什么）

已核实的代码事实（worktree 基于 develop `459d2af220`）：

- **播放引擎**：视频走 media_kit / libmpv（`VideoPlayerController`，
  `fushi/lib/src/media/video/video_player_controller.dart`；mpv 配置
  `video_mpv_config.dart`）。libmpv 与制卡 / ASR 共用**统一 FFmpeg**
  （`tool/ffmpeg-unified/`）。有声书走 just_audio（桌面经 just_audio_media_kit）。
- **光盘**：Windows libmpv 由 `tool/bluray/build_libmpv.ps1` 从 mpv 上游
  `36abaa32` 构建并打 `disc-navigation-state.patch`。**上游这一版已重新具备光盘
  导航层**（`disc_nav_state`、`stream_nav_state.hl` 即 `mp_dvdnav_highlight`、
  DVD 菜单强选 `dvd_subtitle` 轨），Fushi 补丁加了版本化快照
  `disc-navigation-state`。蓝光原盘菜单（HDMV + BD-J）已落地，见
  `docs/specs/2026-10-08-bluray-original-menu.md`、Dart 侧
  `video_disc_menu*.dart` / `bluray_disc_menu_*.dart`。**但 dvdnav 没开**：
  Windows meson 参数无 `-Ddvdnav`，Darwin 显式 `-Ddvdnav=disabled`，
  Dart 侧零 DVD 代码。
- **歌词 UI**：有声书已有 Apple / MD3 两套「歌词模式」覆盖层
  （`fushi/lib/src/media/audiobook/lyrics_player/`，契约
  `lyrics_player_contract.dart`）。歌词正文由透明 WebView 渲染；Android 有
  桌面悬浮歌词（`FloatingLyricChannel` / `FloatingLyricService.java`）。
- **字幕解析**：`packages/fushi_audio/lib/src/parsers/` 有 SRT / ASS / VTT /
  LRC / SMIL / JSON 对齐；**增强 LRC 的词级 `<mm:ss.xx>` 当前被剥掉**；
  `AudioCue.tokenTiming`（`CueTokenTiming`）是瞬态、只给 ASR 产物用。
- **ASR / 对齐**：上游 `fushi-subtitles`（`fushi_asr_align` 等）+ 本仓 ONNX
  后端与 `asr_host.dart` 装配。
- **刮削**：视频 `VideoMetadataProvider` 抽象 + TMDB / AniDB / AniList / MAL；
  封面 `MediaImages`。**全仓无 MusicBrainz / AcoustID / chromaprint**。
- **模块**：`ModuleId`（`fushi/lib/src/models/module_id.dart`）无 music；
  `module_registry.dart` 做 HomeTab 映射。
- **媒体会话**：`audio_service`（`FushiAudioHandler`），目前只服务有声书。
- **音质能力**：仓库里没有 `audio-exclusive` / `replaygain` / gapless 的任何
  使用；统一 FFmpeg 能力下限（`capabilities.json`）不含 ALAC / APE / WavPack /
  DSD / TAK / TTA / CDG。
- DB：`schemaVersion => 124`（CLAUDE.md 写的 v123 已过时，顺手修）。

结论：**播放引擎、光盘导航、歌词壳、ASR 对齐、刮削框架、媒体会话都有底子**；
真正要新建的是音乐曲库、富歌词模型与渲染、声纹刮削，以及 DVD 接入既有原盘菜单链路。

## 4. 架构总览

```
                   ┌──────────────── Flutter（薄 UI）────────────────┐
  曲库页 / 专辑页 / 播放页 / MV + 卡拉OK字幕 / 原盘菜单层（DVD·BD）/ 查词制卡
                   └───────┬──────────────────────┬──────────────────┘
                 快照 stream│ 粗粒度命令           │ 播放位置（本地插值时钟）
   ┌───────────────────────▼─────┐   ┌────────────▼───────────────────┐
   │ native/fushi_music（Rust）   │   │ MusicPlayerEngine（Dart 编排）  │
   │ · 扫描 + 标签（lofty）        │   │ · 一个 libmpv 实例（音乐专用）   │
   │ · CUE / 内嵌 cuesheet 拆轨    │   │ · 队列 / 无缝 / ReplayGain       │
   │ · 声纹（chromaprint）         │   │ · 输出设备 / 独占 / 信号路径     │
   │ · 歌词解析→统一时间轴         │   │ · 变速不变调（scaletempo）       │
   │ · KRC/QRC/YRC 解码、注音对齐  │   │ · audio_service 媒体会话         │
   │ · ASS 卡拉OK标签结构化        │   └────────────┬───────────────────┘
   └──────────────┬──────────────┘                │
                  │                       统一 FFmpeg + libass + dvdnav + libbluray
        Drift（曲库目录持久化，同步 / 备份 / Profile 沿用既有设施）
```

### 4.1 边界划分（遵守「Rust 胖核心、Flutter 薄 UI」）

- **进 Rust（`native/fushi_music`，C ABI + `dart:ffi`）**：一切计算型工作——
  目录扫描 + 标签解析、CUE 拆轨、声纹计算、歌词解析与格式互转、时间轴归一、
  注音与歌词对齐、ASS 卡拉 OK 标签结构化。
  命令粒度示例：`scan_root(root, cursor)` → 事件 stream（每批 ≥256 条）；
  `parse_lyrics(bytes, hint)` → 一次返回整首的 `LyricTimeline`
  （FlatBuffers / 自定义二进制，`Uint8List` 传指针，不来回拼 JSON 字符串）；
  `fingerprint(path, start, dur)`。
  超过 1 ms 的调用一律在后台 isolate。
- **留在 Dart**：曲库目录持久化（Drift，因为同步 / 备份 / Profile 快照 / 墓碑
  设施都在 Drift 上，这是 IO / 编排，不属于「计算型」）、播放编排（libmpv 命令
  本身就是粗粒度的）、网络刮削（IO）、UI。
- **逐帧渲染不跨 FFI**：歌词时间轴整首一次拿到 Dart，渲染层用本地插值时钟
  （复用 `FushiPlaybackClock`）每帧自己算擦色进度。
- 原生库是硬依赖：加载失败明确报错，测试缺库失败不 skip（与 `fushi_compute` 同）。
  `tool/native_libs.ps1` 加入 `fushi_music`。

### 4.2 为什么音乐也用 libmpv 而不是 just_audio

- 统一 FFmpeg：解码能力、ReplayGain、`af` 滤镜图（`scaletempo2`、
  `lavfi`）、gapless、独占输出全由 mpv 提供，五端一致。
- just_audio 在 Android 走 ExoPlayer、iOS 走 AVPlayer：APE / WavPack / DSD
  不全、无独占、无法插滤镜图，满足不了「音质最好」；且 MV / ASS 原样渲染 /
  原盘菜单本来就必须走 mpv。
- 代价：iOS / Android 后台播放与媒体会话要自己接（mpv 不管），由 audio_service
  承担（已有依赖），见 §7.5。

#### 4.2.1 主流 HiFi 播放器怎么做（调研，2026-10-24）

| 播放器 | 播放引擎 | 输出 |
|---|---|---|
| foobar2000 | 自研 | WASAPI 独占（组件）/ ASIO 组件 |
| Audirvana | 自研 | **只用独占**（为控制设备采样率、绕过系统混音）；macOS 有 integer mode |
| Roon / JRiver | 自研 | 独占 / ASIO / 自有网络协议 |
| MusicBee | BASS（商业音频库） | WASAPI / ASIO |
| USB Audio Player Pro / HiBy | 自研 + **自写 USB 驱动**（绕过整个 Android 音频栈） | USB DAC 直出、原生 DSD / DoP |
| Symfonium | 自研 | Android 14+ USB bit-perfect（官方标注实验性）+ USB 独占（原生 DSD / DoP） |
| Feishin（Navidrome 客户端） | **libmpv** | mpv 自带输出 |

结论：

1. 头部 HiFi 播放器几乎都是**自研引擎**，差异不在解码（大家都用 libFLAC /
   FFmpeg 一类），而在**输出端**：独占、跟随采样率、ASIO、DoP / 原生 DSD、
   Android USB 直出。
2. mpv 能覆盖的：全格式解码（统一 FFmpeg）、WASAPI / CoreAudio 独占、
   采样率跟随、gapless、ReplayGain、零 DSP 时整数直通。
3. mpv 覆盖不了的：**ASIO、DoP / 原生 DSD 输出、Android 自写 USB 驱动**、
   macOS integer mode。DSD 在 mpv 里只能先转 PCM。
4. 决策（所有者 2026-10-24 拍板「先走 libmpv」）：v1 全用 libmpv；但
   `MusicPlayerEngine` 的输出层抽成 `MusicOutputBackend` 接口，留出将来的
   **「HiFi 直出后端」**（Rust：解码仍链接统一 FFmpeg 的 libav*，不引入第二份
   FFmpeg；输出用 ASIO / WASAPI 独占 / Android USB，支持 DoP）。只有当实测
   （信号路径面板 + DAC 指示灯）证明 mpv 输出端不够时才启动，不预先做。
   MV / DVD / ASS 原样渲染始终走 mpv。
- 音乐使用**独立的 `Player` 实例**（`vo=null` 纯音频；有 MV / DVD 时切到带
  纹理的视频实例，见 §9），不和视频页抢同一个 mpv。

## 5. 歌词：统一模型 + 全格式

### 5.1 支持的格式

| 类别 | 格式 | 时间粒度 | 备注 |
|---|---|---|---|
| 行级 | LRC、SRT、WebVTT、SAMI、纯文本 | 行 | 纯文本只做静态显示 |
| 字级 | 增强 LRC（A2 `<mm:ss.xx>`）、ESLyric 逐字 LRC、WebVTT cue 内时间戳 | 字 / 词 | 现有 `lrc_parser` 剥词级标签的行为要改 |
| 音节级富格式 | **TTML**（Apple Music / AMLL 方言：`ttm:agent` 对唱、`ttm:role="x-bg"` 和声、`span` 逐字、ruby、翻译 / 罗马音）、Lyricify Syllable（`.lys`/`.qrc` 明文变体） | 音节 | 作为**内部规范交换格式**，导出优先 TTML |
| 卡拉 OK 字幕 | **ASS / SSA**：`\k` `\K` `\kf` `\ko` `\kt`、卡拉 OK templater 产物 | 音节 | 结构化解析 + 原样渲染双轨（§6.3） |
| 平台加密格式 | KRC（酷狗）、QRC（QQ 音乐）、YRC（网易云 JSON） | 音节 | 只解码用户本地已有文件；在线拉取见 D3 |
| 卡拉 OK 歌曲文件 | **UltraStar `.txt`**、MIDI / `.kar` 歌词事件 | 音节 | 只取歌词与时间做逐字显示，音高信息忽略 |
| 图形卡拉 OK | **CD+G**（`.cdg` + mp3 / `.zip`）、DVD / 蓝光字幕轨、MKV 内嵌 PGS | 位图 | CDG 用 FFmpeg `cdg` 解码器出画面 |
| 内嵌 | ID3 `USLT` / `SYLT`、Vorbis `LYRICS` / `UNSYNCEDLYRICS`、MP4 `©lyr`、MKV / MKA 内嵌 ASS / SRT | 视格式 | 扫描时 Rust 直接取出 |

编码探测（UTF-8 / UTF-16 BOM / Shift-JIS / GBK / Big5）沿用 `text_file_io.dart`
的口径，在 Rust 侧实现同一套判据（附回归向量，旧实现输出为基准）。

### 5.2 统一时间轴模型 `LyricTimeline`

```
LyricTimeline
  meta: { source, format, offsetMs, language, agents[], isUserEdited }
  lines[]:
    LyricLine
      startMs, endMs
      agent: AgentRef?          // 对唱声部（v1 / v2 / 合唱）
      role: main | background   // x-bg 和声
      syllables[]:
        LyricSyllable
          text, startMs, endMs
          fill: instant | sweep | outline   // \k / \kf / \ko 语义
          ruby: String?          // 注音（可来自源文件或自动生成）
      translations: { langTag: text }   // 多语翻译
      romanization: String?
      styleRef: AssStyleRef?     // 来自 ASS 时保留样式指针（原样渲染用）
  rawAssScript: bytes?           // ASS 源文件，原样渲染直接喂 libass
  timingQuality: line | word | syllable | syllable+pitch
```

规则：

- **行级歌词也落成同一模型**：每行一个「整行音节」，`timingQuality=line`；
  渲染器按质量自动降级（行级只做整行高亮 + 线性擦色估计，可关）。
- **翻译与原文合并**：多个文件（原文 LRC + 翻译 LRC）按时间戳配对成一份，
  配对规则在 Rust 内统一（时间差 ≤ 300 ms 视为同行，否则作为独立行）。
- **偏移**：`offsetMs` 作用于整份歌词，用户微调实时生效并持久化。
- `AudioCue` 不动：音乐歌词不复用有声书的 cue 表（语义不同：有声书 cue 绑定书章
  节，音乐行绑定曲目且带音节 / 声部）。但**提供 `LyricTimeline → List<AudioCue>`
  适配**，让制卡 / 查词等以 cue 为输入的既有链路直接吃。

### 5.3 注音与罗马音

- 源文件自带 ruby（TTML ruby、RhythmicaLyrics `【漢字|かんじ】`、ASS
  `{\k}漢|かん` 写法）原样保留。
- 无注音时按**当前学习语言**的既有分词 / 读音能力自动补（日语读音、中文拼音
  等，**不假设日语**：没有读音能力的语言不显示注音开关）。
- 自动注音与音节时间对齐：一个汉字音节拆成多个假名时按音节内均分或按对齐结果
  分配，算法在 Rust（输入整行，输出整行）。

### 5.4 歌词来源与优先级

1. 用户手动指定 / 编辑过的（`isUserEdited`，永远最高）
2. 同目录 sidecar（同名 `.ttml` > `.ass` > `.lys/.qrc/.krc/.yrc` > `.lrc` >
   `.srt/.vtt` > `.txt`；同名 + 语言后缀 `.zh.lrc` 视为翻译）
3. 文件内嵌
4. 在线 provider（只装配 **LRCLIB**；国内平台暂不做，见 D3），按「标题 + 艺人 + 专辑 +
   时长 ±2 s」精确匹配，失败再模糊搜索并让用户挑

在线结果缓存进 DB（`music_lyrics`，记 provider 与原始字节），不写用户目录；
「导出到文件旁边」是显式操作。

## 6. 歌词渲染与卡拉 OK 字幕

### 6.1 渲染器：Flutter 原生 `KaraokeLyricsView`

**不沿用有声书的 WebView 歌词正文**：逐字擦色要求每帧（60 / 120 Hz）更新每个
音节的填充进度，WebView 方案要么每帧过平台通道（违反粗粒度原则且有抖动），要么
在 JS 里再维护一份时钟（双时钟漂移）。音乐歌词改用 Flutter `CustomPainter` +
`TextPainter` 缓存：

- 每行预排版一次（字形 run、音节边界的 x 区间、ruby 行），只有字号 / 宽度变了
  才重排；每帧只改 shader 的 stop 位置 → 无布局开销。
- 擦色：`LinearGradient` 硬边（`\k`/instant）或羽化边（`\kf`/sweep），
  `\ko` 只描边；当前音节轻微上浮 + 辉光（Apple 风），时长超过 1 s 的长音做
  「呼吸」放大（AMLL 同款），都受 `fushiMotionDuration` 控制，墨水屏 / 减弱
  动态效果下退化为静态高亮。
- 布局：当前行居中弹簧滚动；非当前行降不透明度 + 轻模糊（可关，低端机自动关）；
  对唱 `agent=v2` 右对齐、合唱居中；`x-bg` 和声以小字号附在主行下方并独立擦色；
  翻译 / 罗马音作为副行。
- 交互：点行跳转；**长按 / 点词进入查词**（复用视频字幕的命中测试思路，
  `VideoSubtitleHitTester` 的音节级版本），查词时自动暂停可配；拖动歌词可预览
  再松手跳转。
- 外壳复用：Apple / MD3 两套「宽屏双栏 / 窄屏单栏」几何、模糊封面背景、控制条
  直接复用 `lyrics_player/` 的 `LyricsPlayerDesign`（抽出与有声书无关的部分到
  `media/shared/lyrics_shell/`），歌词矩形里放 `KaraokeLyricsView` 而不是 WebView。

### 6.2 显示模式

- **歌词页**（默认）：封面 + 逐字歌词（Apple Music 式）。
- **MV 页**：MV 画面 + 卡拉 OK 字幕叠加，三选一：ASS 原样渲染 / 逐字歌词样式 /
  关闭；字幕偏移可调，点字幕查词。
- **桌面歌词**：Android 复用 `FloatingLyricService`；Windows / macOS 新增置顶
  透明穿透窗口（复用查词浮窗已有的无激活窗口能力，**不抢前台**），单行 / 双行，
  逐字擦色。
- **锁屏 / 通知栏**：当前行写进媒体会话的副标题（iOS / Android 原生歌词位按平台
  能力）。

### 6.3 ASS「原样渲染」

动漫 OP / ED 的字幕组卡拉 OK 特效（`\t` `\move` `\clip`、templater 粒子）
结构化后会丢效果。所以 ASS 有两条路：

- **结构化**（默认用于纯 `\k` 系列）：解析成 `LyricTimeline`，走原生渲染器，
  享受查词 / 注音 / 统一主题。
- **原样渲染**（检测到 `\t`/`\move`/`\clip`/逐字定位等特效标签自动推荐）：
  交给 libass。音频文件没有画面，就让 mpv 以封面（或纯色 / 可视化）作为视频轨
  输出到纹理，ASS 叠在上面（这一路允许 mpv 画字幕，类似视频页图形字幕例外）；
  同时后台仍保留结构化时间轴，用于查词：点画面时按当前时间取行，弹出该行文本
  的可点选浮层。

### 6.4 歌词编辑（仅限轻量）

不做打轴。只提供：整首 / 单行偏移、选择歌词来源、改错字、编辑翻译与注音；
改动存 DB（`isUserEdited`），可导出为原格式或 TTML。音节时间只读。

## 7. 播放引擎与音质

### 7.1 解码与容器

- 格式：FLAC、ALAC、APE、WavPack（含 hybrid）、TAK、TTA、Musepack、WAV / AIFF /
  W64 / CAF、DSF / DFF、MP3、AAC、Opus、Vorbis、MKA、MQA 文件按普通 FLAC 解码
  （不做 MQA 展开）。
- **统一 FFmpeg 能力下限要扩**：`capabilities.json` 增 decoders `alac` `ape`
  `wavpack` `tak` `tta` `mpc8` `dsd_lsbf` `dsd_msbf` `dsd_lsbf_planar`
  `dsd_msbf_planar` `cdgraphics`，demuxers `ape` `wv` `tak` `tta` `dsf` `iff`
  `aiff` `caf` `w64` `cdg` `mpc8` `matroska`（已有）；`verify_ffmpeg_capabilities.py`
  与守卫一起改，五端重编。**不引入第二份 FFmpeg**。
- CUE：整轨 + `.cue`、FLAC 内嵌 `CUESHEET`，曲库层拆成虚拟曲目（起止样本），播放
  走 mpv `start`/`end` 或 cue demuxer，**拆轨点无缝**。
- DSD：mpv 不支持 DoP / 原生 DSD 输出，v1 一律 DSD→PCM（176.4 / 352.8 kHz 可配，
  按设备能力取上限），信号路径面板标「DSD→PCM 转换」，不标 bit-perfect。
  DoP / 原生 DSD 留给 §4.2.1 的 HiFi 直出后端。

### 7.2 无缝与队列

- mpv `gapless-audio=weak`（同格式真无缝，格式变化时重开设备）+
  `prefetch-playlist=yes`；队列在 Dart，向 mpv 维持「当前 + 下一首」两项播放列表，
  切歌前预加载。
- 专辑模式自动 album ReplayGain，随机播放自动 track gain。
- 交叉淡入（可选，默认关；开了即非 bit-perfect，标注）。

### 7.3 响度

- ReplayGain 2.0：读标签（`REPLAYGAIN_*`、R128_*、iTunNORM 换算）；缺标签的曲目
  后台用统一 FFmpeg `ebur128` 扫描并写入 DB（**不改用户文件**，写回是显式操作）。
- 预放大 + 防削波（`replaygain-clip=no` + 峰值保护）。

### 7.4 输出与 bit-perfect

| 平台 | 方式 | 说明 |
|---|---|---|
| Windows | `ao=wasapi` + `audio-exclusive=yes` | 独占时设备跟随源采样率 / 位深（`audio-samplerate` 不设、`audio-format` 不强制）；共享模式走混音器 |
| macOS | `ao=coreaudio` + `audio-exclusive=yes`（hog mode）| 同时切设备 nominal sample rate；退出还原 |
| Android | 常规 `ao=aaudio`/`audiotrack`；**Android 14+ USB DAC**：原生侧调用 `AudioManager.setPreferredMixerAttributes`（`MIXER_BEHAVIOR_BIT_PERFECT`）| bit-perfect 属性是可选 HAL 能力，先查 `getSupportedMixerAttributes`，不支持就如实显示「不支持」；bit-perfect 下系统不做软件音量，界面音量条改为提示用 DAC 硬件音量 |
| iOS | `ao=audiounit`；AVAudioSession 首选采样率设为源采样率 | iOS 无独占，标注「系统混音」 |
| Linux | `ao=pipewire` / `alsa`（`hw:` 设备直出可选） | 源码构建平台 |

**信号路径面板**（Roon 式）：源（容器 / 编码 / 采样率 / 位深 / 声道 / 码率）→
解码 → DSP 链（ReplayGain、音量、变速、重采样，每项是否生效）
→ 输出（设备、模式、实际采样率 / 格式）。**只有链上零修改且独占 / bit-perfect
时才显示「Bit-perfect」**，任何一环生效就降级为「高品质」并指出是哪一环。数据来自
mpv 属性（`audio-params`、`audio-out-params`、`af`、`current-ao`），不靠推测。

### 7.5 后台与媒体会话

- `audio_service` 扩展出音乐用的 `MediaItem`（封面、艺人、专辑、时长、当前歌词行）
  ；`FushiAudioHandler` 按「当前活跃会话」在有声书与音乐之间切，**同一时刻只有一个
  会话持有媒体会话**（另一个暂停）。
- Windows SMTC、macOS / iOS Now Playing 由 audio_service 的平台实现提供，若某平台
  缺失再补原生（先实测，不预设）。
- 耳机拔出暂停、蓝牙按键、来电打断、Android 音频焦点；睡眠定时（播完本曲停）。

## 8. 刮削：识别原曲 + MV

### 8.1 Provider 抽象

照视频 `VideoMetadataProvider` 的形态建 `MusicMetadataProvider`
（`packages/fushi_engine/lib/media/music/metadata/`，纯 Dart、不碰 Flutter），
带 resolver / merge / 字段锁 / 原始快照（与视频同模式，表名见 §10）。

| Provider | 用途 | 纪律 |
|---|---|---|
| **AcoustID** | 声纹 → MusicBrainz recording id | 需应用 API key；声纹本地算（Rust chromaprint 实现），只上传指纹 + 时长 |
| **MusicBrainz**（主源） | 录音 / 发行 / 艺人 / 作品（work）/ 关系（翻唱、原唱、MV、作词作曲编曲、声优演唱）| 限 1 req/s、带规范 User-Agent，与 AniDB 同等限流纪律 |
| **Cover Art Archive** | 专辑封面（front / back / booklet） | 与 MusicBrainz 一体 |
| **VGMdb** | 动画 / 游戏 / 声优唱片（日文原名、Catalog No.、角色歌）| 无官方 API，走社区 JSON 镜像或 HTML，频率保守；可关 |
| **AniDB / 本仓动画库** | OP / ED / 插入曲 ↔ 动画作品与集数 | 复用已有 AniDB 身份，不新增并行动画源（遵守动画刮削 provider 边界） |
| **LRCLIB** | 歌词（§5.4） | — |

识别顺序：已有 MBID 标签 → 标签精确查（艺人 + 标题 + 专辑 + 时长）→ AcoustID
声纹 → 用户手选。识别结果写 DB，「写回文件标签」是显式操作（Picard 式预览 diff）。

### 8.2 「原曲」

- 翻唱 / 歌ってみた / Live / 混音：MusicBrainz recording → `performance of` work
  → 该 work 的最早发行录音 / 标为 original 的录音 = **原曲**。
- 曲目详情页展示「原曲」「其它版本」（同 work 的所有录音，本地有的直接可播），
  以及动画出处（第几季 OP、使用集数），点了可跳到视频库对应作品（跨模块）。

### 8.3 MV

来源优先级：

1. 本地：同目录 / 指定 MV 文件夹里的视频，按（标签 / 文件名 / 时长 / 声纹比对
   视频音轨）匹配。声纹比对是硬判据：MV 常有前奏剧情，取视频音轨滑窗对齐，得到
   **MV 相对音频的偏移**，从而 MV 模式下歌词时间轴仍然对准。
2. MusicBrainz 关系里的 `music video` recording 及其 URL 关系（官方 YouTube 等）。
3. 在线搜索（YouTube，复用 `youtube_source_resolver.dart`）：只取官方频道 /
   「Official Video」高置信结果，用户确认后绑定。
4. 动画 OP / ED：可绑定视频库里对应集的片头片尾区间（「无字幕 OP」NCOP 优先）。

MV 播放切到带纹理的 mpv 实例，**音频源可选**：用 MV 自带音轨，或用本地无损音轨
+ MV 画面（按偏移同步，画面静音）——后者是「看 MV 听无损」。

iOS：在线 MV（YouTube 解析）**不归入** `StoreRestrictedCapability`（D5 拍板），
五端一致。

## 9. 光盘：DVD（含菜单）/ 蓝光 / CD

### 9.1 DVD-Video：与蓝光原盘菜单同一套

**所有者要求（2026-10-24）：DVD 菜单与 BD 菜单一样。** 所以 DVD 不新设计任何交互，
完全套 `docs/specs/2026-10-08-bluray-original-menu.md` 的模型：

- **呈现**：mpv 在原视频纹理里合成菜单（DVD 是 SPU 字幕层 + 按钮高亮），Flutter
  不画菜单，只提供进入、返回和输入转发；全屏是盘自己的画面，没有侧栏。
- **顶栏**：复用 `BlurayDiscMenuChrome`（改名 `DiscMenuChrome`，DVD / BD 共用）：
  浮动胶囊、2 s 无操作自动隐藏、隐藏时不吃指针让点击落到盘的按钮上；按钮是
  返回、盘名、顶层菜单（DVD = Root/VMGM 菜单，BD = Top Menu）、标题菜单、音轨、
  字幕、更多。设计稿 `Disc.dc.html` 即此形态。
- **输入**：与蓝光同一条转发路径——方向 / 确认 / 返回 / 手柄 / 遥控；鼠标**只转发
  点击，不转发悬停**（与 BD 同一理由：悬停即选中，自动动作按钮会被误触发）。
  Flutter 弹窗与设置面板仍优先拿输入；菜单关闭后恢复普通播放器操作。
- **会话与标题身份**：菜单会话以盘根定位；未确定正片时不绑定条目、不存进度、
  不累计学习、不允许制卡；选中标题后按原生快照里的真实 title / PGC 绑定库条目；
  迟到结果按「生成代数」丢弃——与 BD 的 MPLS 规则一一对应。
- **音轨 / 字幕**：默认由盘控制（`aid/sid=auto`），用户在 Fushi 显式选轨时接管，
  进入交互菜单时恢复盘控制——与 BD 相同。
- **失败**：读盘失败明确报错，不得悄悄降成「播最长 title」并声称进了菜单。

实现上**复用既有光盘导航层，而不是另写引擎**。mpv 上游 `36abaa32` 已有 DVD 导航
（`mp_dvdnav_highlight`、菜单强选 `dvd_subtitle`），Fushi 的
`disc-navigation-state` 快照与 `video_disc_menu*` 输入 / 焦点宿主已为蓝光落地。
需要做的：

1. **原生**：五端 libmpv 构建开 `-Ddvdnav=enabled`，编入 libdvdnav / libdvdread
   （libdvdcss 不随包：解 CSS 的合法性因地区而异，见 D6；无 CSS 的自制盘 /
   已解密 ISO / VIDEO_TS 直接可用）。Darwin 的 `-Ddvdnav=disabled` 改掉。
   探针 `probe_libmpv.py` / `verify_menu_render.py` 增加 DVD 用例。
2. **快照扩展**：`disc-navigation-state` 加 `dvd_state` 分支（域 FP / VMGM / VTSM /
   VTS、title / PGC / cell、still 状态、高亮按钮矩形与调色板），版本号 +1，
   与蓝光同一套「生成代数」规则：迟到的库查询 / 制卡结果不得写入新标题。
3. **菜单交互**：`bluray_disc_menu_input` / `bluray_disc_menu_focus_host` /
   `bluray_disc_menu_bar` 去掉 `bluray_` 前缀，泛化成 DVD / BD 共用（命令映射按盘
   类型分派到 dvdnav / libbluray）；静帧菜单（still）期间与 BD 菜单一样没有时间轴。
4. **高亮渲染正确性**：mpv 老版本 DVD 菜单被删的直接原因就是高亮渲染不对；
   验收要逐张截图对比按钮高亮调色板（`verify_menu_render.py` 加 DVD 盘样本），
   不对就修补丁，不允许退成「只画个框」。
5. **入口**：ISO / `VIDEO_TS` 文件夹 / 物理光驱（桌面）。没有菜单或用户选择
   「直接播放」时，按 title 列表播放（lsdvd 式：时长、章节数、音轨 / 字幕轨语言）。

### 9.2 音乐语境下的光盘

- **演唱会 / MV 合集 DVD·蓝光**：章节即曲目——章节列表可「导入为曲目」进曲库
  （带起止时间），之后可以像普通歌曲一样加歌单、挂歌词；入口放在曲库「光盘」
  子标签的盘详情里，**不放进原盘菜单画面**（菜单画面与 BD 一致，只有顶栏）；刮削按
  DVD 标题 + 章节名查 MusicBrainz（DVD 发行在 MB 里常有 tracklist）。
- **KTV DVD / VCD**：盘上的卡拉 OK 字幕是位图字幕轨（mpv 画），照常显示；音轨按
  盘上的多音轨正常切换，不做原唱 / 伴唱的特殊处理。
- **蓝光**：完全复用 `2026-10-08-bluray-original-menu.md` 的链路；音乐侧只加「章节
  导入为曲目」和音乐播放页入口。
- **音频 CD**：桌面物理光驱读取（mpv `cdda://`）+ CD-TEXT + MusicBrainz Disc ID
  查询；抓轨（rip 成 FLAC + CUE + 日志，AccurateRip 校验）列为 P5 可选。
- **CD+G**：`.cdg` + 音频成对识别，画面走 FFmpeg `cdgraphics` 解码到纹理。

## 10. 数据模型（Drift，schema 124 → 125）

命名遵守术语表（`cover`、`deletedAt`、`<名>At` 毫秒、`source library`）。

| 表 | 关键列 |
|---|---|
| `music_tracks` | `track_uid`（内容派生：路径 + 起止样本 + 文件指纹）、`source_id`、`path`、`cue_start_ms`/`cue_end_ms`、`duration_ms`、`codec`、`sample_rate`、`bit_depth`、`channels`、`bitrate`、`is_lossless`、`title`、`title_sort`、`album_id`、`disc_no`、`track_no`、`year`、`genre`、`rg_track_gain`/`rg_track_peak`/`rg_album_gain`/`rg_album_peak`、`r128_scanned_at`、`mb_recording_id`、`mb_work_id`、`acoustid`、`file_mtime_at`、`file_size`、`added_at`、`deleted_at` |
| `music_albums` | `album_uid`、`title`、`album_artist_credit`、`mb_release_id`、`mb_release_group_id`、`catalog_no`、`release_date`、`cover_image_id`（→ `MediaImages`）、`total_discs` |
| `music_artists` | `artist_uid`、`name`、`sort_name`、`mb_artist_id`、`kind`（person / group / character）|
| `music_track_credits` | `track_uid`、`artist_uid`、`role`（artist / featured / composer / lyricist / arranger / vocal-cv / character）、`credit_name`、`ord` |
| `music_lyrics` | `track_uid`、`source`（sidecar / embedded / provider:<name> / auto / user）、`format`、`raw`（blob）、`timeline_cache`（blob，Rust 二进制）、`timeline_version`、`offset_ms`、`timing_quality`、`is_user_edited`、`updated_at` |
| `music_videos` | `track_uid`、`kind`（local / youtube / disc-chapter / anime-episode）、`ref`、`offset_ms`（MV 相对音频）、`confidence`、`is_user_bound` |
| `music_disc_sources` | `disc_uid`、`path`、`kind`（dvd / bluray / cdda / cdg）、`volume_id`、`has_menu`、`title_map`（json） |
| `music_playlists` / `music_playlist_entries` | 常规；智能歌单规则存 json |
| `music_play_events` | `track_uid`、`started_at`、`listened_ms`、`completed`（history 唯一含义：最近播放流） |
| `music_scrape_meta` / `music_metadata_raw_snapshots` / `music_locked_fields` | 与视频刮削同构 |

- `SourceLibraryKind` 加 `music('music')`（持久化值新增，不改旧值）。
- 学习统计：`StatSourceKind` / `ActivityMediaKind` 加 music，跨域换算在
  `media_kind_mappings.dart` 补齐；**只有出现查词 / 制卡等学习动作或
  用户开启「听歌计入学习」时**才写 `study_segments`，避免把背景音乐全算成学习
  时长（D4）。
- 同步：曲目身份用内容派生 uid，跨设备 / 互联共享歌词编辑、歌单、播放统计。
  墓碑 `SyncTombstoneKind` 加 music 类型。
- 备份：歌词编辑、歌单、绑定关系进备份；封面缓存不进。

## 11. 模块与 UI

### 11.1 模块注册

- `ModuleId.music`（`prefKey: module_music_enabled`），五端可用；新增 `HomeTab.music`
  与 `module_registry` 映射；设置分类「音乐」。音乐模块不新增受限能力。
- 与 `ModuleId.listening` 的关系：`listening` 是**有声书 / 听书**的模块开关
  （`prefKey: module_listening_enabled`，`ShortcutScope.audiobook` 归它，没有
  底栏 tab，入口在书架里），音乐是独立的新底栏模块，两者不合并。
- i18n key 前缀 `music_`，一律 `i18n_sync.dart --add`。

### 11.2 页面

- **音乐库页**：专辑网格 / 艺人 / 曲目 / 作品（动画）/ 歌单 / 光盘 子标签；
  顶栏动作用 `FushiFloatingTopBar` `adaptiveOverflow`；分段用
  `adaptiveSegmentedButton`；网格错峰进场 `FushiEntranceScope` +
  `fushiStaggeredItemBuilder`，卡片 `FushiPressScale` / `FushiHoverLift`。
- **专辑页**：大封面取色背景、碟片分组、格式徽章（`FLAC 24/96`、`DSD64`、
  `Hi-Res`）、整碟 ReplayGain。
- **曲目详情**：原曲 / 其它版本 / MV / 动画出处 / 歌词来源与编辑 / 信号路径。
- **播放页**：Apple / MD3 两套（复用歌词外壳），封面 ↔ 歌词 ↔ MV 共享轴切换。
- **迷你播放条**：复用 `now_listening_mini_bar` 形态，全局常驻，与有声书互斥显示。
- **MV + 卡拉 OK 字幕页**、**原盘菜单层**（DVD / BD 共用视频页光盘菜单宿主）。
- **首页 dashboard**：「继续听」「最近添加」卡片。
- 曲库页**不放统计概况卡**（曲目数、无损占比等）——所有者 2026-10-24 明确不要。

### 11.3 快捷键 / 手柄

播放、上下曲、±5 s、AB 循环、歌词偏移 ±100 ms、切换字幕渲染方式（原样 / 逐字 /
关）；原盘菜单沿用视频页光盘菜单快捷键；新 `ShortcutScope.music`，焦点所有权按 `docs/agent/focus-ownership.md`。

## 12. 学习闭环

- 歌词点词 → 现有查词弹窗；句子 = 当前歌词行（含翻译作为释义备选）。
- 制卡：音频片段 = 该行（可前后扩 0.5 s）；图片 = 封面或 MV 当前帧；沿用
  `video_clip_exporter` 的导出路径。
- AB 循环一行 / 多行。
- 歌词生词统计：一首歌的未知词数 / 覆盖率（复用词典已知词判定），曲库可按「难度」
  排序。

## 13. 分期

| 期 | 内容 | 退出标准 |
|---|---|---|
| **P0 底座** | `fushi_music` Rust crate 骨架 + 扫描 / 标签 / CUE；统一 FFmpeg 能力下限扩充并五端重编；schema 125；`ModuleId.music`；曲库页 / 专辑页 / 基础播放（mpv 独立实例、gapless、ReplayGain、媒体会话） | 五端能扫库播放 FLAC/ALAC/APE/WV/DSF，CUE 拆轨无缝 |
| **P1 歌词** | 全格式解析 → `LyricTimeline`（含回归向量）；`KaraokeLyricsView`；Apple / MD3 歌词页；LRCLIB；偏移；桌面歌词；查词制卡 | §5.1 每种格式有样本测试；逐字擦色 120 Hz 不掉帧（profile 实测） |
| **P2 音质** | 独占 / bit-perfect 五端；信号路径面板；R128 扫描；DSD 处理 | 每平台实测 `audio-out-params` 与源一致，面板判定与实测一致 |
| **P3 卡拉 OK 字幕** | ASS 卡拉 OK 结构化 + 原样渲染（libass）；MV + 卡拉 OK 字幕页；UltraStar / `.kar` / CDG 显示 | 字幕组特效 ASS 样本与 mpv 单独播放逐帧一致；`\k` `\kf` `\ko` 擦色语义正确 |
| **P4 刮削与 MV** | AcoustID / MusicBrainz / CAA / VGMdb；原曲与其它版本；MV 本地匹配 + 声纹偏移 + 在线绑定；动画 OP/ED 联动 | 抽样 200 首识别正确率报告；MV 偏移误差 ≤ 100 ms |
| **P5 光盘与扩展** | DVD 原盘菜单（dvdnav 构建 + 快照 + 高亮验收 + 套用 BD 菜单交互）；章节导入为曲目；CD 读取；服务器曲库（Jellyfin 音乐 / OpenSubsonic）；EQ / 卷积（可选） | DVD 菜单在样本盘上高亮截图逐张正确；菜单→正片→返回菜单闭环；交互与 BD 菜单逐项一致 |

每期按本仓验证纪律：Dart 改动 `flutter analyze` 为推送门；播放 / 歌词 / 布局类
修复要在真机或 Windows 离屏 runner 复测原始路径；Rust 侧带固定输入→输出向量。

## 14. 风险

- **DVD 高亮正确性**：正是 mpv 当年删菜单的原因。缓解：先在 P5 前单独做一个
  探针盘集（多家制作工具出的盘），用离屏渲染截图对拍；失败则修补丁而不是降级。
- **iOS 后台 + mpv**：AVAudioSession 中断与 mpv 状态同步要实测；不行就该平台的
  纯音频播放保留一条 AVPlayer 退路（仅 iOS，且功能降级在界面标明）——此为平台
  限制下的临时兼容层，需写清清理条件。
- **独占模式与系统音量 / 其他应用冲突**：独占失败要明确提示并退回共享，不静默。
- **歌词 / 封面版权**：只缓存不分发；在线 provider 默认只开 LRCLIB。
- **统一 FFmpeg 重编**：五端二进制都要换，守卫 `ffmpeg_unified_*` 与配方一起改。
- **CLAUDE.md 漂移**：schema 版本 / 表数已与代码不一致，P0 一并修正。

## 15. 决策记录（所有者 2026-10-24 拍板）

- **D1 模块位置**：独立底栏模块。（`listening` 是有声书模块，见 §11.1。）
- **D2 播放引擎**：先走 libmpv；iOS 实测不行再说。HiFi 直出后端只留接口（§4.2.1）。
- **D3 国内平台歌词**：暂时不做；在线歌词只装配 LRCLIB。本地已有的 KRC / QRC /
  YRC 文件照常解析。
- **D4 学习统计口径**：只有发生学习动作或用户开启「听歌计入学习」时才计。
- **D5 iOS 在线 MV**：不归入受限能力。
- **D6 libdvdcss**：**未答复**，按推荐暂定不随包（桌面端允许用户自行放置系统库），
  P5 动工前再确认。
- **D7 人声分离**：作废——卡拉 OK 只做字幕兼容，不做人声分离（范围澄清见 §0）。
- **D8 DVD 菜单**：与 BD 原盘菜单同一套体验（§9.1）。
- **D9 曲库统计卡**：不要。

## 16. 设计稿

视觉稿（桌面 5 张 + 手机 3 张 + 信号路径面板）：
<https://claude.ai/artifact/YKRDyRgaDhxsgSnpBbN2qC>（私有，需所有者分享后他人可见）。
