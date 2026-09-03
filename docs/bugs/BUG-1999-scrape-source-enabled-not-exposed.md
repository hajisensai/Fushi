## BUG-1999 · 来源刮削 enabled 开关未暴露，用户无法关闭强制刮削
- **报告**：2026-09-01（用户：「强制我刮削，我无法指定他不刮削」）
- **真实性**：✅ 真 bug。数据层开关一直存在且真实生效：`video_source_scrape_settings.enabled`，协调器 `_scrapeSourceUnlocked` 判 `!settings.enabled` 直接短路（`fushi/lib/src/media/video/metadata/video_source_scrape_coordinator.dart:266`，含下载导入后的 `scrapeImportedWork` 路径）。但「来源刮削设置」对话框从没画过这个开关，保存时还硬编码回写旧值（`fushi/lib/src/pages/implementations/media_sources_view.dart:1041` 修前：`enabled: Value(existing?.enabled ?? true)`）——能力在库里躺着，UI 把它锁死成 true。
- **[x] ① 已修复** — `194637edab`：设置对话框新增「启用此来源的刮削」开关行（i18n `video_source_scrape_enabled_toggle`），draft/保存路径带 enabled 真写穿；关闭后手动、扫描后、下载导入后与库内自动补刮全部短路（协调器判据现成，零新分支）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_source_scrape_ui_test.dart`（「source settings keep AniDB fixed and persist safe output toggles」扩展断言 `settings.enabled == false` 写穿 DB）；补刮侧跳过关闭来源见 `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`（「来源刮削开关关闭时既不进队列也不补刮」）。
- **备注**：刮削重设计 P1 将把「无 AniDB 身份的下载任务跳过刮削阶段」一并落地，届时 per-job 维度也不再有强制刮削。
