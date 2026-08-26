## BUG-1880 · 搜索资源被下载后端运行时前置门禁阻断
- **报告**：2026-08-24（用户反馈；截图已去身份化）
- **真实性**：✅ 真 bug。`home_page.dart` 的资源搜索与订阅入口在
  `Navigator.push` 前调用 `currentVideoDownloadBackendIdentity()`；Windows Debug 包缺少
  内置 torrent runtime 时会直接返回，实际的资源 provider 搜索从未启动。
- **[x] ① 已修复** — 允许资源页先打开并完成搜索，把下载后端身份解析延迟到用户
  提交下载/订阅时；提交失败在当前资源页显示可操作错误，页面保持可重试。
- **[x] ② 已加自动化测试** — 静态守卫锁定后端解析必须位于 `onSubmit` 内，widget
  回归覆盖 runtime 缺失时的提交提示、页面留存与按钮恢复。
- **备注**：本地 Windows Debug 运行时缺件是独立的构建产物问题；恢复四个受忽略的
  runtime DLL 并重启应用后，内置下载后端可正常探测。源码修复确保缺件时仍能浏览资源。
- **验证缺口**：本条的验证层就是最强可落地层（`video_discovery_production_wiring_guard_test.dart`
  的静态守卫 + `video_resource_version_group_list_test.dart` 的 widget 回归），不涉及 galgame 真机门。
  仍未做的一步：没有在缺 runtime DLL 的真 Windows Debug 包上手动复跑「首页点资源搜索 →
  页面打开并出结果 → 提交下载时才报错且可重试」这条原始失败路径（本轮真机验证已取消）。
