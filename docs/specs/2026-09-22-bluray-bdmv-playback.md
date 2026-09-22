# 蓝光盘（BDMV）解析与播放（2026-09-22）

> 需求：「蓝光盘的视频播放支持一下，弄一个 bd 解析。可以拿来看电影或者 mv 这种。」
> 背景截图里说明了盘的形态：视频不是单个 MP4，而是 `BDMV` 结构里的 M2TS 流。

## 现状：今天一张盘进库会变成什么

`.m2ts` 早就在 `kVideoExtensions` 里（BUG-168 加的），所以把一张盘的目录加成扫描根**今天就能扫**——扫出来的是 `BDMV/STREAM/` 下的一堆散装文件：

- 正片按授权切割被切成 2~20 段，每段一条独立条目，顺序与时长全错；
- 菜单循环、厂标、版权警告、预告片各自成条；
- 标题全是 `00001`、`00002`……而 `bookUid` 只取 basename（`singleVideoBookUid`），两张盘的 `00001.m2ts` 还会撞成 `video/00001` 与 `video/00001 (2)`；
- 章节、音轨语言、字幕语言一概没有。

真正描述「这张盘该怎么播」的是 `BDMV/PLAYLIST/*.mpls`，全仓此前零解析（只有 `filename_parser` 把 `BDMV` 当发布组噪音 token 剥掉）。

## 交付物

1. **MPLS / CLPI 解析器**（纯 Dart，五端一致）：片段序列、IN/OUT、章节点、音轨与字幕轨语言、编码/扫描格式/帧率。
2. **盘 → 标题列表**：从几条到上百条 MPLS 里挑出真正是内容的那几条。
3. **播放**：一条 MPLS → 播放内核吃得下的东西（真实 m2ts 路径，或 `edl://` 拼接）。
4. **入库**：扫描根里认出盘，一张盘一个合集，一条标题一行 `VideoBooks`。
5. **规格与封面**：时长/编码/语言直接从 MPLS 出，封面抽帧指向真实码流。
6. **删除护栏**：删条目不得动到盘结构。

## 为什么不交给播放器自己解盘

mpv 有 `bluray://`，但**只有 Windows 的随包 libmpv 编了 libbluray**：

| 平台 | libmpv 来源 | libbluray |
|---|---|---|
| Windows | `third_party/media_kit_libs_windows_video/vendored/mpv-dev-*.7z` | **有**（DLL 里留着 meson 配置行 `-Dlibbluray=enabled`，`bdnav/mpls_parse.c` 等编译路径与 `stream_bluray.c` 的字符串都在） |
| macOS / iOS | `hajisensai/libmpv-darwin-build` 构建期下载 | 上游默认不编，**无** |
| Android | `hajisensai/libmpv-android-video-build` 构建期下载 | 同上，**无** |
| Linux | 系统 libmpv | 随发行版，不可控 |

靠 `bluray://` 会把这个功能做成「只有 Windows 能看」。MPLS 是公开的定长大端结构，纯 Dart 解析在五端行为完全一致，还顺带把分辨率、帧率、编码、音轨与字幕语言一次拿全——这些用 ffprobe 反而要逐段探测，而 BD 的 m2ts 实测一条 18~75 秒（BUG-1867/1877）。

解析器的每个字段偏移都与上游 libbluray 的 `bdnav/{mpls_parse,clpi_parse}.c` 逐条比对过，取值表（`bd_video_format_e` / `bd_video_rate_e` / `bd_stream_type_e`）逐值对齐，写盘侧用 tsMuxeR 的 `blurayHelper.cpp` 做了反向交叉验证。

## 解析层：`packages/fushi_engine/lib/media/video/bluray/`

| 文件 | 职责 |
|---|---|
| `bluray_playlist.dart` | MPLS：PlayItem 序列、IN/OUT、STN table（视频/音频/PG 三类流）、PlayListMark 章节 |
| `bluray_clip_info.dart` | CLPI：只取 SequenceInfo 的呈现起止，用来判「这段是不是被整段用掉」 |
| `bluray_disc.dart` | 认盘、读全部播放列表、筛选标题、盘名（`BDMV/META` 优先于目录名） |
| `bluray_source.dart` | 一条 MPLS → 可播源 |
| `bluray_probe.dart` | 一条 MPLS → `VideoProbeFacts` |

放在 `fushi_engine` 而不是 `fushi/`：全部是纯逻辑，无头服务端将来要用不必搬家。

