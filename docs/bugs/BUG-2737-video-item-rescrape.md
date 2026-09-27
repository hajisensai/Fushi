## BUG-2737 · 视频卡长按菜单没有「重新刮削」入口（刮错的独立电影无法重刮）
- **报告**：2026-09-27（用户：截图《リズと青い鳥》被刮成挪威电影《Få meg på, for faen》的封面，长按菜单里找不到重新刮削）
- **真实性**：✅ 真 bug。视频卡菜单 `_showVideoMenu`（`fushi/lib/src/pages/implementations/home_video_page.dart`）的注释写着「重命名 → 封面/刮削 → …」，但动作列表里从来没有刮削项；单作品重刮只实现在合集菜单（`_rescrapeCollection`，经 `planScrapeWorksForCollection` 按合集定位）。独立电影不在任何合集里，于是刮错后只能整来源重刮——库页上是断头路。计划器本身早就为它产出了 `book:<uid>` 作品单元（BUG-2433），缺的只是「按单个视频定位」的入口。
- **[x] ① 已修复** — 引擎新增 `planScrapeWorkForVideoBook`（`packages/fushi_engine/lib/media/video/metadata/video_library_scrape_sweep.dart`，只问视频自己所属本机来源的同一份计划，命中 `book:<uid>` 或它所在剧集的 `collection:<id>` 单元）；视频卡菜单加「重新刮削资料与封面」（门：有刮削 controller + 本机文件），手动指定 → `rescrapeWorkWithLookup` 与合集入口抽成共用的 `_rescrapePlannedWork`，不开第二条落库路径；定位不到时给可见提示。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`（`planScrapeWorkForVideoBook` 组：独立电影 / 剧集一集 / 跨来源同名 / 远端与不存在）；`fushi/test/pages/home_video_page_menu_test.dart`（「视频卡重新刮削资料与封面」组：入口出现 / 无 controller 不画 / 流媒体不画 / 定位不到给提示）。
- **备注**：入口只修「能重刮」。这部片为什么会被自动刮成同名度很低的挪威电影（自动匹配过宽）是另一个问题，未在本条处理。
