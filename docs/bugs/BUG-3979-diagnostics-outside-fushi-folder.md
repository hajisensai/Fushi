## BUG-3979 · 桌面端错误日志 / 面包屑写在用户 Documents 根，不在 Fushi 目录
- **报告**：2026-11-02（用户反馈 4w_veZGiQ7）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/utils/misc/error_log_service.dart:218-229` 直连 `getApplicationDocumentsDirectory()`；`video_diag_log.dart:145-150`、`study_diag_log.dart:52-57` 同模式；crash_report_state / previous_exit_state / session_marker / activity 面包屑都挂在同一目录。macOS 去沙盒后、Windows、Linux 上即用户 `~/Documents` 根）
- **[x] ① 已修复** — `AppPaths.diagnosticsDirectory()` 成为诊断文件唯一落点：桌面 `<ApplicationSupport>/logs`，移动端保持沙盒内 documents（iOS MetricKit 原生落盘约定不变）；首次解析时 `migrateLegacyDiagnostics` 把旧位置的已知诊断文件（确切文件名 + `activity_` 前缀，绝不碰其它用户文件）搬过去（跨卷 copy+delete，目标已存在以新为准），搬迁先于 ErrorLogService 读面包屑；失败条目在 ErrorLogService.init 写进错误日志。ErrorLogService / VideoDiagLog / StudyDiagLog 改用它；更新 app_paths 白名单注释与 documents_whitelist_guard 注释（分支 claude/review-merge-bug-fixes-b183d4，未提交）
- **[x] ② 已加自动化测试** — `fushi/test/storage/diagnostics_directory_test.dart`（只搬诊断文件、同名以新为准、搬后面包屑崩溃恢复仍生效、lib/ 直连 getApplicationDocumentsDirectory 白名单守卫）
- **备注**：审计其它直连：video_clips 导出（clip_export / playback_remote）、桌面目录选择器、数据根判定、移动端下载回退、有声书平台默认解析器——均为用户文件语义或只比对路径，列入守卫白名单未改。
