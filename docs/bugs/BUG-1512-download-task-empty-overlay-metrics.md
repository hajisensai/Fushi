## BUG-1512 · 下载任务空态遮挡且缺少实时指标
- **报告**：2026-08-10（用户：）
- **真实性**：✅ 真 bug。`downloads_page.dart` 把新版 `VideoDownloadJobsPanel` 与旧版 `AnimeDownloadDialog(tasksOnly: true)` 同时包成 `Expanded`，两者固定各占半屏；旧计划为空仍绘制“暂无下载任务”。新版卡片又只读取 Drift 工作流字段，后端已经提供的总大小、节点、实时速率、剩余字节和流量全部未接入。可见验收还发现新版 `library` 任务的 embedded resume id 从未进入启动 keep 集合，重启会丢掉做种与实时观测能力。
- **[x] ① 已修复** — 旧计划列表通过任务存在回调按需分配高度，空时完全折叠；新版任务页每 3 秒按持久任务绑定读取真实 torrent 快照，展示选定大小、真实状态、做种/用户、上下行速度、剩余时间和分享率。qB `total_size` 与内置引擎 `total_wanted` 统一进入 `TorrentSnapshot.totalSizeBytes`；历史任务没有运行时快照时从持久文件行回退真实选定大小。新版 embedded 完成任务继续保留 resume，重启后恢复做种与指标。
- **[x] ② 已加自动化测试** — `video_download_jobs_panel_test.dart` 覆盖完整实时指标与历史大小回退，`qbittorrent_client_test.dart` 覆盖总大小解析，流水线测试钉住完成任务 resume 保留，Windows 集成验收断言旧空态不再出现；旧内联任务回归继续通过。
- **备注**：旧构建已经删掉 resume 的历史任务无法伪造节点、速率和分享率，仍以“—”诚实降级；真实选定大小和工作流状态照常显示。新下载与仍有后端任务的记录展示完整实时值。
