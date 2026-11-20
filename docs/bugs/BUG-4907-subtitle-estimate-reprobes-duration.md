## BUG-4907 · 字幕费用预估每次刷新都对没识别过的集串行重跑 ffprobe
- **报告**：2026-11-20（来源：路线图 `docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md` 的 gap-subpanels-4，c35 组；复核结论「部分成立：不卡 UI，只是预估行晚出」）
- **真实性**：✅ 真 bug（性能）。`fushi/lib/src/media/video/subtitle/app_video_subtitle_service.dart:1207`（基线 `origin/develop` 7745effa2e）的 `estimateCost` 对每个没识别过的集都 `await _probeDurationMs(...)`（ffprobe 子进程），逐集串行；生成面板切校对 / 画面开关、换语言都会重估，同一批集每次都重新探测。函数留的 `knownDurationsMs` 参数没有任何调用方传，等于没有缓存。整季 24 集时每次重估 = 24 次串行 ffprobe。
- **[x] ① 已修复** — 服务内按媒体路径缓存时长（存进行中的 Future，并发重估共用一次探测；探测失败 / 非正值不缓存，下次重探）。删掉无人使用的 `knownDurationsMs` 参数。没有复用任务目录的 `state.json`：能读到 `state.json` 的集一定已有字幕稿，本来就按字幕稿估、不走时长分支。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/video/subtitle/app_video_subtitle_service_test.dart` 的「BUG-4907：重估不重复探测时长；探测失败的下次重探」：同一目标连估三次（切画面、换语言）再并发估两次，探测次数必须是 1（修复前是 5）；探测失败的集下一次会重探并按时长估。
- **备注**：没有量真实 ffprobe 的耗时（本轮不做设备验证）；修复后的次数从 N×重估次数降到 N。
