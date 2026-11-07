## BUG-4233 · macOS 把别的版本 / 上次会话之前的 .ips 判成上次闪退
- **报告**：2026-11-07（用户：应用内自动闪退报告 J1ZWNUeaCT，macOS 3.3.0）
- **真实性**：✅ 真 bug。报告里唯一证据是 `[Process.macCrashReport] app=fushi version=3.0.1 … at=2026-11-04 … termination: DYLD code=1 Library missing`，上次会话（3.3.0）已正常退出（无 `previousExitUnclean`），却被判成「崩溃（3.3.0）」弹闪退报告。根因：
  - `fushi/lib/src/diagnostics/previous_exit_log.dart:1742`（修前）收 `.ips` 的起点只取 `max(已读水位, now-7天)`，不看上次会话起点 `previous.startedAt`——上次会话启动前的报告也会被当成「上次怎么没的」；
  - `previous_exit_log.dart:1757`（修前）收到的每份 `.ips` 一律 `kind: crash`，不比 `.ips` 头部 `app_version` 与上次会话 / 本次版本；同进程名的旧副本（3.0.1，dyld 找不到库启动失败）留下的报告被归到 3.3.0 头上。
- **[x] ① 已修复** — 起点再取 `previous.startedAt`（没有上次会话时退回 7 天窗口）；新增 `macIpsAppVersion` / `macCrashReportVersionMatches`，按版本数字主干比对（Apple 包 `CFBundleShortVersionString` 剥掉了预发布段，标记里是完整 build-name），与上次会话、本次版本都不符的只作诊断（`kind: null`、`severe: false`），任一方版本未知按属于处理。提交 22a6de2244。
- **[x] ② 已加自动化测试** — `fushi/test/diagnostics/previous_exit_log_test.dart`：「macOS：上次会话启动前的 .ips 不收、版本对不上的只作诊断」「macOS 崩溃报告版本比对：比数字主干，任一方未知按属于处理」。去掉起点修复 → `hasLength(1)` 红（实得 2 份）；单独去掉版本比对 → `contains('只作诊断')` 红。
- **备注**：J1ZWNUeaCT 现场上次会话起点未知（日志没带标记），真正挡住这份 3.0.1 报告的是版本比对；起点约束挡的是同版本、但早于上次会话的旧报告。
