## BUG-1284 · 游戏活动身份不统一导致封面缺失
- **报告**：2026-07-29（用户：活动里的游戏缺少封面，怀疑命名不同）
- **真实性**：✅ 真 bug。`hibiki/lib/src/mining/gal_hook_session_controller.dart:1079`
  的启动活动身份原先把 exe 绝对路径写进 `mediaKey`，而
  `hibiki/lib/src/pages/implementations/home_dashboard_page.dart:1978` 的活动封面
  按游戏库身份反查；attach 事件还可能没有 key，所以封面命不中。
- **[x] ① 根因修复** — `launchGame` 明确接收 `gameId/gameTitle`，三个库内启动
  入口统一传 `GalgameEntry.id/displayName`；读取侧新增
  `findGalgameForActivity`，按新 id → 旧 exePath → 旧标题快照兼容历史活动。
  首页与游戏首页时间线共用该解析，并复用 `resolveMediaCoverImage`。
- **[x] ② 自动化测试** —
  `test/mining/gal_hook_session_controller_test.dart` 钉住新活动实际落库身份；
  `test/mining/galgame_launch_args_test.dart` 覆盖三类历史/当前身份；
  `test/mining/galgame_helper_launch_guard_test.dart` 钉住三处调用接线；
  `test/pages/home_dashboard_page_test.dart` 用旧 exePath 复现并断言活动封面。
- **备注**：根因修复与自动化测试提交 `9d6243bd0`。定向测试启动前被 `pdfium_dart` 下载
  `pdfium-win-x64.tgz` 的 GitHub 网络超时阻断（0 条执行）；10 个改动项的
  `flutter analyze --no-pub` 通过。
