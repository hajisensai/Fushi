## BUG-4473 · 切屏后游戏内查词（实测排版路线）失效，要到下一句才恢复
- **报告**：2026-11-11（用户：「我切屏以后这个内嵌查词就失效了，需要进入下一句才恢复」；TyranoScript/Electron 游戏，3840x2160 全屏）
- **真实性**：✅ 真 bug，本机 `%TEMP%\hibiki_glookup.log` 实证：切到后台时游戏客户区变成 3840x2127 → runner 报 `measuredLayoutStale/measured_client_size_mismatch` → Dart 强制重发的 2160 测量被拒（`update_rejected ... measured=3840x2160`）；切回前台尺寸变回 2160，runner 带新的实时客户区再报一次 stale，但 Dart 的「同一份测量被拒过就不重发」备忘把这份**此刻已有效**的测量挡掉；DOM 观察脚本的快照没变（`json === state.last`）也不会推新帧 → 一直挂起到下一句。根因：`fushi/lib/src/lookup/gal_attached_text_controller.dart` `_pushMeasuredFrame` 的拒收备忘只记 payload、不记拒收时的客户区尺寸。
- **[x] ① 已修复** — 拒收备忘带上拒收时 runner 报告的实时客户区尺寸（`_measuredRejectedClientSize`，取状态事件的 referenceClient）；只有「同一份测量 + 同一客户区尺寸」才不重发。runner 状态签名本就含实时客户区尺寸，尺寸一变就发状态事件，走 measuredLayoutStale 分支强制重发，不会循环。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_attached_measured_route_test.dart`「切屏：客户区短暂变样时被拒的测量，尺寸变回后重发（不等下一句）」。
- **备注**：未在真机复测切屏路径（需用户游戏环境）。
