## BUG-1459 · 安装器无法替换被残留子进程锁定的文件
- **报告**：2026-08-07（用户：Windows 生产机自更新到 v1.3.1-debug.10156 失败，弹窗「安装器无法替换 D:\APP\Hibiki\ffmpeg.exe（DeleteFile code 5）」，且日志显示「启动安装器前已确认 Hibiki 退出」）
- **真实性**：✅ 真 bug。根因 `hibiki/windows/installer/fushi.iss` 的 `InitializeSetup()`（修复前 :207 起）：互斥体层只证明主程序退出——`FushiMutexExists()` 为假即整段短路 `Exit`；从安装目录启动、**不持有单实例互斥体**的辅助进程（Anki 音频转码的 `ffmpeg.exe`、galgame helper）可以比主程序活得久并锁住自己的镜像文件，文件复制阶段随即失败。`KillImage('hibiki.exe' /T)` 的进程树清扫也只在「互斥体仍在」分支执行，且父进程先退出后子进程脱树，`/T` 同样够不到。
- **[x] ① 已修复** — 新增 `PrepareToInstall`（用户确认后、文件复制前的最后钩子）调用 `KillProcessesUnderDir(ExpandConstant('{app}'))`：PowerShell 按「进程可执行路径位于目标目录之下」（`$_.Path.StartsWith($d, OrdinalIgnoreCase)`）过滤后 `Stop-Process -Force`——按路径不按名字，不误伤机器上用户自己的同名进程。同款补丁同步落更新桥分支 `bridge-hibiki-final` 的 `hibiki.iss`（老用户升桥的必经安装器）。提交：fushi-mega 侧见本文件所在提交；桥侧 `bridge-hibiki-final` 分支。
- **[x] ② 已加自动化测试** — 源码扫描守卫 `hibiki/test/build/windows_installer_appdir_process_sweep_guard_test.dart`（钉 `PrepareToInstall` 存在 + `{app}` 清扫调用 + 路径前缀过滤 + `Stop-Process -Force`；变异实测：注释掉清扫调用守卫转红，反向替换还原）。
- **备注**：安装器逻辑本体无法在 Dart 单测中执行，守卫层为最强可落地层；真机验证路径 = 老包升桥时 ffmpeg.exe 残留场景，随桥版本发布后由更新链路自然覆盖。
