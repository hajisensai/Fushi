## BUG-5231 · 手动检查更新先唤回任意在途下载：stable 下载在途时，调试版面板按 debug 查被 stable 浮层截走
- **报告**：2026-11-22（外部审计 2026-11-22 项目审查 HBK-AUDIT-230，PR #4106）
- **真实性**：✅ 真 bug。`checkAppUpdateNow` 第一步 `UpdateChecker.revealActiveDownload()`（修前 `fushi/lib/src/updates/app_update_check.dart:41`）不带通道，唤回登记表里任一在途下载就返回，通道解析在它之后（修前 58 行）。BUG-4987 让调试版流水线面板显式按 debug 时间线查；stable 下载在途时，这次 debug 检查根本不发请求，只把 stable 的下载浮层拉出来。
- **[x] ① 已修复** — 先解析生效通道再唤回：下载会话按目标版本记下所属通道（`_UpdateDownloadSession.channel = channelForUpdateVersion(version)`，与版本 / tag 的通道判定同一套 pattern），`revealActiveDownload` 新增 `channel` 过滤，`checkAppUpdateNow` 只唤回本次要查的通道的下载，其余照常去查对应 manifest。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/update_download_session_overlay_test.dart`「HBK-AUDIT-230: manual check only reveals an in-flight download of the channel it is about to check」（真下载会话浮层：stable 会话隐藏后按 debug / beta 唤回为 false、浮层不出现，按 stable 唤回；debug 会话反之）。
- **备注**：不同通道的两次下载可以同时在途（流按版本互斥，本来就是两个版本）；没改。
