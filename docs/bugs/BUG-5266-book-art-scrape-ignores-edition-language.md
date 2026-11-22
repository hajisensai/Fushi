## BUG-5266 · Cover scraping uses Japanese MangaBaka covers for non-Japanese editions
- **报告**：2026-11-22（用户：问 MangaBaka 遇到日文版与中文版同系列时会怎样）
- **真实性**：✅ 真 bug（代码路径确认，未跑网络复现）。「获取各卷封面」按书名分组，不看语言：`final String groupKey = series?.key ?? row.title;`（`fushi/lib/src/media/metadata/book_art_scrape_service.dart:320-321`），所以日文版与台版《化物語》落进同一个刮削组、匹配同一个 MangaBaka 系列；每卷封面一律拉日文：`fetchSeriesImages(seriesId, type: 'volume', language: 'ja')`（同文件 :872-877）。中文版第 N 卷因此拿到日文版第 N 卷的封面，只要那张比书里内嵌的中文封面大 1.2 倍就会写进刮削层、替换掉显示的封面。
- **[x] ① 已修复** — 分组：同一系列名带两种以上已知语言时组键加语言（与 BUG-5265 同一判据，单一语言的组键不变，旧的钉死记录照旧生效）。选图：`pickMangaBakaVolumeImages` 加 `language`（按主语言子标签比，默认 `ja`），非日文版的组拉该系列全部语言的卷图、只挑同语言的，没有就保留书里的封面，不回落日文版；Bangumi 单行本封面都是日文版，非日文版的组不用它补卷（钉死 Bangumi 时仍按钉的条目匹配）。横幅不分语言，照旧共用。手动「刮削封面」对话框仍列日文版卷图（用户自己挑，不在本条范围）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/metadata/book_art/book_art_plan_test.dart`「按版本语言挑卷封面」：`zh` 只收 `zh` / `zh-tw`、缺卷不回落 `ja`，默认仍选日文版。
- **备注**：
  - 与 BUG-5265 同一个根：系列身份不含语言。但本条独立于合集——刮削按书名分组，书不在合集里也会中。
  - MangaBaka **追踪**（进度同步）不算 bug：追踪的是作品而不是版本，两个版本读到的卷都计入同一个条目是合理的；系列级链接（PR #4196，未合并）按「已读完的最高卷」发送、不倒退，跨版本取最大值符合预期；develop 上的逐卷链接同样只增不减（`media_tracking_service.dart:597`「同步只会增加远端进度」）。合集级「不追踪」会同时覆盖两个版本，属于 BUG-5265 的影响。
