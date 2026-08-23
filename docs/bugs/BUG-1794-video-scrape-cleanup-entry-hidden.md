## BUG-1794 · 视频导入页看不到清理全部刮削记录入口
- **报告**：2026-08-23（用户：）
- **真实性**：✅ 真 bug。清理 action 原先只声明在 `fushi/lib/src/settings/settings_schema_video.dart` 的视频设置 schema；`fushi/lib/src/pages/implementations/media_sources_page.dart` 的视频「导入」页页头仅渲染「全部刮削 / 后台任务」，所以用户截图所在的真实刮削工作流页面完全没有清理入口。设置页还先渲染很长的播放分区，入口即使存在也很难发现。
- **[x] ① 已修复** — 在视频「导入」页页头把「清理全部刮削记录」与「全部刮削 / 后台任务」并列显示；`video_scrape_cleanup_action.dart:18` 收口确认框、single-flight、清理 service、错误提示与成功广播，设置页与导入页复用同一实现。成功后 `media_sources_view.dart:265` 重读保活来源页，立即移除已经清掉的「上次刮削」摘要。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_source_actions_wiring_guard_test.dart` 固定页头入口顺序、HomePage→VideoLibraryShell→MediaSourcesPage 回调接线、设置页共用 action，以及清理成功后的来源页重读广播；相关 shell / 拖放构造测试同步覆盖新增必传能力。
- **备注**：定向 `flutter test` 4 个文件共 24 项通过；6 个相关生产文件逐文件 `dart analyze` 均通过。按用户要求未跑全量测试或构建；Windows 实机视觉复测待用户当前运行版本更新后确认。
