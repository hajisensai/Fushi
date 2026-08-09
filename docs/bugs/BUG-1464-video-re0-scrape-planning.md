## BUG-1464 · re0 特典误作作品且主剧季标题识别失败
- **报告**：2026-08-09（用户：`re0` 来源刮削异常，希望对齐 MoviePilot）
- **真实性**：✅ 真 bug。真实 `video_source_scrape_runs.id=15` 规划 10 个作品，主剧失败、9 个待确认；`video_local_extra_classifier.dart` 的动画附件正则只接受空格/点/横线边界，无法识别发布名里的 `[PV]`、`[NCOP]`，也未覆盖 `menu`、`迷你动画` 目录。`video_source_scrape_coordinator.dart:_titleCandidates` 虽收集父/祖父目录，却把带字幕组、全集范围、编码块的原始目录名直接送入 provider 搜索，没有像 MoviePilot `MetaInfoPath` 那样先解析目录标题；因此中文“第三季”线索未形成有效 TMDB 查询。
- **[x] ① 已修复** — 方括号动画标记和常见菜单/特典目录统一归为本地附件，保留 `VideoBook` 但不再产生独立刮削作品；provider 候选先加入文件名、父目录、祖父目录的清洗标题，并从三层路径合并季号约束。重扫索引会把旧的附件临时作品解绑并挂回唯一主作品。
- **[x] ② 已加自动化测试** — `video_source_metadata_indexer_test.dart` 覆盖 `[PV]`、`[NCOP]`、menu、迷你动画分类；`video_source_work_planner_test.dart` 用 `re0` 同构目录验证只规划一个主剧作品；`video_filename_parser_test.dart` 锁定第三季/集号；`video_source_scrape_coordinator_test.dart` 验证只有清洗后的中文父目录标题能命中 TMDB 且季号为 3。
- **备注**：对齐 MoviePilot 的“文件名 + 父目录 + 祖父目录解析后识别”行为，但继续保留 Hibiki 的严格自动应用门槛；不会把附件删出“全部视频”，也不会移动或重命名磁盘文件。
