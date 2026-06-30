# 桌面精简 ffmpeg 编译流水线（~10MB，开箱即用）

> 状态：**v0 脚手架，需在真实构建机/CI 上迭代收敛**。本文档 + `tool/ffmpeg-min/build-ffmpeg-min.sh` + `.github/workflows/ffmpeg-min.yml` 是起点，不是已验证产物。

## 为什么

桌面 ffmpeg 调用走系统 PATH 上的 `ffmpeg`（未捆绑）；没装 ffmpeg 的电脑会丢内封字幕/cue 动图/制卡音频/封面（优雅降级，非崩溃）。现成静态 ffmpeg.exe 都 **~80–170MB**（含全部编解码器），太大。Hibiki 桌面其实只用到一小撮组件，自己 `configure` 精简编译可压到 **~10MB**，再放到 app 程序旁即被 `resolveFfmpegExecutable()` 优先选用（已实现，见 `hibiki/lib/src/media/video/ffmpeg_backend.dart`：HIBIKI_FFMPEG > 程序旁 ffmpeg > PATH）。

移动端不走本流水线：Android/iOS 已捆绑 `ffmpeg_kit_flutter_new_min`（见 `KitFfmpegBackend`）。

## Hibiki 桌面实际调用的 ffmpeg 命令（白名单依据）

| 功能 | 命令骨架 | 需要的组件 |
|---|---|---|
| 内封字幕枚举 | `ffmpeg -i in.mkv`（解析 stderr） | demux matroska/mov/mpegts |
| 内封字幕抽取 | `-i in -map 0:s:N out.{srt,ass,vtt}` | + 字幕 decoder(ass/subrip/mov_text/webvtt/text) + encoder(srt/ass/webvtt) + muxer |
| cue 动图 | `-ss -t -i in -filter_complex fps,scale,palettegen,paletteuse -loop 0 out.gif` | video decoder + filter(scale/fps/palettegen/paletteuse) + encoder gif + muxer gif |
| 句子音频 | `-ss -t -i in -vn -c:a aac out.aac` | audio decoder(opus/aac/ac3…) + swresample + encoder aac + muxer adts |
| 视频帧/封面 | `-i in -frames:v 1 -update 1 out.jpg` | video decoder + encoder mjpeg + muxer image2 |
| 片段导出（TODO-945） | `-loop 1 -i img.png -i clip.aac -c:v mjpeg -c:a aac -shortest out.mov` | encoder mjpeg+aac + **muxer mov**（容器需同时装视频+音频流）+ bsf aac_adtstoasc |

**只解码 + native gif/aac/mjpeg 编码 → 不需要 `--enable-gpl`（无 x264/x265）。** 走 LGPL，体积/许可更干净。

## configure 白名单（见 build 脚本，需调优）

demuxers / decoders / encoders / muxers / filters / parsers / bsfs / protocols 的精简集见
`tool/ffmpeg-min/build-ffmpeg-min.sh`。关键 `--disable-everything` + `--enable-small` 后逐项 `--enable-...`。

## 调优清单（真编 + 真视频迭代，收敛判据）

逐条在真实素材上跑通，失败就按提示补 enable：

- [ ] **能编过**：三平台 configure+make 无错（Windows 在 MSYS2 mingw64）。
- [ ] **内封字幕枚举**：`ffmpeg -i 真mkv` stderr 列出字幕流（缺 demuxer → 补）。
- [ ] **内封字幕抽取**：`-map 0:s:0 out.srt` 出非空 srt（ass→srt 需 ass decoder + subrip encoder；mov_text 同理）。
- [ ] **cue 动图**：filter_complex 出有效 gif（缺 filter/parser → "Unknown filter" / 解码失败）。
- [ ] **句子音频**：`-c:a aac out.aac` 出可播 aac（缺 aresample → "Resampling needed but..."；mp4 内 aac 需 bsf aac_adtstoasc）。
- [ ] **封面帧**：`-frames:v 1 out.jpg` 出图（缺 mjpeg encoder/image2 muxer → 补）。
- [ ] **片段导出**：`-loop 1 -i img.png -i clip.aac -c:v mjpeg -c:a aac -shortest out.mov` 出可播 .mov（缺 mov muxer → exit -22 EINVAL，BUG-460；adts/gif/image2/mjpeg 都装不了视频+音频双流）。有声书片段音频本身写 `.aac`（adts），不要写 `.m4a`（需不存在的 ipod/mov muxer）。
- [ ] **覆盖常见容器/编码**：mkv(h264/hevc/av1 + opus/aac/ac3 + ass/srt)、mp4(h264/aac/mov_text)、ts。各跑一遍四类命令。
- [ ] **体积** ≤ ~15MB；记录各平台实际大小。

> 漏组件的典型症状：`Unknown decoder/encoder/muxer/filter 'x'`、`Stream map matches no streams`、运行时某类文件静默失败。按症状回补对应 `--enable-*`。

## 集成（产物→app 旁）

1. CI（`ffmpeg-min.yml`，手动触发）产出 `ffmpeg-min-{linux-x64,macos,windows-x64}` 三个 artifact。
2. 收敛后接进 `release-desktop.yml`：下载对应平台 artifact，把 `ffmpeg(.exe)` 放进打包产物里 app 可执行文件**同目录**（Windows `…\Hibiki\ffmpeg.exe`；macOS `Hibiki.app/Contents/MacOS/ffmpeg`；Linux 同目录）。
3. 运行时 `resolveFfmpegExecutable()` 自动优先用它——代码已就绪，无需再改 Dart。

## 待办（本会话未做，需构建机）

- 真编三平台 + 跑调优清单收敛白名单（脚手架的 enable 列表是推断值，未编译验证）。
- 收敛后把版本/产物校验（哈希）固化，接进 release-desktop。
- macOS/Linux 是否也分发：同桌面策略（程序旁 ffmpeg）。
