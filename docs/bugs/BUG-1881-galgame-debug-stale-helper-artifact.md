## BUG-1881 · Windows Debug 构建残留旧 helper 导致 SGRE 内嵌查词坐标回退
- **报告**：2026-08-25（用户：Wight）
- **真实性**：✅ 真 bug。运行中的 SGRE 加载 `fushi_voice_hook.dll` SHA-256 `00DC3920…2BD5`，时间早于 `815819002` 的 draw glyph 坐标修复约 90 分钟；日志锚点仍以 50 px/字推进，而当前源码及修复后证据为 80 px/字。`fushi/windows/CMakeLists.txt` 仍只可选复制旧 `galgame_helper` zip，既不调用 BUG-1449 的普通文件安装脚本，也不清理增量 bundle 中的 `voice_hook/`，因此 Flutter 重建后仍会注入旧 DLL。
- **[x] ① 已修复** — Windows CMake 安装阶段统一调用 `install_into_bundle.ps1`；组包写入当前 helper 构建输入的确定性源码指纹，安装时同时验证源码身份与 archive SHA。Debug 遇到 dist 缺失或“文件完整但属于旧源码”时都会清掉旧 `galgame_helper/` 与 `voice_hook/`，宁可明确不可用也不注入旧件。injector 复用 ABI-compatible ready mapping 前还会核对目标进程驻留模块的规范路径与 SHA-256：已证明 path/digest 不同则报 `residentHookMismatch` 并要求重启游戏，Toolhelp/文件暂不可读或 `hooked=0` 仍保留为可有界重试的 `staleSession`，不再把瞬时竞态误判成永久失败。
- **[x] ② 已加自动化测试** — 扩展 `gal_helper_bundled_as_plain_files_test.dart`，钉住本地 Windows 构建必须调用共用脚本、不得退回 zip 复制，并以真实 PowerShell 分别验证 dist 缺失、完整但源码指纹陈旧时都会清理旧 helper；另守卫组包/安装共用同一指纹契约。native identity/launch-policy/session-reuse 测试覆盖确定不匹配与暂不可观测分型，Dart retry matrix/controller 测试分别钉住“旧 DLL 不重试”和“旧映射消失后恢复”。
- **备注**：坐标算法本身未改；必须从当前 HEAD 重新构建 native helper、安装进 Debug bundle并重启游戏进程，已加载的旧 DLL 不会被文件覆盖替换。
