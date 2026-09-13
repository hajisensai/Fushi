## BUG-2236 · 视频文件夹导入按文件名拆散难度合集
- **报告**：2026-09-07（导入父目录内三个难度文件夹，每个约500个不同标题视频）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_filename_parser.dart:165` 仅按解析标题分组；`source_library_scanner.dart` 递归扫描后始终调用此规则，没有保留目录分组的选项。`VideoSourceWorkPlanner` 将未入多集合集的视频作为独立作品；相同资料标题并不会建立合集成员关系。
- **[x] ① 已修复** — schema v98增加来源 videoGroupingMode（默认series保留旧行为），目录合集保存本机 sourceFolderPath。导入时及来源设置提供目录模式，按一级目录创建普通合集，根直属视频归根合集，重扫事务内复用；不认领同名手动合集。目录模式不创建动画元数据索引/刮削计划，系列页优先按目录合集折叠。提交：`2fb9e0641a`。
- **[x] ② 已加自动化测试** — `video_folder_group_coordinator_test.dart` 覆盖1500视频/3合集、幂等、手动合集碰撞、切换模式及截图Fate命名；`video_source_grouping_ui_test.dart` 覆盖设置写穿；`migration_v98_video_grouping_test.dart` 覆盖v97无损升级。
- **备注**：截图中的Fate文件名在当前解析器回归用例能够归为同一作品，无法仅凭旧截图推断当前版仍存在相同解析错误。错封面的真实旧NFO内容未提供，未修改或删除用户资料。尚未在安装版复测原始1500个媒体文件导入。
