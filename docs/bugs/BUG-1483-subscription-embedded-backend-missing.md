## BUG-1483 · 订阅创建后因内置下载引擎缺失而全部卡在需处理
- **报告**：2026-08-10（用户反馈：订阅下载异常）
- **真实性**：✅ 真 bug。只读检查实际运行库确认订阅已成功发现 3 个条目并创建 3 个任务，但任务均停在 `needsAttention/enqueue`，错误为 “The original download backend is not configured on this device”；对应 Release 目录同时缺少内置引擎的 4 个运行时 DLL。根因是 `fushi/lib/src/models/app_model.dart:3622` 构造任务后端身份时只按平台选择 embedded，未将 FFI 就绪状态纳入身份门禁，而 `fushi/windows/CMakeLists.txt:133` 之前允许 Profile/Release 在 DLL 缺失时静默完成打包。
- **[x] ① 已修复** — embedded 后端不可用时在任务持久化前返回可操作错误，旧任务解析时保留同一明确原因，legacy 导入仍可继续启动；Windows Profile/Release 缺任一运行时 DLL 时构建直接失败，避免再次发布残缺包。并将下载任务/订阅/设置及发现页订阅改为全宽页面。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_backend_identity_test.dart`、`fushi/test/build/windows_torrent_bundle_guard_test.dart`、`fushi/test/pages/video_download_jobs_panel_test.dart`、`fushi/test/pages/video_download_subscriptions_panel_test.dart`、`fushi/test/pages/torrent_settings_field_width_test.dart`、`fushi/test/pages/video_discovery_acquisition_dialogs_test.dart`；另由 `fushi/integration_test/subscription_download_full_width_itest.dart` 在 Windows 真 runner 中焦点驱动四个页面并保存非空白截图（提交哈希见本修复分支 Git 历史）。
- **备注**：诊断和验证使用独立 worktree / 隔离产物；未修改用户正在运行的数据库。
