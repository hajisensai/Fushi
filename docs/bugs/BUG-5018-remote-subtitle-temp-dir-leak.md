## BUG-5018 · 远端字幕生成失败 / 取消时不清产物临时目录
- **报告**：2026-11-20（来源：路线图 `docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md` 的 gap-subpanels-9，c35 组；复核结论「部分成立，窗口很窄」，「一集失败即终止」与本机管线同口径、不改）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/subtitle/remote_video_subtitle_service.dart:514`（基线 `origin/develop` 7745effa2e）：每集在系统临时目录下建一个产物目录交给 `InterconnectJobClient` 下载 host 的产物，只有成功取回后才删；host 报错、流没给结果就结束、用户取消（`_runEpisode` 返回 null 时直接 `return`），以及 `_collect` 复制字幕时抛错，这个目录（可能已下载了部分产物）都留在 `fushi_remote_subtitle_jobs/` 下，越积越多。另外失败 / 取消原先在流回调里就把任务收尾，调用方看到任务结束时目录还没处理。
- **[x] ① 已修复** — `_runEpisode` 不再自己收尾，只返回这一集的去向（产物 / 以失败或取消结束）；`_run` 用 `try/finally` 包住「跑一集 + 取回」，不论哪条路都先删临时目录，再按去向收尾任务。删目录失败（文件被占用）只进错误日志、不改判任务。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/video/subtitle/remote_video_subtitle_service_test.dart` 的「BUG-5018 产物临时目录」组：host 先往产物目录写半截文件，再分别以报错、流直接结束、用户取消收场，`job.done` 之后工作根目录下必须为空（修复前三种都残留目录）；成功路径同样为空。
- **备注**：取消时客户端那边的下载流是异步断开的，若它在目录删掉之后还写入，会重新建出目录——窗口极窄，记在 PR 遗留项。
