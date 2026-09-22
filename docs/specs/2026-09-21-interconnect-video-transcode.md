# 互联视频弱网可用：host 端按需转码 + 自适应画质

日期：2026-09-21 · 状态：已落地

## 0. 一句话

互联 host 一直只会「原文件 Range 直传」，人在外面用手机网络看一部 8 Mbps 的片子就只能
卡着等缓冲。本批让 host 按对端选的画质档把视频切段转码成 HLS 下发，并让 client 在
「自动」档下按实测网况升降画质。

## 1. 用户诉求（2026-09-21）

> 话说 fushi 互联的视频要不要加个自动压码率画质啥的，在外面手机网络不好的情况下也能用

追加：

> 还要做成自适应网速，还有不同档位切换画面

## 2. 决定设计的硬事实（实测，非推理）

### 2.1 随包 ffmpeg 没有 HLS muxer

`third_party/ffmpeg-min/windows/ffmpeg.exe -muxers` 首版实测只有 `mov` 与 `mp4`（视频类），
**没有 `mpegts`、`hls`、`dash`、`segment`**；编码器侧 `libx264` 与 `aac` 都在，滤镜有
`scale`，协议有 `pipe`。

→ 走不了 ffmpeg 自带的 HLS 输出。但 playlist 不过是一段文本：**playlist 由 Dart 生成，
分段一段一个短命 ffmpeg 出**。首版分段用 `mp4` muxer 的 fragmented 模式（零二进制改动）；
2026-09-22（BUG-2630 第二段，见 2.6）改成 MPEG-TS，ffmpeg-min 配方补编 `mpegts` muxer。

### 2.2 为什么不是「一条不可 Range 的渐进流」

另一条路是 host 直出一条 fMP4 长流。它要求播放器侧：拦截 seek 改成「带 startMs 重新
取流」、伪造时长（转码流 mpv 报 duration 为 0，进度条几何是 `duration * slider`，为 0
时整条不可用）、并且**改 vendored 的 media_kit fork**——进度条在
`third_party/media_kit_video/.../material.dart` 里直发 `player.seek`，不经
`VideoPlayerController`。

HLS 则让 libmpv 原生接管：进度条、总时长、seek 全部照常工作，播放页几乎零改动。
同样的用户价值，代价差一个数量级。

### 2.3 （首版 fMP4）ffmpeg 的 fMP4 muxer 必然把 `tfdt` 归零

每段一个独立 ffmpeg（`-ss n*6 -to (n+1)*6`）转出来的 fMP4 分段，`moof/traf/tfdt` 的
baseMediaDecodeTime **恒为 0**。`-copyts`、`-output_ts_offset`、
`-avoid_negative_ts disabled` 三种组合逐一实测，都改不了它。

后果是所有分段的时间戳都落在 `0..段长` 上互相重叠。实测 3×6 秒的 playlist：

- 分段各自单独解码都是完整的 180 帧；
- 串成 playlist 后只有 **300 帧**进得了解码器（应为 540），后面的段因时间戳回退被整片丢掉；
- demuxer 会打 `timestamp discontinuity ... new offset=` 自行补偿，但那是容错不是契约。

首版的解法是分段发出去之前按各 track 自己的 timescale 给 `tfdt` 加上该段的绝对偏移
（`fmp4_rewriter.dart`，已随 2.6 整个删除）。**mpegts muxer 认 `-output_ts_offset`**，
TS 分段不需要任何字节层改写。

### 2.4 （首版 fMP4）分段不能自带 `moov`

fMP4 分段若保留 `ftyp`+`moov`，播放器会报 `Found duplicated MOOV Atom`，并把后续分段拆成
**另一组流**（ffprobe 实测列出两套 h264+aac）。所以首版把分段剥成纯 `moof`+`mdat`，
track 定义由一个共用的 `EXT-X-MAP` 初始化段给出。TS 分段自描述，没有这层结构。

### 2.6 FFmpeg 6.1 客户端上 fMP4 HLS 一 seek 就坏（BUG-2630 第二段，2026-09-22）

用户报「切画质档就播不了」。分段端点补上扩展名（3.1）后，从 0 起播五端都好了，但
**只要 seek（含恢复上次位置）**，iOS 模拟器 / macOS / Android 立刻黑屏、位置跳到片尾。
Windows 客户端没事。取证链（全部真机 / 真 libmpv，非推理）：

