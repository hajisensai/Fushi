## BUG-5257 · retheme-drops-shell-theme
- **报告**：2026-11-21（代码审查发现，排查「色块摆放」时顺带找到）
- **真实性**：✅ 真 bug。`rethemeFushiWithScheme`（`fushi/lib/src/models/theme_notifier.dart:3999`）重走 `buildFushiThemeData` 时没传 `shell:`，工厂缺省 `const FushiShellTheme()` 产出的同类扩展在 `[...base.extensions, ...rebuilt.extensions]` 合并里排在后面，盖掉用户的外壳样式；平滑圆角还烤进了组件形状（`roundedShape`）。受影响：`FushiBlockColorScope`（MD3 色块取色）、歌词页 / 歌词浮层、视频 M3E 面板、视频遥控页。
- **[x] ① 已修复** — 把 `base.extension<FushiShellTheme>()` 传回工厂（`theme_notifier.dart:4010`），文档注释写明原因。
- **[x] ② 已加自动化测试** — `fushi/test/models/retheme_keeps_shell_theme_test.dart`：MD3 / 玻璃两套下重新取色后外壳扩展与用户一致，卡片形状跟随用户的平滑圆角设置而非工厂缺省。
- **备注**：
