## BUG-2200 · 导出的视频片段 moov 在文件末尾，QQ 等 IM 判无法播放
- **报告**：2026-09-07（用户：wrds）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/media/video/video_clip_exporter.dart:399`（修复前的 `buildFfmpegVideoClipExportArgs` 尾部，整条 copy 命令里一个 `-movflags` 都没有）
- **[x] ① 已修复** — 抽出共用纯函数 `buildClipFaststartArgs`，copy 与 reencode 两条路径统一按输出容器给 `-movflags +faststart`
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_clip_exporter_test.dart`：`buildClipFaststartArgs` 容器门控 + `copy args put moov up front for mp4 output` + `copy args omit -movflags for non-mp4 containers`
- **备注**：

### 现象

用户从视频页导出片段（`K-ON_-_S01E14_002018_426-002022_429.mp4`，4.0 秒 / 586 KB），本地播放器正常，发到 QQ 里播不了。

### 根因

`exportVideoClip` 有两条路径：

- **快路径 `-c copy`**（`buildFfmpegVideoClipExportArgs`）—— h264/hevc + aac 源直接命中，**绝大多数导出走这条**；
- **兜底重编码**（`buildFfmpegVideoClipReencodeArgs`）—— 只在源编码装不进 mp4 时才跑。

`-movflags +faststart` 只写在**重编码**那条上（连它的 doc 注释都写着「moov 前移便于边下边播」），copy 路径漏了。于是实际产出的片段：

```
top-level box 顺序: ftyp free mdat moov      ← moov 在文件末尾
```

mp4 muxer 默认把 `moov`（轨道索引 + 解码参数）写在 `mdat` 之后。本地整文件播放的播放器（mpv / PotPlayer / ffmpeg 自己）读到尾巴才拿索引，**看不出任何区别**——「本地能播、发出去播不了」就是这个形状的指纹，与 BUG-2011 的「mpv 自算时长所以看不出章节轨」同型。而边下边播 / 接收端预览的场景先读文件头，读不到轨道信息就直接判「无法播放」。

### 修复

```dart
List<String> buildClipFaststartArgs(String outputPath)  // .mp4/.m4v/.mov → ['-movflags', '+faststart']
```

两条路径共用（唯一真相源），重编码路径原来硬编码的那两个参数也改成走它。

按扩展名门控是必需的：`-movflags` 是 mov/mp4 muxer 的**私有选项**，给 matroska 之类的输出会 `Option movflags not found` 硬失败。当前 `exportVideoClip` 输出恒 `.mp4`，这层门控是留给纯函数被别的容器调用时的安全边界（`buildFfmpegVideoClipExportArgs` 的既有测试就用 `.mkv` 输出调它）。

### 同一次排查里量到、但未动的两件事

都在同一个产物上验过，与本 bug 分开记：

1. **视频轨 edit list 越界 83ms**。`elst = [(83, -1), (4004, 2002)]`：先一段 83ms 空 edit（`media_time = -1`），再从 media 2002 起播 4004ms，而 `mdhd.duration` 只有 96096 —— 第二段跑过媒体末尾 2002 个时间单位（83ms）。2002/24000 = 83.4ms 正是 `has_b_frames: 2` 的重排延迟。尊重 edit list 的播放器开头会有 83ms 空白。**未修**：它是 ffmpeg 对「输入 start_time 非 0 + B 帧重排」的标准产物，且 `-avoid_negative_ts make_zero` 在 copy 下会吃掉 GOP trim（BUG-2011 ②），没有不伤及既有行为的改法；影响是 83ms 的观感，不是不可播。
2. **tx3g 软字幕轨**。片段带一条 `mov_text` 字幕流（这是 `soft-subtitle muxing` 的既有功能）。部分移动端播放器对 tx3g 支持很差。**未修**：需要先确认 QQ 是否真卡在这一条，不能凭猜把用户要的软字幕砍掉。

### 验证

- `flutter test test/media/video/video_clip_exporter_test.dart --no-pub`
- 手工比对：修复前后各跑一次 ffmpeg 命令，解 top-level box 顺序应从 `ftyp free mdat moov` 变成 `ftyp moov free mdat`。