- Android / macOS 的 mpv 日志：seek 后 hls demuxer 重新拉了 init + 目标段，但 mov
  demuxer **没有**报「duplicated MOOV」（没把重新喂进来的 init 当 init 解析），随后
  `[ffmpeg] NULL: Invalid NAL unit size (…) / missing picture in access unit` 成串。
- 同一批产物抓成静态文件、A/B 交替两份不同编码、活 host 明文直连、活 host 经中继——
  用 Windows 随包 libmpv（python-mpv 加载 `libmpv-2.dll`）做「打开 → seek 到 15 s」，
  **全部正常**（seek 后 mov 报「duplicated MOOV，skipped」并继续）。所以分段格式、
  host 的动态出段、中继都无罪。
- 差异只剩 FFmpeg 版本：Windows 随包 libmpv 是 2026-08 master 构建，Apple / Android
  是 6.1.6。对比源码：master 的 `mov_read_packet` 开头有一段「`s->pb->pos == 0` 就丢弃
  fragment index / 样本游标 / index entries 并重新 `mov_switch_root`」，专门配合
  `hls_read_seek` 里的 `pb->pos = 0`（源码注释原话：「to let the mpegts demuxer know
  we've seeked」）；**6.1 的 mov.c 没有这段**，`mov_switch_root` 沿 seek 前记下的绝对
  `next_root_atom` 向前跳过新数据再当 moof 解析，整条流从第一个样本起就错位。6.1 的
  hls.c 连 `EXT-X-DISCONTINUITY` 都不处理（子 demuxer 只在 `hls_read_header` 建一次），
  fMP4 在 6.1 客户端上无路可走。

→ 分段改成 **MPEG-TS**：mpegts demuxer 本就是那次 `pos = 0` 重置的设计对象，也是
Jellyfin / Emby 给 mpv 客户端的标准分段形态；`-output_ts_offset` 直接给出绝对时间轴，
`fmp4_rewriter.dart` 与 `hlsinit.mp4` 端点整个删除。ffmpeg-min 配方（`tool/ffmpeg-min/
build-ffmpeg-min.sh`）`MUXERS` 补 `mpegts`（h264 进 TS 的 Annex B 转换靠已编入的
`h264_mp4toannexb` bsf），fork 上 `ffmpeg-min.yml` 重编后 vendor 到
`third_party/ffmpeg-min/{windows,macos}`；smoke-test 加了与 `buildTranscodeSegmentArgs`
同形状的 TS 探针。

**但 TS 分段还有一条硬约束：段编码不能开 B 帧（`-bf 0`）。** `-output_ts_offset` 平移
的是 PTS 和 **DTS** 两者，而有 B 帧时段首关键帧的 `DTS = PTS − 重排延迟`；第 0 段又会
被 `avoid_negative_ts`（mpegts muxer 没有 `AVFMT_TS_NEGATIVE`，默认 MAKE_NON_NEGATIVE）
整体抬成非负，其余段偏移够大不触发。hls demuxer 判 seek 落点用的**正是 DTS**——
`first_timestamp`（第 0 段首包 DTS）加 playlist 里 `EXTINF` 的累计，凡 DTS 比它小的包
全部丢弃——于是段 n 唯一的关键帧恰好早了一个重排延迟，**整段被丢、落到段 n+1**，目标
落在最后一段时直接 EOF。实测（随包 ffmpeg，854p / 1.5 Mbps / 6 秒段）重排延迟
83.422 ms，段 1 / 2 的关键帧 DTS 5.916578 / 11.916578 对名义 6.000000 / 12.000000；
真 mpv 上 seek 7 s 落到 11.94 s、seek 13 s 播不出来。关掉 B 帧后 DTS == PTS == 名义
起点，落点恢复精确。

这不是调参绕过：每段是**独立编码**、起点由 `-output_ts_offset` 钉死在 PTS 域，而 HLS
的分段索引是 DTS 域的，两域必须重合段边界才自洽。代价是少了 B 帧的压缩收益，但
`-g 600` 本来就是一段一个关键帧，而弱网上「seek 能用」比那几个百分点重要得多。
验这条要看**段首视频关键帧的 DTS**，不是 `start_time`、更不是 PTS——单段 `start_time`
在坏的形态下看上去仍「≈ 偏移」。守卫：`live_transcode_test.dart` 钉 `-bf 0`，
`tool/ffmpeg-min/smoke-test.sh` 出两段真 TS 验 DTS 落点，itest 的 seek 断言带上界。

