## BUG-2202 · 内封 tx3g 字幕轨让导出的片段在 QQ 等 IM 里整个不可播
- **报告**：2026-09-07（用户：wrds）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/media/video/video_clip_exporter.dart:392`（`-c:s mov_text` 把字幕封成 tx3g 轨）
- **[x] ① 已修复（不可播这一条）** — `resolveClipSubtitleCodec` 对 mp4 系返回 null，导出的片段不再带 tx3g 轨，到处能播。**字幕以硬字幕形式回来这一半还没接线**（见下「当前进度」），需要 CI 先重编一版带 `overlay` 的 ffmpeg-min
- **[x] ② 已加自动化测试** — `video_clip_subtitle_burn_test.dart`（24 条）+ `video_clip_subtitle_image_test.dart`（8 条）+ 导出链路 `mp4 output gets no subtitle track at all`；四个相关测试文件共 90 条全绿
- **备注**：与 [BUG-2200](BUG-2200-clip-export-moov-at-tail-qq-cannot-play.md) 同一次用户报告拆出来的两条独立缺陷。2200（moov 在文件末尾）已修，但**不足以**让文件在 QQ 里播放。

### 现象

用户导出的片段（`K-ON_-_S01E14_002018_426-002022_429.mp4`，4.0 秒 / 586 KB，h264 High@4.0 + AAC LC）本地播放器正常，发到 QQ 里播不了。

### 二分定位（用户在真 QQ 上逐个验的）

在同一份源上做变体，**只差一个变量**：

| 变体 | moov 前置 | tx3g 字幕轨 | QQ |
|---|---|---|---|
| 原始导出 | ✗ | ✓ | ✗ |
| `qqtest1` | ✓ | ✓ | **✗** |
| `qqtest2` | ✓ | ✗ | **✓** |
| `qqtest3`（全重编码无字幕） | ✓ | ✗ | ✓ |

1 与 2 只差字幕轨 ⇒ **根因是 tx3g 轨**，`+faststart`（BUG-2200）单独不够。

又试了两条「保住内封」的补丁，**都不行**：

| 变体 | 改动（字节层面，ffmpeg 的 `-disposition` / `-enc_time_base` 实测对 mov_text 轨完全无效） | QQ |
|---|---|---|
| `qqtest4` | 字幕轨 `tkhd.flags` `000003` → `000000`（轨道 disabled） | ✗ |
| `qqtest5` | 字幕轨 `hdlr.handler_type` `sbtl` → 规范的 `text` | ✗ |

两个补丁文件都验过码流没坏（`ffprobe -count_frames`：96 视频帧 + 189 音频帧，与未改动版一致）。

结论：QQ 就是不接受这条轨。而且**即便它能播，QQ 也不会渲染 tx3g** —— 内封字幕在「导出→分享」这个主场景里是纯负资产：既让文件播不了，播得了也看不见字。

### 修法：烧成硬字幕，走 `overlay` 而不是 libass

用户选定烧录（硬字幕）。两条路线里选了 `overlay`：

- `overlay` 是 ffmpeg **内建** filter，五个平台**零新增原生依赖**，`ffmpeg-min` 的构建脚本只需在 `FILTERS` 白名单里多一个词。
- libass 的 `subtitles` filter 要拖进 libass + freetype + fribidi + fontconfig 四个库，而 macOS 自 BUG-1443 起不能用 brew 的动态库，得把整条依赖链从源码静态编一遍；而且渲染的是 SRT 默认样式，**没有假名注音**，跟用户在播放器里看到的字幕不是一回事。

布局全在 Dart 侧算完（渲染成与视频**同分辨率**的全画幅 RGBA PNG，`overlay` 到 `0:0`），所以 filter 图里零布局逻辑。这也延续了 `video_clip_subtitle.dart` 既有的设计哲学：字幕真相源是播放器内存里的 cue，导出的字幕恰好是用户屏幕上看到的那条。

**实测确认只需要 `overlay` 一个词**：`ffmpeg -v verbose` 解图，这条链真正实例化的只有 `overlay` + ffmpeg 为 `rgba→yuva420p` 自动插入的 `scale`（白名单里本来就有），连 `format` 都用不上。

已验证可用的 filter 图（用真实文件跑通，1920×1080 / 96 帧解码干净）：

```
[0:v][1:v]overlay=0:0:enable='between(t,0.083,1.447)'[vb0];
[vb0][2:v]overlay=0:0:enable='between(t,1.547,3.867)'[vout]
```

### 当前进度

已落地：
- `tool/ffmpeg-min/build-ffmpeg-min.sh`：`FILTERS` 加 `overlay`。
- `video_clip_subtitle_burn.dart`：能力探测（`ffmpeg -filters` 解析，两种 flag 列宽都吃）、画面尺寸解析、filter 图与输入段拼装、可烧性门控。全纯函数。
- `video_clip_subtitle_image.dart`：`dart:ui` 把一条 cue 渲染成与视频同分辨率的全画幅透明 PNG，字号/底距/投影按 `画面高 / 屏幕视频区高` 换算，复用屏幕上那套 `VideoSubtitleStyle`——于是「字幕占画面的比例」在屏幕和导出件里一致。
- `resolveClipSubtitleCodec` 对 mp4 系返回 null：**不再封 tx3g**，导出的片段立刻到处能播。这里没有加任何新分支——调用方早就有「容器封不下文本字幕 → 退回纯视频音频导出」的降级链，改返回值就够了。

还缺（下一批）：
- 把渲染器接进 `exportVideoClip`：探到 `overlay` 就渲染 cue → 拼 `-filter_complex` → 走重编码路径烧录；探不到就维持现在的无字幕导出。这一步要把导出入口从「SRT 文本」换成「cue（带时间轴）」，会动到 `soft-subtitle muxing` 那组既有测试。
- CI 重编一版带 `overlay` 的 `ffmpeg-min` 二进制（Windows/macOS/Linux），移动端自编的 ffmpeg-kit 同理。在新二进制到位前 `ffmpegCanBurnClipSubtitles` 恒为 false，行为就是现在这样：片段到处能播，但没有字幕。

### 未动的一件事

视频轨 edit list 越界 83ms（`elst = [(83,-1), (4004,2002)]`，第二段跑过媒体末尾 83ms，来自 `has_b_frames: 2` 的重排延迟）。ffmpeg 的标准产物，影响是尊重 edit list 的播放器开头有 83ms 空白，不是不可播；改它会撞上 BUG-2011 ②「`make_zero` 在 copy 下吃掉 GOP trim」。记录在此，不在本 bug 范围。
