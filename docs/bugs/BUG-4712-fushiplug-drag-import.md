## BUG-4712 · .fushiplug 插件包拖进插件管理 / 音源 / 歌词来源 / 追踪插件页毫无反应，只能走文件选择器
- **报告**：2026-11-16（维护者应用内反馈 izO74oG7IE：把 ASMR.ONE 音乐插件包拖进窗口没有任何反应）
- **真实性**：✅ 真 bug。两层根因：
  - `fushi/lib/src/media/drag_drop/drop_classification.dart:408`（develop be81d1c091）：没有任何类别认 `.fushiplug`，拖入一律落 `unknown`，各落点静默忽略；
  - `fushi/lib/src/pages/implementations/music/music_plugin_settings.dart:73`：音乐插件的「校验 → 确认 → 安装」流程焊死在 `pickAndInstallMusicPlugin` 的文件选择器里（追踪插件同理，`tracking_plugins_section.dart` 的 `_install` 先选文件再装），拖放根本没有入口可接；插件音源管理页（`music_plugin_pages.dart:140`）、音乐来源页、歌词来源页、追踪插件区都没有挂拖放落点。
- **[x] ① 已修复** — 分类层新增 `kDragPluginExtensions` / `DroppedFiles.plugins`（书架 / 视频等落点据 `hasAny` 给「本页不支持」提示，不再静默）；`kPluginPackageExtensions` 成为两处文件选择器与插件落点共用的扩展名真相源；安装流程拆出 `installMusicPluginPackage(context, manager, bytes)` 与 `TrackingPluginsSection._installPackage(bytes)`，按钮与拖放共用；新增 `PluginPackageDropTarget`（`fushi/lib/src/media/drag_drop/plugin_package_drop_target.dart`），挂在插件音源管理页、音乐来源页（两个分页）、设置里的歌词来源页与追踪插件区；插件列表 / 来源列表改为订阅 `MusicPluginManager.changes` 刷新，不再只认按钮安装。
- **[x] ② 已加自动化测试** — `fushi/test/media/drag_drop/plugin_package_drop_test.dart`（分类 + 音乐插件落点拖入弹确认、确认后安装、非插件包不碰安装）；`fushi/test/media/tracking/plugin/tracking_plugins_section_test.dart`「dropping a .fushiplug file runs the same install flow as the file picker」。修复前前者编译失败、后者断言失败。
- **备注**：曲库主页（音乐 tab）本身仍没有拖放落点，拖到那里依旧无反应；本次只在插件安装的入口页面接上拖放，没有扩到全局路由。真机拖放未复测。
