## BUG-2430 · 发现页失败横幅印原始 provider id 且不分失败类型

- **报告**：2026-09-10（用户截图：搜索时横幅「部分来源暂不可用，已显示其余结果」，右端标 `mal`；
  用户疑问「搜索的时候显示 mal 失败，外面显示 anlist」）
- **真实性**：✅ 真 bug，但**不是**标识取错。AniList 结构性地不参与搜索
  （`fushi/lib/src/media/video/discovery/video_discovery_service.dart:73-76` 的 `searchProviderIds`
  只由 metadata catalog 生成 = `{mal, tmdb}`，过滤在 `:275-282`；守卫
  `fushi/test/media/video/discovery/video_discovery_aggregated_sources_guard_test.dart:45` 把这条钉死），
  用户在页面别处看到的 AniList 是本季/放送 feed 那条路径。真正的缺陷是横幅的两处表达。

### 根因

1. **同域两条 failure 翻译路径**：TMDB / AniList 走
   `video_discovery_adapters.dart` 里认得 `VideoMetadataNetworkException` 的私有 `_providerFailure`
   （429 → `rateLimited`，带 `statusCode` / `retryAfter`）；MAL 走
   `video_metadata_discovery_provider.dart:104` 的裸 `ExternalProviderFailure.fromException`，
   它只认 `TimeoutException` / `ClientException` / `FormatException`，其余一律压成 `unknown` 并丢掉状态码。
   MAL 经 Jikan 公共接口、1 秒一发且 `maxAttempts: 1` 不重试（`mal_video_metadata_provider.dart:26-31`），
   429 是常态——于是「被限流，等一会儿再搜」被显示成「来源暂不可用」，用户会跑去设置页找一个不存在的开关。
2. **横幅印 provider id 而非品牌名**：`video_discovery_page.dart:913-914,936` 直接
   `failure.providerId`（`mal`），与页面别处的品牌名不是一个口径（漫画发现页是走 displayName 的）。
3. **文案不看失败性质**：`video_discovery_page.dart:793` 只判 `_failures.isNotEmpty`，一句「暂不可用」通吃。

### 修复

- **[x] ① 已修复** —
  翻译逻辑提成全域唯一一份 `externalFailureFromVideoMetadataError()`
  （`fushi/lib/src/media/video/metadata/video_metadata_transport.dart`），MAL 那条路径改用它；
  `VideoDiscoveryProvider` 接口新增 `displayName`（编译期强制每个来源给出品牌名，MAL/TMDB 复用既有
  `videoMetadataProviderLabel`），经 `VideoDiscoveryService.displayNameFor` 与
  `VideoDiscoveryController.displayNameFor` 端口透出给页面；横幅文案按 failure kind 分三档
  （限流/配额 → 稍后再试；不可用/鉴权/不支持 → 暂不可用；其余 → 暂时请求失败）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/discovery/video_metadata_discovery_failure_kind_test.dart`
  （429 → rateLimited 且带 status/retryAfter、401/503/404 各归其类、非传输异常走通用分类、displayName 非 id）
  + `fushi/test/pages/video_discovery_page_test.dart` 三条横幅用例（印显示名不印 id、限流文案、真不可用仍说不可用）。

### 备注

未在本次修复范围内、但值得注意：番剧/动漫类目下 TMDB 因 categories 只有 movie/tv 被滤掉
（`video_discovery_adapters.dart:44-47`），实际只剩 MAL 一个搜索源，它一失败结果就全空。
