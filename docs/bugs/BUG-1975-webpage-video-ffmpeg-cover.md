## BUG-1975 · 网页视频导入不应让 FFmpeg 抽 HTML 页面封面
- **报告**：2026-08-30（用户：）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/url_stream_video.dart:213` 的封面策略把除 YouTube 外的所有 HTTP(S) URL 都归为 `ffmpegFrame`，包括同文件已由 `isKnownWebPageVideoUrl` 判定为 HTML 播放页的 Bilibili / Netflix / Niconico 等地址；`video_import_dialog.dart` 随后把 HTML URL 交给 `extractVideoCover`，触发 FFmpeg `Invalid data found when processing input`。
- **[x] ① 已修复** — 已知非 YouTube 网页播放地址改为 `noAutomaticCover`，不再启动 FFmpeg；导入和网页播放器分流不变，真正的 MP4/HLS 直链仍走抽帧。提交：本提交。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/url_stream_video_test.dart` 覆盖 Bilibili / Netflix / Niconico / TVer 不进入 FFmpeg 策略，并保留直链/HLS 的既有回归覆盖。提交：本提交。
- **备注**：用户要求直接开 PR，不等待完整测试。定向测试在用例开始前因 `pdfium_dart` 下载 GitHub native asset 超时而阻塞（零测试执行）；定向 `dart analyze` 又在 Analysis Server 关闭阶段因本机 perf 文件删除失败崩溃，均不记作通过。`bug.dart check --strict` 与 diff check 通过。
