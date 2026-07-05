## BUG-548 · Windows 更新 .staging 暂存根目录泄漏堆积
- **报告**：2026-07-05（用户：wrds）
- **真实性**：✅ 真 bug。实况 `C:\Users\wrds\AppData\Roaming\Hibiki\Hibiki\updates\` 有几十个空的 `.hibiki-<version>-windows-setup.exe.staging/` 目录（0.9.x~0.11.x，6月17-28，全 >7 天且内部为空）。
  - **根因（设计缺陷，与 build 时间线无关）**：
    1. `hibiki/lib/src/utils/misc/update_checker_download.dart:1303` `_promoteCompleteDownload` 成功后只删内层 `{id}` 子目录（`_deleteDirectory(stagingPaths.directory)`），留下**空的 `.<安装包名>.staging` 根**，从不删根本身。
    2. `hibiki/lib/src/utils/misc/update_checker_download.dart:199` `selectStaleUpdateArtifacts`（7天GC 纯函数）`if (entry.isDirectory) continue` 跳过**所有目录**，`.staging` 根逃过 GC；且 `_cleanupOldApks` 给 dir entry 传 `epoch-0` 假 mtime、内联的空根 `deleteSync` 是被 catch 静默吞的 best-effort。
    3. `reconcilePendingWindowsInstallerHandoff`（`update_checker_release.dart`）安装成功只删 `.exe`（TODO-1089 `installerToDeleteAfterSuccessfulHandoff`），不删对应 `.staging` 根 → 每装一版残留一个空根。
- **[x] ① 已修复** — 根因修复（好品味，与 1089 同范式）：
  - `selectStaleUpdateArtifacts`（`update_checker_download.dart:199`）目录分支改为**只**回收名字以 `.staging` 结尾的下载暂存根、按目录自身 mtime 与安装包同策（非 `.staging` 目录一律不碰）；`_cleanupOldApks`（`update_checker_release.dart` `_cleanupOldApks`）给 dir entry 传**真实 mtime**、删除时按后缀区分（`.staging` 递归删目录、其余删文件），移除混乱的内联特例块。
  - 新纯函数 `stagingDirToDeleteAfterSuccessfulHandoff`（`update_checker_download.dart`）+ 在 `reconcilePendingWindowsInstallerHandoff` 安装成功即刻删对应 `.staging` 根（best-effort，删失败由 GC 兜底）。归一化 + 越界守卫（复用 `_normalizeUpdatePathForCompare`，绝不删 updates 根直属之外 / 非 `.staging` / 更深子目录）。
  - 提交：见本轮 commit。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/update_checker_cleanup_test.dart`：
  - `selectStaleUpdateArtifacts` 组：过期 `.staging` 按 mtime 回收 / 新近 `.staging` 保留 / cutoff 当刻不删 / 非 `.staging` 目录越界守卫。
  - `stagingDirToDeleteAfterSuccessfulHandoff` 组：安装成功重建 staging 路径 / 未装不删 / 空路径不删 / updates 外不删 / 更深子目录不删 / 恒直属且以 `.staging` 结尾 / 尾斜杠归一 / 空根保守。
  - 源码扫描守卫：reconcile 内确实调用 `stagingDirToDeleteAfterSuccessfulHandoff` + `deleteStaging` 日志（平台耦合 static 无法端到端单测，锚定接线防重构摘掉）。
- **备注**：真实 Windows 更新装成功后 staging 根消失需真机验（本次保证清理逻辑 + 守卫绿）。TODO-1149。
