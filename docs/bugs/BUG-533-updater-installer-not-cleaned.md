## BUG-533 · Windows update installer not deleted after successful install
- **报告**：2026-07-03（用户：安装包没有自动清除，`%APPDATA%/Hibiki/Hibiki/updates` 堆积）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/misc/update_checker_release.dart:99`（`_cleanupOldApks`）——过期完整安装包的兜底 GC（`selectStaleUpdateArtifacts`，TODO-1010）此前**只**在 `_check`（检查更新，同文件 line 215）路径被调用。用户关闭自动检查 / `neverRemind` 短路时该 GC 永不跑，每升级一版残留的旧安装包（几百 MB）在 updates 目录无限堆积。handoff「安装成功即删」（`installerToDeleteAfterSuccessfulHandoff`，TODO-1089）只负责**当次**那个包、且是一次性尝试（AV/句柄占用删失败即无重试锚点）。
- **[x] ① 已修复** — 把兜底完整包 GC 挂到每次 Windows 启动的 `reconcilePendingWindowsInstallerHandoff` 入口（`update_checker_release.dart`，在 reconcile 前无条件 `await _cleanupOldApks(currentVersion)`）。不依赖任何用户动作，确定性回收历史堆积，也补回 handoff 一次性删除失败的漏网包；GC 自带 handoff 待装包保护，不误删待重启安装的包。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/update_checker_cleanup_test.dart` 新增 group「BUG-533 接线守卫」：源码扫描断言 `reconcilePendingWindowsInstallerHandoff` 方法体内确实调用 `_cleanupOldApks`（该路径平台耦合无法纯 Dart 端到端跑，守卫接线防重构复发）。纯函数 `selectStaleUpdateArtifacts` / `installerToDeleteAfterSuccessfulHandoff` 的单测已存在于同文件。
- **备注**：handoff 成功即删（TODO-1089）仍保留，负责当次包的即时回收；本修复补的是「兜底 GC 从不因关闭检查而跑」这一空洞。真机走一次实际 Windows 更新 + 重启后确认 updates 目录被清仍需实机验证。
