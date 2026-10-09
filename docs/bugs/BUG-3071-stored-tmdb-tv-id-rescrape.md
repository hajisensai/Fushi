## BUG-3071 · BUG-2828存量未修：重刮仍复用存成movie的TMDB tv id，リズと青い鳥仍是挪威电影
- **报告**：2026-10-09（用户：「リズと青い鳥 刮削错了」。在含 BUG-2828 修复的 2.10.0-debug.18353 上经互联 `POST /api/library/metadata/scrape` 以 `anidb:13491 movie` 重刮，结果仍是 TMDB movie 62564「Turn Me On, Dammit!」：2011、挪威语、76 分钟、imdb tt1650407）
- **真实性**：✅ 真 bug。BUG-2828 只修了「从 Fribb 映射取 id」那一路，记录里「存量作品在修复版里重刮一次就会改绑」不成立：
  - `video_metadata_provider_identities` 只存 `provider` + `externalId`，没有 TMDB 命名空间；`video_metadata_database_store.dart` 的 `lookupsForWork` / `confirmedLookup` 把每行按作品形态（movie）还原成 lookup——旧 bug 绑错的 `tv 62564` 于是以 `/movie/62564` 回来。
  - `video_source_scrape_coordinator.dart` `_resolveWork`：同一 AniDB id 重刮 `changedIdentity == false`，存量交叉引用全数进 `identityHints`，`tmdbLookupHint` 先被它占住，`tmdbLookupHint ??= _tmdbLookupFromMapping(...)` 根本不跑（BUG-2828 的命名空间判断被整个绕过），`_preserveTmdbIdentity` / `_tmdbSupplement` 照它拉 `/movie/62564` 再写回——每次重刮都自我复制。
  - BUG-2828 的测试全从「没有存量身份」起步，覆盖不到这条路。
- **[x] ① 已修复** — `_tmdbHintContradictsMapping`：主身份（MAL / AniDB）在映射里明确把这个 TMDB id 放在另一个命名空间时，存量 / NFO 带来的 TMDB 提示判为绑错、丢弃并留警告，再走映射 / 标题补充；映射没收这部或没给 TMDB 时不动（标题搜到的交叉引用照样可信）。映射查询抽成 `_mappingEntries`，与 `_tmdbLookupFromMapping` 共用。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/offline_identity_coordinator_test.dart`「rescrape drops a stored TMDB id that the mapping places in the other namespace (BUG-3071)」：第一轮用「62564 是电影」的映射造出绑错存量，第二轮用真实 `{tv: 62564}` 映射重刮，断言不再拉 62564、身份表不再写回（变异实测：去掉丢弃即红 `Actual: ['62564']`）。
- **备注**：根治是给 TMDB 交叉引用落命名空间（identity 表加列 + 迁移），涉及 schema 版本，另立；本修复用映射做矛盾判定，覆盖了 Fribb 能判的全部动画存量。用户库里的 リズと青い鳥 需在含本修复的版本再重刮一次（或等补刮）才会改绑到 TMDB movie 482150 / tt7089878；旁边 Fushi 自己写的 `.nfo` 随之重写。
