## BUG-427 · Android install permission granted then cannot resume/retry install
- **报告**：2026-06-26（TODO-852）
- **真实性**：✅ 真 bug
  - 原生 `hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java:369-381` 权限门
    用 `startActivity(settings)` + `FLAG_ACTIVITY_NEW_TASK` fire-and-forget，且立即
    `result.error("INSTALL_PERMISSION_REQUIRED")`：新任务脱离结果回调链，`onActivityResult`
    永不触发，用户授权返回后没有任何代码续接安装。
  - Dart `hibiki/lib/src/utils/misc/update_checker_release.dart:612-630` 的通杀 catch 把
    `INSTALL_PERMISSION_REQUIRED` 当普通下载失败吞（弹 `update_download_failed`），`finally`
    随即 `overlay.remove()` + 销毁会话 + 丢弃已下载 apk 引用 → 用户必须重下。
- **[x] ① 已修复** —
  - 原生：权限门改 `startActivityForResult(settings, INSTALL_PERMISSION_REQUEST=1002)`（去掉
    NEW_TASK），暂存 `pendingInstallResult` / `pendingInstallApkPath`（已过 cache-dir 校验的
    路径）；新增 `onActivityResult` 分支 + `onResume` 兜底 + `resumePendingInstall()`（复查
    `canRequestPackageInstalls` 后 `launchApkInstaller(new File(apkPath))` 复用已下载 apk，
    不重下）；抽 `launchApkInstaller(File, Result)` 两路径共用（`FileProvider.getUriForFile`
    只一次）。`installApk` 入口先终结悬挂 pending（防永久 BUSY 锁死）。
  - Dart：新增 `_applyWithInstallRetry`（`PlatformException.code == INSTALL_PERMISSION_REQUIRED`
    时隐藏遮罩不销毁会话、弹重试对话框、点重试用同一 apkFile 递归 apply 绝不重下；取消则
    正常返回 apk 留缓存；其它 code rethrow 走原路径）+ `InstallPermissionRetryDialog`
    + 4 i18n key（`update_install_permission_title/_message/_retry/_cancel`）。
    `:603` apply 改走 `_applyWithInstallRetry`，前后均加 `context.mounted` 守卫。
  - 提交哈希：见本分支 commit。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/platform/android_install_permission_retry_guard_test.dart`（原生源码扫描守卫：
    startActivityForResult 非裸 startActivity、请求码 1002≠SAF、onActivityResult/onResume 续接、
    设置段不含 NEW_TASK、FileProvider 仅一次、SAF 分支保留）。
  - `hibiki/test/utils/misc/update_checker_install_permission_retry_test.dart`（首拒+重试成功
    apply 调 2 次且 apk 路径一致不重下、取消只 1 次不 rethrow、非目标 code rethrow、对话框弹出、
    关键回归：不弹 update_download_failed）。
- **备注**：真机门禁待用户（API26~36 各 OEM 时序专项 + 复用 apk 不重下 + SAF 不串扰）。
