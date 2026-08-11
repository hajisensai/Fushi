## BUG-1521 · 详情Tracker刷新被其他请求阻塞
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。用当前 Windows Debug 包中的 `fushi_torrent_ffi.dll` 从 Dart 层加载用户实际的 7 份 resume，逐个任务都能立即读出 5 条 Tracker，排除原生数据与 FFI 解析问题。根因在 `fushi/lib/src/pages/implementations/torrent_detail_dialog.dart`：任务快照和四个详情标签共用一个全局刷新锁，Tracker 查询必须等待正在执行的 peers/总览请求；前序请求慢或悬挂时，`_trackers` 永远停在未加载态。qBittorrent 则按 torrent hash 独立请求 `/api/v2/torrents/trackers`，不依赖其他详情请求。
- **[x] ① 已修复** — 拆分任务快照刷新与逐标签刷新通道；不同标签可独立查询，同一标签的重复轮询仍合并。Tracker 的 `null`/异常现在会进入明确失败态并写错误日志，不再无限显示加载动画。
- **[x] ② 已加自动化测试** — `fushi/test/pages/torrent_detail_dialog_test.dart` 覆盖 peers 请求未结束时 Tracker 仍立即查询并渲染，以及 Tracker 返回 `null` 时结束加载并显示失败态。
- **备注**：按用户要求跳过全部自动化测试；使用 Windows Debug 构建直接实测。
