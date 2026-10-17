## BUG-3192 · 带年份文件夹的番没刮上：裸年份未剥离
- **报告**：2026-10-09（群反馈「定力」：视频库里一部分番封面是截帧、没刮上，没刮上的目录名都带年份，如 `DEATH NOTE (2006)`、`FX戦士くるみちゃん (2026)`）
- **真实性**：部分为真。
  - 截图里带 `(年份)` 的目录名是本仓下载整理器自己写的形态（`packages/fushi_engine/lib/media/video/download/video_download_organizer.dart` `'$title (${request.year})'`），即这些都是 Fushi 下载的作品。用户这批没刮上的主因是 BUG-3073（下载任务身份被当用户锁定 → 哈希不决定身份、Jikan 不可达即 providerUnavailable），已由 f226f21d6f（10-09 13:09，晚于用户的构建）修复。
  - 括号年份 `(2023)` `[2023]` `（2023）` `【2023】` 解析一直正确（块分类 ③）。
  - 新发现的真缺口：不带括号的裸年份（scene 命名 `Title.2023.1080p`、`Title 2023`、`Title_2023`）原样留在标题里（`packages/fushi_engine/lib/media/video/scraper/filename_parser.dart` `_parseTitleText`），严格标题门对不上，回落标题匹配查无。
- **[x] ① 已修复** — `FilenameParser._takeTrailingYear`：标题尾部裸年份进 `year`；门槛为左侧须有标题文字、不晚于明年、括号年份优先（WIP 提交，见分支 pr/scrape-year-folder-regression）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/scraper/filename_parser_test.dart`「带年份的目录名（BUG-3192）」；`fushi/test/media/video/metadata/video_scrape_title_candidates_test.dart`「year-tagged work directories fall back to a title match」（标题精确匹配的假资料源 + 真 resolver）。
- **备注**：封面兜底「糊」是 LandscapeCoverImage 把横向截帧放进竖卡、上下模糊填充的设计，不是截帧本身模糊；是否改取帧策略属产品取舍，待定。
