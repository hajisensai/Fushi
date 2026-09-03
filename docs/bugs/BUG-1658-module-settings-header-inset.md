## BUG-1658 · 模块设置子页顶栏与其他子页边距不一致
- **报告**：2026-08-15（用户：视频页截图两张——「设置和其他页面的左右边距不同。每个子页的顶栏选择组件的宽度不同」；追加「每个页面的页头宽度不一样怎么解决」→ 扩到全部顶层页面）
- **真实性**：✅ 真 bug。页头几何不统一共四处：
  1. `fushi/lib/src/pages/implementations/module_settings_view.dart:50`（修前）：四个模块壳（视频 `video_library_shell.dart` / 书架 `home_reader_page.dart` / 漫画 `manga_library_page.dart` / 游戏 `home_game_page.dart`）共享的「设置」分区把**页头+正文整体**包进 `DesktopContentLayout(kind: settings)`（16/24px 侧向留白 + 宽屏 960 居中限宽，`platform_utils.dart:230/246`），其余分区都是 `readerShelf` 全出血（`platform_utils.dart:222/242`）→ 切「设置」时共享分段导航条整体偏移、宽度包络随窗口档位变化。
  2. `home_dictionary_page.dart:383`（修前）：查词页大标题页头被包在 `DesktopContentLayout(kind: dictionary)`（16/24px 留白）里 → 页头比书架/视频/游戏右移一档。
  3. `downloads_page.dart:188`（修前）：下载页还是旧 `Scaffold.appBar` 小标题 + 居中 TabBar，与各库页大标题页头完全不同构。
  4. `browser_extension_page.dart:140`（修前）：浏览器扩展页同为旧 `AppBar` 小标题。
- **[x] ① 已修复** — 统一基线 =「`FushiPageHeader` 页头全出血 + 自身 `spacing.page` 内边距」：① `ModuleSettingsView` 去掉整页 settings 档包裹（正文横向缩进由 renderer `detailHorizontalInsets` 自持）；② 查词页页头提出 dictionary 档之外（正文文字流留白保留）；③ 下载页由 develop 上游「统一门头（2026-08-13）」批次先行完成（`FushiPageHeader.customTitle` + 分段条，本轮不重复改、仅以守卫锁定不回退）；④ 浏览器扩展页改 `FushiPageHeader`。全局设置主页 `settings_home_page.dart`（页头本就在布局外）与首页 dashboard（无页头）不受影响。提交：见本文件同一提交。
- **[x] ② 已加自动化测试** — `fushi/test/pages/module_settings_header_alignment_guard_test.dart`（源码扫描守卫三条：ModuleSettingsView 剥注释后无 `DesktopContentLayout`/`DesktopContentKind`；查词页 `_buildPageHeader()` 必须先于 `DesktopContentLayout(`；下载/扩展页剥注释后无 `appBar:` 且有 `FushiPageHeader(`）。三条均已变异实测（包回 wrapper / 层序对调 / 重加 appBar 守卫皆红；注释提及类名不误伤；还原后 sha256 逐字节一致）。
- **备注**：修后模块内「设置」分区正文在宽屏不再 960 居中限宽（与兄弟分区一致）；首页 dashboard 本无页头、设置主页页头已在布局外，均不在本 bug 范围。如日后要恢复正文限宽，只许包正文、不得再包页头。
