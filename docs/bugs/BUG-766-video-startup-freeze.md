## BUG-766 · 快速进出视频后 Windows 启动冻死在 loading
- **报告**：2026-07-13（用户：）
- **真实性**：✅ 真 bug。现场诊断（Windows 桌面、用户实机）：进程活、Win32 `responding=True`、yomitan（同 UI isolate 的 shelf server，`hibiki/lib/src/sync/yomitan_api_server.dart:92`）仍响应 ⟹ UI isolate 事件循环是活的；主窗口卡在 `hibiki/lib/main.dart:1255` 裸 loading 分支（背景 `Color(0xFF1F4959)`，截图坐实纯色空白），转圈帧时序上排在 DB 打开之前却从未 present，20s 看门狗（`hibiki/lib/main.dart:972`）逃生 UI 也从未出现 ⟹ 卡的是 **Flutter 引擎 raster / GPU present 管线**，非 Dart isolate。触发：快速进出视频 → libmpv/ANGLE/WGC churn（首开在途 controller 无法取消 `video_hibiki_page.dart:2342-2456`；退出 fire-and-forget dispose `video_player_controller.dart:2870`）污染进程共享 D3D device/swapchain → 首帧 present 楔死。
- **[ ] ① 未修复** — 四层：①首开在途 controller 主动取消 ②退出可 await 干净释放 ③DB probe busy_timeout 前置 ④present-watchdog 自愈；引擎级 D3D 隔离 deferred（Windows native，非 app Dart）。
- **[ ] ② 未加自动化测试** —
- **备注**：Windows-only；引擎级根治需真机取证坐实 device-lost 后另起 native spike。
