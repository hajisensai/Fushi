## BUG-3102 · 图形字幕整轨转文字抽轨按体积估总超时，慢盘上误杀仍在推进的 ffmpeg
- **报告**：2026-10-09（用户 + 开发者哈吉千歳：图形字幕「转为文字字幕」失败，日志
  `video.graphicSubtitleOcr.extract ffmpeg timed out; executable=D:\APP\Hibiki\ffmpeg.exe`，
  `#1 extractGraphicSubtitleTrackToSup` / `#2 _VideoSubtitle._generateSubtitleFromGraphicTrack`；同一时段
  `extractVideoFrameViaFfmpeg`（单帧抽取，固定 30 s）也报超时）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/graphic_subtitle_track_ocr.dart:31`（旧
  `graphicSubtitleExtractTimeout`）+ `:66`：整轨 `-c copy` 抽字幕要把整个容器读一遍，耗时只取决于磁盘吞吐，
  却给了一个按体积估的**总时长**预算 `60 s + 8 s/GB`（隐含 ≥125 MB/s 的吞吐假设）。USB 机械盘 / NAS / 播放中的
  libmpv 与缩略图预览等多个 ffmpeg 同时抢 IO 时（同时段单帧抽取都超时就是 IO 被挤满的旁证），读完一遍远超预算，
  进程一直在推进却在中途被 SIGKILL。
  - 排除项（逐一实测，本机捆绑的 `third_party/ffmpeg-min/windows/ffmpeg.exe` n7.1.5 对照
    `D:/ffmpeg/ffmpeg-2025-06-11-git-f019dd69f0-full_build`）：① **不缺组件**：精简版编入了 `sup` 与 `null`
    封装器、matroska / mpegts 解复用器；没有 PGS 解码器，但 `-c copy` 不需要——只多一行
    `Could not find codec parameters … (hdmv_pgs_subtitle): unspecified size` 警告，7.5 GB / 30 分钟 mkv 抽出的
    `.sup` 与完整版逐字节一致（36180 B，cmp 相同）；② **命令本身没卡**：已是 `-map 0:s:N -c copy -f sup`，不解码；
    ③ **不是等 stdin**：Windows 上 ffmpeg 对管道 stdin 用 PeekNamedPipe 非阻塞读，仍补了 `-nostdin`；
    ④ 页缓存热态下精简版 11.1 s 读完 7.5 GB，命令本身是快的。
  - 复现（`-readrate 1.5` 把读取限速成「慢盘」，2 分钟 / 60 MB mkv，捆绑精简 ffmpeg）：旧的固定预算 60 s →
    `rc=null after 0:01:00.21 (ffmpeg timed out)`，正是用户日志；新实现 → `rc=0 after 0:01:20.23`，期间 28 次进度推进。
- **[x] ① 已修复**（4869645cba）— 新增 `packages/fushi_engine/lib/media/video/ffmpeg_watched_run.dart`：长任务按**进度**判活——
  ffmpeg `-progress pipe:1` 的 `out_time_us` 连续 `stallTimeout`（抽轨用 90 s）不推进才算卡死强杀，一直推进就不设
  总时长上限；带取消信号（进度卡 ✕ / 退页强杀进程，不再在后台把整个文件读完）。`CliFfmpegBackend` /
  `BlurayFfmpegBackend` / 移动端 `KitFfmpegBackend`（统计回调 `Statistics.getTime()`）都实现 `FfmpegWatchedRunner`，
  捆绑 → PATH 回退与蓝光输入改写照旧。抽轨命令加一个同次读文件的 `-map 0:v:0? -map 0:s:N -c copy -f null -`
  伴随输出，让已处理时间跟着文件读取位置**连续**推进（只映射稀疏字幕流时长段无对白会几分钟不动，按进度判活会误判）；
  实测双输出与单输出耗时相同（11.0 s vs 11.1 s）。不支持观察式运行的后端（测试替身）退回旧总预算。
  卡死仍然真卡死时（实测：从没人写的 `pipe:0` 读）3 s 窗口内被判 `stalled` 杀掉，日志写明「no progress for Ns」。
- **[x] ② 已加自动化测试**（4869645cba）— `packages/fushi_engine/test/media/video/ffmpeg_watched_run_test.dart`（一直推进超过
  4 倍窗口不杀 / 进度停住被杀并带 stalled 标记 / 取消 / 失败原样带回 / CLI 前缀）；
  `fushi/test/media/video/graphic_subtitle_track_ocr_test.dart`（抽轨命令含进度伴随输出、观察式后端走进度判活且
  进度转给调用方、取消不报失败不留半截 `.sup`、入库精简 ffmpeg 真跑抽轨）。
- **备注**：同时段 `extractVideoFrameViaFfmpeg` 的超时是同一场 IO 争用的受害者（缩略图预览 / 制卡抽单帧，固定
  30 s），本修复把抽轨的 ffmpeg 改为可取消、离开页面即停，减少争用，但没改单帧抽取的预算——单帧是有界任务，
  固定预算本身合理。