解析失败一律返回 `null`，不抛——输入是用户随手拖进来的目录，半张盘、`BACKUP/` 里的截断文件、非 BD 的同名文件都是常态。

## 标题筛选链（`selectBlurayTitles`）

盘上的 `PLAYLIST/` 少则 3 条多则上百条，其中真正是内容的往往只有几条。剩下的是菜单循环、版权警告、预告，**以及有意生成的诱饵**——某些发行盘会放几十条时长与正片完全相同、只是片段顺序被打乱的播放列表，专门让自动选片工具选错。

六步，每步只用盘上能确证的事实，不做画面内容推断：

| # | 判据 | 挡掉什么 |
|---|---|---|
| 1 | `playback_type != 1` | 随机/洗牌播放列表是菜单构件 |
| 2 | 引用的 m2ts 不在盘上 | `BACKUP/` 与主目录不一致的半张盘 |
| 3 | 时长 < 60 秒 | 厂标、警告画面、菜单循环 |
| 4 | 同签名合并：`(片段多重集, 总时长)` | 顺序打乱的诱饵——多重集一排序就现形。同签名里留**章节最多**的那条（诱饵通常只有一个章节点） |
| 5 | 「全部播放」：片段集合恰好等于另外 ≥2 条的并集 | TV 盘把各集串起来的 play-all（丢它保各集） |
| 6 | 时长 < 最长标题的 15% | 电影盘的花絮 |

第 6 条是整条链里最省事的一步：**它让「电影盘只进正片」和「MV 盘全进」用同一个判据表达**，不需要先猜这张盘是什么类型。电影盘的花絮通常在正片的 5% 以下（120 分钟对 2~5 分钟），而剧集盘/MV 盘的各条目彼此在同一量级。0.15 这个值同时给「40 分钟的制作特辑」留了余地。

被筛掉的播放列表仍完整保留在 `BlurayDisc.playlists` 里，将来要做「显示全部标题」不必回头改筛选链。

**命名**：单标题盘用盘名；多标题盘是 `<盘名> - 01`、`- 02`（按 mpls 编号升序）。MPLS 里没有曲名/集名，编造不如给一个稳定可排序的序号，用户可以自己改。

## 播放：两种形态，能用第一种就绝不用第二种

### 形态 1：真实文件路径

播放列表只有一个片段、且把这段从头用到尾时，直接交出 `BDMV/STREAM/<id>.m2ts`。这是绝大多数 MV 盘、剧集盘每集、以及单段正片的形态。

给真实路径的好处**不在播放**（两种都能播），**在下游**：ffmpeg 抽封面、内嵌字幕探测、制卡裁剪这些链路全都吃「一个本地文件」，换成别的什么它们就地失效。

判「是不是整段用满」必须读 CLPI：MPLS 的 IN/OUT 是绝对 PTS，m2ts 的首个 PTS 几乎从不为 0，拿 IN 和 0 比毫无意义。留 1 帧容差（授权工具写出来的 IN/OUT 与 CLPI 的呈现区间常差几个 tick）。

### 形态 2：`edl://`

多段拼接，或需要按 IN/OUT 截取时。EDL 是 mpv 内核自带的时间轴拼接语法（不是可选构建项），它把若干段拼成一条连续时间轴，seek、时长、进度全部按拼接后的轴走——正是 BD 播放列表要的语义。

路径一律走 `%<字节数>%<内容>` 长度前缀：`:`（盘符）、`,`（字段分隔）、`;`（条目分隔）在 EDL 里都有语义，Windows 路径必然撞上，而 EDL 没有转义字符。长度按 **UTF-8 字节**算，不是码点。

#### ⚠️ EDL 的 `start` 在源文件**原始时间戳域**里，不减零点

这条踩过一次，写下来免得再踩。mpv 有两套互不相干的语义：

- **顶层文件**（`--start=10 file.m2ts`）：**归零**。`--rebase-start-time` 默认 `yes`，文档里明说就是为传输流写的。
- **EDL 段的 `start`**：**不归零**。`demux_edl.c` 在省略 `start` 时填的默认值是源 demuxer 的 `start_time`（不是 0），而 `demux_timeline.c` 的 `switch_segment()` 用 `ts_offset = start - d_start` 把源包映到虚拟时间轴上——两处都要求 `start` 与源包的原始 PTS 同域。子 demuxer 没有经过 `loadfile.c` 的 rebase，吐的就是原始 PTS。

