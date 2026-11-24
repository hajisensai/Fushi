## BUG-5398 · 双语书名（罗马字 + 日文）的系列永远拿不到 Bangumi 候选
- **报告**：2026-11-23（用户要求验证「获取各卷封面与横幅」每个来源都能用；实网核对合集「Horimiya ホリミヤ」：MangaBaka 有候选，Bangumi 一个都没有）
- **真实性**：✅ 真 bug（根因两处：`fushi/lib/src/media/metadata/book_art_scrape_service.dart:1178` `_bangumiSearch` 只用全名搜一次；`packages/fushi_engine/lib/media/metadata/book_art/book_art_matcher.dart:437` 标题档位只拿整名比）
- **[x] ① 已修复** — Bangumi 与 MangaBaka 用同一查询序列（全名 → 双语书名的日文段 → 去副标题）；双语书名整名对不上时，任一段对得上给 `localExtends`（最多待确认）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/metadata/book_art/book_art_matcher_test.dart`（拆段、档位封顶）；`fushi/test/media/metadata/book_art_scrape_service_test.dart`（查询序列；Bangumi 全名零结果时改用日文段搜到候选）
- **备注**：实网（2026-11-23）：Bangumi `POST /v0/search/subjects` 搜「Horimiya ホリミヤ」total 0、「Horimiya」total 0、「ホリミヤ」命中系列 51158。修复后同一合集待确认列表里有 MangaBaka 6029 与 Bangumi 51158，分别钉死都能写入两卷封面（MangaBaka 另带横幅；Bangumi 不提供横幅）。

### 根因

1. **搜索**：Bangumi 是关键词精确搜索，双语书名的全名与罗马字段都是零结果；MangaBaka 有查询序列（全名 → 去副标题），
   Bangumi 只搜全名一次。
2. **比对**：`compareBookTitles` 只认「本地 = 候选」「一方是另一方 + 分隔符 + 副标题」。`Horimiya ホリミヤ` 对 MangaBaka 的
   `Horimiya` 是 `localExtends`（待确认），对只有日文原名 `ホリミヤ` 的 Bangumi 条目是 none——即使搜到也进不了候选。

### 修复

- 引擎 `bilingualBookTitleParts(title)`：按空白分词，日文段（含假名 / 汉字的词）与拉丁段都非空、且没有夹数字 / 符号词才算双语。
- 引擎 `localBookTitleTier(local, remotes)`：整名档位优先；整名 none 且是双语书名时，任一段对得上给 `localExtends`。
  只增加候选，不抬成自动采用（与 MangaBaka 对同一本书的现有档位一致），`assessBookArtCandidate` 改用它。
- `_queries` 在全名后加双语书名的日文段；`_bangumiSearch` 按序列逐个搜、合并结果，出现值得拉卷的系列候选就停；
  全部 404 时仍按「没有 Bangumi 结果」处理，有回应但零结果时照旧交给判定（rejected）。
