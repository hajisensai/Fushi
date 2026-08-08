## BUG-1461 · Himouto 罗马字标题被 TMDB 本地化结果严格门控拒绝
- **报告**：2026-08-08（用户：`himouto` 刮削失败）
- **真实性**：✅ 真 bug。`FilenameParser` 能从 `[Kamigami] Himouto! Umaru-chan - 10 [...]` 正确得到标题与集号；失败发生在 `hibiki/lib/src/media/video/metadata/tmdb_video_metadata_provider.dart:40`：TMDB 中文搜索可以通过英文别名命中，但响应只保留本地化中文名和日文原名，严格标题门控看不到英文命中名后返回 `notFound`。
- **[x] ① 已修复** — 本提交在同一 TMDB 主源内以稳定顺序合并配置语言、英文、日文和简中搜索结果，把同一 TMDB ID 的本地化标题保留为 aliases；自动应用仍要求规范化标题精确命中，不引入跨源回退或模糊匹配。刮削入口同时改为应用生命周期后台任务，关闭面板不取消，并可从来源页/全局悬浮入口查看当前进度、待确认项与持久运行历史。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/metadata/video_metadata_provider_contract_test.dart:194` 覆盖中文响应丢英文标题、英文补充响应恢复严格匹配；`hibiki/test/media/video/video_filename_parser_test.dart` 锁定真实 Himouto 文件名解析；`hibiki/test/pages/video_source_scrape_ui_test.dart` 覆盖后台面板关闭、任务继续和重新进入；`hibiki/test/media/video/metadata/video_source_scrape_task_test.dart` 锁定首次任务通知即为 busy。
- **备注**：补充语言请求逐个隔离失败，主配置语言失败仍维持原错误语义；任务遇到多个严格候选时在后台等待用户确认，不会静默选错。
