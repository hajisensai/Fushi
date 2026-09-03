## BUG-2000 · 未刮削系列没有任何自动刮削入口，存量库永远无资料
- **报告**：2026-09-01（用户：「自动刮削好像没了」「没刮削的系列应该有自动刮削才对」）
- **真实性**：✅ 真缺口。修前自动刮削只有两个触发点：来源扫描完成 + `autoAfterScan`（默认关，`fushi/lib/src/pages/implementations/home_page.dart:_onVideoSourceScanCompleted`）与下载导入完成（`video_download_pipeline_service.dart` → `scrapeImportedWork`）。库内既有条目没有任何入口：实测用户生产库 34 个规范作品中 31 个无 AniDB 身份、8 个合集零资料，全部静躺。用户看到的「自动刮削任务」全部是 `scope='work'` 的下载导入触发批次，下载停滞后任务自然消失。
- **[x] ① 已修复** — `194637edab`：新增 `fushi/lib/src/media/video/metadata/video_library_scrape_sweep.dart`。进视频 tab 每进程一轮，把「规范作品行缺失或无任何作品级 provider 身份」的作品按来源子集经统一任务 controller 自动刮（`scope='sweep'`）；严格唯一命中才落库，歧义/查无留在「待确认作品」队列等人工指定。受 `videoAutoScrape` 总闸（默认开）与 per-source enabled 双重门控，AniDB 3s 限流由 provider 既有请求门保证。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`（只补刮无身份作品 / scope 记 sweep / 总闸与来源开关 / 每进程一轮）。
- **备注**：判据刻意排除「已有 NFO/TMDB 历史身份」的作品——那些视为已刮削，不重复打扰；整来源重刮走既有入口。
