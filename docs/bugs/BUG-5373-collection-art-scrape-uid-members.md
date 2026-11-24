## BUG-5373 · 合集「获取各卷封面与横幅」对按 uid 存的成员一本都认不出
- **报告**：2026-11-23（用户：合集「Horimiya ホリミヤ」点「获取各卷封面与横幅」，结果只有「0 covers updated, 0 kept, 0 failed」，没有任何系列行，横幅也没有）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/metadata/book_art_scrape_service.dart:343` `collectionBookKeys` 把合集成员行 `entryKey` 直接当 bookKey 交给 `run()`，`run()` 里 `getEpubBook(key)` 按 bookKey 查不到就 `continue`；v83 起 epub 成员行 `entryKey` 是 `epub_books.uid`）
- **[x] ① 已修复** — `FushiDatabase.resolveEpubBookKeysForMembers`（成员行键 → bookKey 批量换算，uid 与 v83 前的 bookKey 都认），书图刮削的四个合集入口统一经 `collectionMemberBookKeys` / `epubMemberBookKeys` 取 bookKey
- **[x] ② 已加自动化测试** — `fushi/test/media/metadata/book_art_scrape_service_test.dart`（uid 成员 + 存量 bookKey 成员 + 远端透传 + 视频成员：刮削写入、横幅按成员读回）；`fushi/test/media/collections/collection_art_scrape_clear_test.dart`（uid 成员 Enter 确认后刮削层清掉）
- **备注**：现场库核对：该合集两条 epub 成员与 `epub_books.book_key` 0 条匹配、与 `uid` 2 条匹配。MangaBaka 系列 6029 确有可用横幅（1915×645、safe、webp），修好后能取到。

### 根因

v83 把合集成员表 epub 域的 `entryKey` 从 bookKey 换成稳定 uid，其余消费者（标签、隐私 / 上锁、
作品图谱、书架折叠、有声书演员表、条目刮削等）都已按 uid 读或先 `resolveEpubBookKeyByUid`。
书图刮削（每卷封面 + 横幅，刮削层 `BookArtStore` 按 bookKey 记）的合集入口没跟上，四处都把
`entryKey` 当 bookKey：

- `BookArtScrapeService.collectionBookKeys`（界面按钮与 ops `POST …/scrape-art` 共用）：`run()`
  一本书都认不出 → 没有系列组、不发任何请求，结果面板只剩空的汇总行。
- `CollectionArtScrape.bannerFor`：按 uid 查刮削层 → 合集详情页永远拿不到横幅。
- `CollectionArtScrape.clear` 与 ops `DELETE …/scrape-art`：按 uid 找刮削层 → 一本都删不掉。

MangaBaka 与 Bangumi 两个来源都在 `run()` 之后，所以两个来源同时失效；问题不在来源本身。

### 修复

- `fushi_core`：`resolveEpubBookKeysForMembers(entryKeys)` 一次查出成员行键对应的 bookKey
  （`uid IN … OR book_key IN …`，分批绑定参数），远端透传行不在结果里。
- `book_art_scrape_service.dart`：`collectionMemberBookKeys(db, id)` / `epubMemberBookKeys(db, rows)`
  作为唯一换算口；`collectionBookKeys`、`bannerFor`、`clear`、ops 清除路由都走它。
- 合集详情页横幅改为异步算：`_reload` 在 setState 前算好；刮削层变更时按当时的成员重算，
  算完成员已被 reload 换掉就丢弃。