（`DOCS/edl-mpv.rst` 里「If the start time is omitted, 0 is used」与代码冲突，以代码为准。）

所以 EDL 里直接写 MPLS 的 IN。减了零点的后果不是「差一点」，是**该段整个播不出来**：seek 目标在源域算成负值，源包的原始 PTS 加上 `ts_offset` 后远超 `seg->end`，在 `demux_timeline.c` 里被整片丢弃 → 瞬间 EOF。

### 章节

来自 MPLS 的 `PlayListMark`，**不问 libmpv**：EDL 拼接时 libmpv 会把每个分段边界当成一章（分段是授权切割，不是章节），单段时它又只看得到 m2ts 里根本没有的容器章节。两种情况下 `chapter-list` 给的都不是这张盘的章节表。

全局位置换算与 libbluray 的 `navigation.c` 同形：`sum(前面各段时长) + (mark_time - 本段 IN)`。落在本段区间外的标记直接丢弃——宁可少一个章节，也不要一个会把进度条拖到别处的坐标。

## 接线

### 身份：`videoPath` = 这条标题自己的 `.mpls` 绝对路径

用真实存在的文件而不是虚构的 `bd://` 串做身份，是为了让下游所有「这文件还在不在」（`isLocalVideoResourceMissing` 用 `File.exists`）、「这路径被谁引用着」（`referencedLocalVideoPaths`）的判据**原样可用**，不需要为 BD 另开一套。

### 导入：`fushi/lib/src/media/source_library/source_library_scanner.dart`

- `planScanFromFileList` 新增 `detectBlurayDiscs`，认盘走纯函数 `planBlurayDiscRoots`（判据：至少有一条 `BDMV/PLAYLIST/*.mpls`）。规划层不碰文件系统——同一条扫描会对上万个路径调用它。
- **盘一旦被认出来，它 `BDMV` 下的所有文件都从散装视频里摘掉**（含 `BACKUP/`）。与 `.mokuro` 的让位规则同一取舍：manifest 认领了的文件不再被更低层的分类器重复消费。
- `_importBlurayDiscs` 与 m3u8 清单导入**完全同构**（一张盘 = 一个 `playlist` 合集，一条标题 = 一行 `VideoBooks`），所以幂等性、重扫对齐（`reconcileSplitPlaylist`）、删除墓碑守卫（BUG-1739）直接复用那套。
- **只在本地来源开**：盘内播放列表要随机读 `PLAYLIST`/`CLIPINF`，播放要拿到 `STREAM` 下的本地路径，网络来源两样都给不了。关掉时 m2ts 退回散装视频，与今天的行为一致。

拖拽一个盘目录进视频页走的是「目录 → 登记为来源 → 扫描」，所以**不需要单独接线**。

### 播放：`fushi/lib/src/media/video/video_player_controller.dart`

在 `load()` 里统一解析，不放页面里——这样外部打开、画质重载这些别的入口一起覆盖到。`_videoPath` 设成**第一段 m2ts** 而不是 mpls：吃它的是内嵌字幕抽取、制卡裁剪这些 ffmpeg 链路，它们要的是一段真实码流。

解析不出来（盘坏了/被删了一半）时原样透传，让 libmpv 的真实错误经 `onPlaybackError`（BUG-2441 的通道）浮上来，而不是在这里编一个更像样但不真的理由。

### 规格：`fushi/lib/src/media/video/video_specs_service.dart`

`.mpls` 走 `probeBlurayPlaylistFacts`，绕开注入的 ffprobe 入口。时长是**各段之和**（ffprobe 探任一段都只能给出那一段的时长），编码名用 ffprobe 的拼写（`h264` / `truehd` / `hdmv_pgs_subtitle`）好让下游的映射表原样查得到，文件大小是引用到的 m2ts 之和。

**宽度不猜**：`video_format` 只编码扫描格式，而 BD 规范允许 1080 行同时对应 1920 与 1440（MPEG-2/VC-1 的变形宽高比）。展示层对「有高度没宽度」已有兜底（`video_specs_display.dart` 两个都非空才显示像素对）。

### 封面：`packages/fushi_engine/lib/media/video/video_cover_extractor.dart`

`.mpls` 换成它引用的第一段 m2ts 再走原路。与 BUG-1564 的 m3u8 拒收在同一层收口，区别是这里有真码流可用，所以是**改道**不是拒收。

### 删除护栏：`packages/fushi_engine/lib/media/video/video_local_files.dart`

