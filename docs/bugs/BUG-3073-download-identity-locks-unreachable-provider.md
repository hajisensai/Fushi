## BUG-3073 · 下载任务身份被当用户锁定：那家资料源连不上就永远providerUnavailable，不换任务里的TMDB id
- **报告**：2026-10-09（用户：视频页「3 部作品还没确认身份，资料和封面都没刮出来」。三部是 天気の子、ドラえもん のび太とアニマル惑星 (1990)、新魔界大冒険 (2007)；刮削记录全是 `pending:provider_unavailable ai=not_asked candidates=0`，天気の子 报 `MAL anime/38826/full request failed: HandshakeException`——Jikan 从本机连续数日不可达）
- **真实性**：✅ 真 bug。
  - `video_source_scrape_coordinator.dart` `scrapeSource` 把 `downloadConfirmedLookupsForWorks` 的结果并进与调用方显式身份同一张 `lookups` 表，到 `_resolveWork` 已无从区分，成了 `confirmedCanonical`——等同用户锁定：resolver 只按这一家 id 取，网络异常折成 `providerUnavailable` 直接返回，主源 → 兜底源链与标题搜索都不跑。离线索引 / 哈希映射这两种同为「自动证据」的身份早有退路，唯独下载身份没有。
  - `discovery_metadata_identity.dart` 的 `videoDiscoveryMetadataLookup` 只返回首个 id（MAL 优先），任务里同时记着的 TMDB id 从没机会被用。
- **[x] ① 已修复** — 新增 `videoDiscoveryMetadataLookups`（全部可直取 id，首选在前；单数版本取首个，行为不变）与 `downloadConfirmedLookupListsForWorks`（单数版本改为由它派生）。协调器把下载身份放进独立的 `downloadEvidence`，以 `downloadLookups` 交给 `_resolveWork`，与离线索引合成 `automaticLookups`：按序逐个 id 试，全不行再按主源链严格标题搜；形态（movie/tv）仍跟下载身份走。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/download_confirmed_identity_coordinator_test.dart`「下载身份那家连不上 → 换任务里记着的另一个 id（TMDB），不卡在 MAL」（变异实测：退回「并进显式身份表」即红 `Expected: contains '311842', Actual: []`）。
- **备注**：同时出现的「同一作品每分钟重刮十几次」是补刮调度的另一个 bug（批次自己的写入触发下一轮 + 临时失败立即清账），单独记录修复。