### 2.5 「下载速度」不能当带宽富余的判据

播放器按需下载：缓冲填满后就不再全速拉流，稳态下 `cache-speed` ≈ 媒体码率，看上去
永远「刚好够用」。升档判据因此用 `demuxer-cache-duration`（缓冲**深度**）——它才如实
反映「拉得比放得快」。

## 3. 架构

### 3.1 host 端（`packages/fushi_engine`）

| 端点 | 作用 |
|---|---|
| `GET …/<id>/streamurl?maxWidth=&maxBitrate=` | 协商：认档就回 HLS playlist URL，不认就回老的直传 URL |
| `GET …/<id>/hls.m3u8?token=` | VOD playlist（每段 `EXTINF`，段 URI 用相对形式；无 `EXT-X-MAP`） |
| `GET …/<id>/hlsseg.ts?token=&n=` | 第 n 段（MPEG-TS，ffmpeg 产物原样，`-output_ts_offset` 已平移时间轴） |

- **档位绑在 token 上，不从 query 取**：后两条路径（playlist / 分段）豁免 Basic 鉴权（播放器取 playlist /
  分段都是裸 GET），让分段端点自带编码参数就等于把「在 host 上起一个任意参数
  的 ffmpeg」敞开给 URL 持有者。签发侧（`/streamurl`，要 Basic）定档。
- **两条路径的扩展名是协议的一部分**（BUG-2630）：FFmpeg 6.1.3+ / 7.1.1+ / 8.0（2025 年安全加固回移到维护分支；6.1.0～6.1.2 与 7.0.x / 7.1.0 没有这道门）
  的 hls demuxer 对 playlist 里每个分段 URL 先查 `allowed_segment_extensions` 白名单
  （扩展名取 query 之前的路径尾，`ff_match_url_ext`），不在名单上直接 `Invalid data found`。
  首版分段端点是裸 `hlsseg?token=`，随包 libmpv 四端（Android / iOS / macOS 6.1.6，
  Windows master 构建；Linux 走系统库、发行版 6.1.1 / 7.0.x 不复现）一个都不肯取分段，
  「切画质档就黑屏」。现在分段是
  `hlsseg.ts`（同时在白名单与 mpegts 分段表里），守卫
  `fushi/test/sync/fushi_sync_server_hls_segment_ext_guard_test.dart` 把 hls.c 的判据移植成
  Dart 钉住 host 签发的每个 URI。分段为什么是 TS 不是 fMP4 见 2.6。
- **一段一个短命进程**：没有会话表、没有临时文件、没有长跑进程要清理；seek 到哪就转哪。
  并发上限 3（`kMaxConcurrentTranscodes`）——不设闸门的话一次 seek 能同时点起七八个
  ffmpeg，CPU 被瓜分之后每一段都变慢。
- **四道闸门**缺一不可：档位有效 ∧ 用户开关 ∧ 本机能 exec ffmpeg ∧ 探得出时长。
  任一不成立就**静默退回原文件直传**，不是报错。

### 3.2 能力协商

- `/api/capabilities` 的 `liveLibrary.videoTranscode`：老 host 无此字段 → client 不显示
  画质档，行为与从前一致。
- `/streamurl` 响应另带 `transcodeAvailable`（这台 host 支不支持）与 `transcoded`
  （当次有没有转）。分开报是必要的：client 起播默认走自动档（局域网里就是不转码），
  若只回 `transcoded: false`，它永远无从得知画质档可不可选。
- 转码流一律报 `streamIsOriginalContainer: false`（BUG-2590 的既有语义：容器换了，
  内嵌字幕不能再指望 libmpv 自绘，要走 `/subtitle` 外挂下发）。

### 3.3 移动端 host 如实报不支持

判据是「能不能 exec 一个 ffmpeg 子进程」而不是「有没有 ffmpeg」：移动端装的是进程内的
ffmpeg-kit，只能跑完一条命令再交结果，**没有可接管的 stdout 管道**；iOS 更是从根上禁
子进程。所以 Android / iOS 当 host 时能力位恒 false。

### 3.4 client 画质档

`InterconnectSyncBackend` 实现既有的 `RemoteVideoQualityLimit`，于是播放页的画质菜单
（`video_fushi/quality.part.dart` 的媒体服务器分支）**零 UI 改动**直接可用：列出
「自动 + 5 档」，切换走既有的「停旧会话 → 重新协商 → 回到原位置 → OSD」。

