## BUG-5598 · video-network-volume-background-reads
- **报告**：2026-11-27（用户：「陰の実力者播放不动」，安装版 Windows，片源在 rclone 挂的夸克网盘 Z:）
- **真实性**：✅ 真。`video_diag_log` 里播放几秒后 `cache=0.0s cache-speed=85 paused-for-cache=true`、`published=0`；OpenList 日志里夸克 CDN 连续 `wsarecv: forcibly closed`、32 MB 分片 5～16 s。主因在外部：夸克单连接限速 + 断连，带宽（实测单连接约 0.9～7.6 MB/s 波动）只比这片的码率（HEVC 10bit + FLAC，约 0.85 MB/s）高一点。Fushi 在同一条带宽上还额外读：
  - 进度条缩略图取帧 `OffscreenVideoFrameGrabber.grab`（`fushi/lib/src/media/video/video_thumbnail_preview_controller.dart`）：每格 ffmpeg 都 seek 到新位置，rclone 随之从那里另开一路下载并带 128 MB 预读；`error_log` 里 21:47 / 21:51 多条 `extractVideoFrameViaFfmpeg ... ffmpeg timed out`。
  - 下一集内封字幕后台预热 `prewarmEmbeddedSubtitleCache(background: true)`（`packages/fushi_engine/lib/media/video/video_subtitle_source.dart`）：播第 20 集时 OpenList 收到 S2 第 01 集的读取。原有的「同盘排队」只防机械盘磁头争用，网络卷上抢的是带宽，排队躲不开正在播的流。
- **[x] ① 已修复** — 新增 `isRemoteMediaVolume`（`packages/fushi_engine/lib/platform/media_disk_identity.dart`：Windows UNC / `DRIVE_REMOTE` / WinFsp `FUSE*`/`rclone` 文件系统名；Linux `stat -f %T`；macOS `mount` 最长挂载点类型；判不出按本机盘）。网络卷上取帧器判为不可用（只显时间戳），下一集预热直接放弃；当前集的字幕抽取不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/embedded_subtitle_disk_queue_test.dart`（网络卷上后台预热不读文件、前台照常；三平台判据纯函数）、`fushi/test/media/video/video_thumbnail_preview_test.dart`（网络卷上不起 ffmpeg、`isUnavailable` 为真）。
- **备注**：用户侧同时给 rclone 挂载加了 `--vfs-read-chunk-streams 4`（`D:\OpenList\autostart.ps1`，4 路并行实测约为单路 3.5 倍）。未做、待拍板：`VideoContentFullHashUpgrader` 会把网络卷上每个新文件整份读一遍算 sha256（用户库 Z: 上 242 个文件 11-23 前已全部整读过），网络卷上是否只留 `osh:` 采样指纹会影响搬家识别，需用户定。
