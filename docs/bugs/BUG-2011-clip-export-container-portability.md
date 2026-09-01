## BUG-2011 · 视频片段导出产物只有 mpv 能播，进度条显示整集时长
- **报告**：2026-09-01（用户：）
- **真实性**：✅ 真 bug，三条独立根因叠在同一条导出链路上。用户样本
  `_2_2016_-_S02E13_000227_314-000232_736.mp4`（文件名声称 5.422 秒）实测：
  1. **进度条显示整集时长** — `fushi/lib/src/media/video/video_clip_exporter.dart`
     两个参数构建器都没给 `-map_chapters`，ffmpeg 默认等价 `-map_chapters 0`，把**源整集**
     的章节表原样搬进片段；mp4 muxer 为此建一条与最后一个章节等长的 chapter text track，
     `mvhd.duration` 被它拉满。样本解出：`MVHD duration=1274124 (1274.124s)`，
     `track 6 · HDLR handler=text · duration=1274.124s`，而媒体轨只有 10.7 秒。
     mpv 自己按媒体轨重算时长所以正常，读 `mvhd` 画进度条的播放器全部显示 21 分 14 秒。
  2. **产物播不了** — `exportVideoClipViaFfmpeg` 的决策模型是「跑 `-c copy`，**退出码非 0**
     才降级重编码」（`video_clip_exporter.dart` 的 `attempt()`）。可 `hev1` / 10-bit /
     FLAC 全都能成功封进 mp4、退出码 0，于是重编码兜底**永远不触发**，产物播不了却被判成功。
     样本流表：`Video: hevc (Main 10) (hev1) yuv420p10le` + `Audio: flac (fLaC)`（还是
     default 轨）+ aac ×2。`hev1`（参数集带内）Apple 生态 / 浏览器 / Windows Media
     Foundation 基本只认 `hvc1`；FLAC-in-mp4 系统解码器不认；10-bit 硬解路径大多不支持。
  3. **时长多一个 GOP** — copy 路径给了 `-avoid_negative_ts make_zero`。`-c copy` 下
     `-ss` 必然从请求点**之前**的关键帧起，那段前导本该由 mp4 edit list 表达成「播放时
     跳过」；`make_zero` 把这段负时间戳整体平移成正片内容。样本 5.422 秒的请求实际落成
     10.760 秒 = `27.314 + 5.422 - 关键帧 20.0` 的形状。
     60 秒合成源（关键帧 0/10/20/30/40/50）复现：`-ss 27.314 -t 5.422` → 实得 **12.76s**
     （= 27.314+5.422−20.0）；把 `-t` 挪到 `-i` 之后**同样** 12.76s（挪位置不是解法），
     去掉 `make_zero` 后得 **5.437s** 且 `ELST media_time=7.314s` 精确跳过前导。
- **[x] ① 已修复** — `fushi/lib/src/media/video/video_clip_exporter.dart`：
  - 新增 `ClipSourceCodecs` / `parseClipSourceCodecs()`（解析 `ffmpeg -i` 日志）与
    `ClipCodecPlan` / `resolveClipCodecPlan()` / `buildClipCodecArgs()`：**把「导出成功」的
    判据从「退出码 0」前移到「产物能不能被通用播放器播」**，按流编码逐条决定 copy 还是
    重编码。h264/hevc + 8-bit 才 copy；hevc copy 时改写 `-tag:v hvc1`；音频只有全部
    aac/mp3 才 copy，否则整体转 AAC。探测失败/解析不出一律退回 `ClipCodecPlan.fullCopy`，
    与加门控之前逐参数等价 —— 探测是优化判据，不是导出的前置条件。
  - 两条路径（copy 与重编码兜底）都加 `-map_chapters -1`。
  - `-avoid_negative_ts make_zero` 改为**只在视频重编码时**给：视频 copy 时把关键帧前导
    留给 edit list 表达；重编码时 accurate seek 精确切在请求点，归零无副作用。
  - 保留 `-map 0:a?`（BUG-345 的「不赌音轨语言」承诺不动），改为保证**每条**音轨都可播。
  - 实测（源=用户那个真实产物，请求 3.0 秒）：`MVHD 1272.124s → 3.087s`；chapter text
    track 消失；实际时长 `5.09s → 3.02s`；视频 `hevc 10bit/hev1 → h264 High/avc1/yuv420p`；
    音频 `flac+aac×2 → aac×3`。h264+aac 源的对照仍走 `-c copy`（MVHD 3.016s，速度不变）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_clip_exporter_test.dart`
  新增 group `source codec gating (BUG-2011)` 共 10 条，含：用**用户那份真实 `ffmpeg -i`
  日志**断言解析结果、10-bit HEVC + FLAC 必须全重编码、已通用可播的源保持 `-c copy` 快路径、
  8-bit HEVC 保持 copy 但改 `hvc1`、只有音频不可播时只转音频、`nv12` 不得被当成 12-bit、
  探测不可用时退回门控前行为、两个构建器恒带 `-map_chapters -1`、`-avoid_negative_ts`
  只在视频重编码时出现、探测调用在裁剪之前且不带 `-ss`。
  变异实测（三处根因各改回坏的样子，改完 sha256 对账回原状）：去掉 `-map_chapters -1`
  → 红 4 条（含专门守卫）；`-avoid_negative_ts` 改回无条件 → 红 3 条；把 8-bit 白名单换成
  「按名字尾巴猜位深」→ 精确红 `nv12` 那条。
- **备注**：`-map 0:a?` 带全部音轨是 BUG-345 的有意设计（多音轨番剧默认轨常不是 0，赌错
  会导出错语言），本次不动它；门控保证的是这些音轨条条可播，而不是砍到一条。
  同构的有声书片段导出 `fushi/lib/src/media/audiobook/audiobook_clip_export.dart`
  （文件头自述「镜像 `exportVideoClipViaFfmpeg`」）未在本轮排查范围内，若它也 `-c copy`
  且不丢章节，同样的三条根因可能成立 —— 留作后续单独核查。
