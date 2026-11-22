## BUG-5266 · Cover scraping uses Japanese MangaBaka covers for non-Japanese editions
- **报告**：2026-11-22（用户：问 MangaBaka 遇到日文版与中文版同系列时会怎样）
- **真实性**：✅ 真 bug（代码路径确认，未跑网络复现）。「获取各卷封面」按书名分组，不看语言：`final String groupKey = series?.key ?? row.title;`（`fushi/lib/src/media/metadata/book_art_scrape_service.dart:320-321`），所以日文版与台版《化物語》落进同一个刮削组、匹配同一个 MangaBaka 系列；每卷封面一律拉日文：`fetchSeriesImages(seriesId, type: 'volume', language: 'ja')`（同文件 :872-877）。中文版第 N 卷因此拿到日文版第 N 卷的封面，只要那张比书里内嵌的中文封面大 1.2 倍就会写进刮削层、替换掉显示的封面。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — 建议在 book art 的计划 / 选图层加纯函数测试：`zh` 的书不选 `ja` 封面（MangaBaka 有该语言的卷封面就用该语言，没有就保留本地内嵌封面）。
- **备注**：
  - 与 BUG-5265 同一个根：系列身份不含语言。但本条独立于合集——刮削按书名分组，书不在合集里也会中。
  - 修法方向（未拍板）：分组键加主语言；按书的语言请求卷封面（`language: <书的主语言>`），该语言没有时不拿别的语言的封面盖掉本地封面（横幅不分语言，可共用）。
  - MangaBaka **追踪**（进度同步）不算 bug：追踪的是作品而不是版本，两个版本读到的卷都计入同一个条目是合理的；系列级链接（PR #4196，未合并）按「已读完的最高卷」发送、不倒退，跨版本取最大值符合预期；develop 上的逐卷链接同样只增不减（`media_tracking_service.dart:597`「同步只会增加远端进度」）。合集级「不追踪」会同时覆盖两个版本，属于 BUG-5265 的影响。
