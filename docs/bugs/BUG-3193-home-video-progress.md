## BUG-3193 · 首页继续栏视频缺进度显示
- **报告**：2026-10-09（用户：应用内反馈 FWfm7txZbt「小说有进度显示，视频缺了进度显示」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dashboard_page.dart` 旧 `_videoContinueEntry` 只用 `videoWatchFraction`（`packages/fushi_engine/lib/media/video/m3u8_playlist.dart:32`）算进度——它只认单行多集播放列表（`episodeCount >= 2`），合集里的一集与单视频恒返回 null，封面底部不画进度条；副标题也只写「观看」，没有集数。根因是 `VideoBooks` 不存总时长，页面从没去读已有的时长缓存 `VideoFileSpecs.durationMs`。
- **[x] ① 已修复** — 首页聚合时按在看视频的路径批量读 `videoFileSpecsByPath`；纯函数 `dashboardVideoContinueProgress` 给出三种口径：多集播放列表 =「第 N 集」+ 集粒度进度；合集成员 =「第 N 集」（组内序号）+ 本集看到哪；单视频 = 进度条 + 百分比，时长未知时角标退回看到的时间点（▶ 12:34）。PR pr/home-slim。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`：`dashboardVideoContinueProgress` 四个分支单测 +「精简 · 视频也显示进度」widget 测试（规格缓存有 / 无两条视频）+ 合集卡角标 = 集数。
- **备注**：流媒体与从没探测过规格的本地文件拿不到时长，只能显示时间点角标。