`localVideoFileCandidates` 对蓝光标题**一条候选都不给**。`.mpls` 是真实文件，但不是「这一条的原始文件」——它是盘结构的一部分，删掉它等于把盘拆坏（码流还在 `STREAM/` 下，盘却再也说不出该怎么播），而且一张盘上多条标题还共用同一批码流。删除确认框据此连「同时删除本地文件」的勾选框都不会摆出来。

## 测试（67 条，全绿）

| 文件 | 测什么 |
|---|---|
| `bluray_playlist_test.dart` | MPLS/CLPI 字节层：片段序列、多角度块、章节换算、流属性、坏输入 |
| `bluray_source_test.dart` | 两种播放形态的选择、EDL 域语义、长度前缀转义 |
| `bluray_disc_test.dart` | 六步筛选链逐条、盘根反推、META 标题 |
| `bluray_disc_io_test.dart` | 真实磁盘上铺一张最小的盘，走完整条 IO 链 |
| `bluray_wiring_test.dart` | 扫描规划摘盘、删除护栏、规格转换 |

夹具（`bluray_fixture.dart`）手工拼字节而不是塞一份真盘文件进仓：MPLS 没有可公开分发的样本，而合成的好处是每个字段都能单独拨动——「IN 不从零起跳」「多角度」「章节落在第二段上」这些情形在随便一张真盘上不一定同时出现。

**夹具与解析器共用同一套偏移假设，所以单测结构上发现不了偏移错**——那一层保障由与 libbluray 的逐字段比对提供（见上）。

## 已知限制（合并时定案）

- **`edl://` 拼接形态下制卡裁剪 / 字幕自动对轴不可用**：这两条链路拿 `videoPath` 交给
  ffmpeg 按播放位置裁，而播放位置在拼接后的虚拟时间轴上；只有单段整段用满（形态 1）
  时第一段 m2ts 的时间轴才与之相等。拼接形态下 `videoPath` 保持为 `.mpls`，ffmpeg 开
  不了它、以看得见的失败收场，而不是静默制出别的句子的卡。要支持需把播放位置按段
  映射回「片段 + 片段内偏移」再裁。
- **合集名按盘根去重**：盘名（无 META 时即目录名，`DISC1` / `Vol.1` 极常见）撞上属于
  别的盘的合集时改用「盘名 (上级目录名)」再加序号（`blurayCollectionNameCandidates`），
  否则 `S1/DISC1` 与 `S2/DISC1` 会互相吞成员、重扫来回翻转。

## 未验证项（如实记录）

- **没有在真盘上跑过**：本机与仓库里都没有 BDMV 素材，全部验证是合成盘 + 上游源码比对。以下几条尤其需要真盘确认：
  - `edl://` 多段拼接在五端 libmpv 上的实际播放、seek 与时长（EDL 的域语义已按 mpv 源码推定，但没有回放验证）；
  - PGS 字幕在 BD 上走 `selectEmbeddedGraphicTrack` 的实际表现（本仓字幕统一走自绘 overlay，内封**文本**轨靠 ffmpeg 抽取，BD 是位图 PGS，只能交给 libmpv 自绘）；
  - 真盘上筛选链的命中率（诱饵播放列表、seamless branching 的多角度盘）。
- **加密盘不支持**：AACS/BD+ 未解密的原盘读不出 MPLS。随包 libmpv 里 libbluray 的 AACS/BD+ 是 stub，实际解密要外部 `libaacs` + KEYDB，不随包。本功能只面向已解密/已 remux 的 `BDMV` 目录树。
- **ISO 镜像不支持**：需要 UDF 文件系统解析 + 一层能按 Range 供流的中继才能喂给内核。形态上可行（仓里已有 `YoutubeRangeRelay` 这种 loopback 分块中继的范式），但不在本次范围。
- **BD-J 菜单不支持**：带 Java 菜单的盘只能按标题列表播，没有交互菜单。这是刻意的——本仓要的是「拿来看电影或 MV」，不是还原碟机。
- **无头服务端（`fushi_server`）没接**：它的 `library_scanner.dart` 是另一套扫描，且服务端把视频按 HTTP 流发出去，而 EDL 拼接是客户端侧的事。解析层放在 `fushi_engine` 里就是为了将来要接时不必搬家。
- **iOS 未验证**：解析层是纯 Dart 不受影响，但 iOS 上用户能不能拿到一个 BDMV 目录的可读路径（沙盒 + 文件选择器）没有实测。