档位比 Jellyfin/Emby 那套（最高 20 Mbps）整体更低——那边的典型场景是家里电视盒子拉
局域网服务器，这边要解决的恰恰是手机网络。偏好键也**分开存**
（`video_interconnect_quality_preset`）：两边阶梯不同，共用一个下标会让同一个数字在
两处指向不同画质。

### 3.5 「自动」档的自适应

起点靠「这条连接在不在局域网里」（`interconnect_video_quality.dart`）：在家原画，在外
先给一个能跑的档。不靠探测起步，是因为探测要先卡一阵子才学得到东西，而第一分钟恰恰是
用户最容易直接退出去的那一分钟。CGNAT（100.64/10，Tailscale 之类）算「在外面」——流量
还是走对端上行。

之后交给 `AdaptiveQualityController`（纯逻辑、按拍可测）：

| | 判据 | 理由 |
|---|---|---|
| 降档 | 20 秒窗口内卡满 3 拍 | 降档要灵敏 |
| 升档 | 连续 90 秒没卡 **且** 缓冲深度持续 ≥25 秒 | 升档要迟钝；判错方向的代价不对称 |
| 冷却 | 换档后 30 秒不再评估 | 一次网络抖动不该连降三档 |
| 上界 | 受管最高档，**不回原画** | 原画码率由源文件说了算，撑不住过一次就别再试 |

自适应换的是「自动」策略下的**当前取值**，不动用户偏好——否则自动降档会把设置改成一个
具体档位，看起来设置自己会动，而且再也回不到自动。

## 4. 验证

### 4.1 端到端（真 host + 真 ffmpeg-min + ffprobe）

60 秒 720p 测试源（56.7 MB，≈7.5 Mbps），经真 `FushiSyncServer` 按 854×0.8 Mbps 档取流：

- 10 段全部 200，每段 ≈710 KB → **7.1 MB，压到原来的 1/8**；
- 抓下来的 HLS：`duration=60.000`、854×480@30fps、**1800 个包一个不丢**、pts 连续覆盖
  0→60、完整解码 1800 帧**零 discontinuity 警告零错误**；
- seek 到 5 / 23 / 41 / 57 秒分别落在段 0 / 3 / 6 / 9 的起点关键帧上。

### 4.2 自动化测试（66 条新增）

- `fushi/test/media/video/live_transcode_test.dart`：档位往返、分段划分、playlist
  生成（无 `EXT-X-MAP`）、ffmpeg 参数（`-f mpegts` + `-output_ts_offset`，不再有
  `-movflags`）。首版的 fMP4 剥头与 `tfdt` 平移用例随 `fmp4_rewriter.dart` 一起删除（2.6）。
- `fushi/test/sync/fushi_sync_server_transcode_test.dart`（15）：能力位随开关实时翻转、
  协商四道闸门、三条 HLS 端点、鉴权（缺/错 token、直传 token 点不动转码端点、跨视频
  token）。
- `fushi/test/sync/interconnect_adaptive_quality_test.dart`（19）：升降档判据按拍钉死、
  冷却、窗口滑动、上下界、局域网/公网/CGNAT 起点。
- `fushi/test/sync/interconnect_video_quality_client_test.dart`（12）：档位菜单可见性、
  三级优先（用户 > 自适应 > 起点）、档位表不变式。

另跑：全量 `flutter analyze` 零问题、53 条目录枚举型守卫（396 条）全过、i18n 完整性
30 条全过、设置 schema 守卫 36 条全过、既有视频流/token/客户端测试 125 条全过。

## 5. 明确没做的

- **转码流只有一条音轨**：host 协议已接受 `audioStreamIndex`（签发时定），但 client 侧
  的「切音轨触发重取流」没做。多音轨番剧在转码流下切不了日配/中配——这是转码的固有
  限制（Jellyfin 同样在转码时定死一条），留给后续。
- **真机双端未验证**：本批的端到端证据来自「真 host 服务 + 真 ffmpeg + ffprobe 校验
  产物」，没有在两台真设备之间跑过一次真实播放。自适应的升降档判据是按拍单测钉死的，
  但它在真实移动网络上的手感（会不会太灵敏/太迟钝）需要真机调。
- **host 侧转码上限**：没有加「host 只肯转到某档」的设置。client 的档位已经限定了上限，
  真需要时再加。
