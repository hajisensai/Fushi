## BUG-5263 · import-dialog-pops-page-above
- **报告**：2026-11-23（来源：应用内反馈 zorhfwRcz- 分诊时发现）
- **真实性**：✅ 真 bug。导入框在 `await` 导入结束后用裸 `Navigator.pop(context, true)` 关自己（`fushi/lib/src/media/manga/manga_import_dialog.dart:776`，书 / 有声书 / 字幕重导 / 粘贴文本 / 压缩包 / 视频 / IPTV 导入框同型共 16 处）。`Navigator.pop` 弹的是导航器最顶层路由，不是框自己的路由；导入期间用户从悬浮反馈球 / 全局快捷键推出别的页面时，导入完成会关掉那一页并把导入结果当成它的返回值（类型不符时直接抛），导入框自己留成关不掉的孤儿。
- **[x] ① 已修复** — `fushi/lib/src/utils/own_route_exit.dart` 新增 `closeOwnRoute(context, result)`：自己在顶层走普通 `pop`，不在顶层用 `removeRoute` 只摘掉自己并带上结果，路由已不在栈里时什么都不做。所有导入框的完成 / 取消关闭改用它；`audio_cd_import.dart` 原来私有的同款实现收编进这个原语。
- **[x] ② 已加自动化测试** — `fushi/test/utils/own_route_exit_test.dart`（`closeOwnRoute` 三种情形：在顶层 / 上面压着页面 / 已关闭）；`fushi/test/media/import/import_dialog_close_own_route_guard_test.dart`（导入框源码里不许再出现带结果的裸 `Navigator.pop(context, …)`）。
- **备注**：反馈 zorhfwRcz- 本身的闪退（3.3.0 无 Java 栈）与本 bug 无因果证据，仍按「缺信息」挂着。
