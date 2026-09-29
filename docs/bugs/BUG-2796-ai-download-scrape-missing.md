## BUG-2796 · AI下载后作品页尚未刮削
- **报告**：2026-09-30（用户：AI 下视频下完「FX戦士くるみちゃん」第 1 集，作品页「尚未刮削详细资料」；发现页状态行「出错 · 保存资料中」；放送中作品没问下载还是订阅）
- **真实性**：✅ 真 bug，三个独立根因（用户库只读核实：任务 `523afaf0…` `stage=scrape lifecycle=needsAttention last_error=…VideoMetadataNetworkException(504): MAL anime/63337/full HTTP 504`，身份含 mal 63337 / tmdb 311842）：
  1. 刮削阶段任何失败一律 needsAttention（`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart` `_processWithLease` 的 `job.stage == scrape` 分支）；解析器 `providerUnavailable` 把「没配置」与「网络 504」混成一个状态（`video_metadata_resolver.dart` `_attempt` / `_resolveLookup`），管线无从区分临时故障。
  2. 单集合集按单集刮（资料挂在 bookUid 上，计划器有意为之），作品页 / 演职员 / 字幕检索只按合集查（`getVideoMetadataWorkByCollection`），刚下完第一集的剧集页永远查不到。
  3. 意图提示把「download / get」都映射成 `mode=download`（`fushi/lib/src/ai/ai_video_acquisition_assistant.dart`），「帮我下X」就把模式填死，reducer `_decideMode` 不再问。
- **[x] ① 已修复** —
  1. `VideoMetadataResolution.transient`（只有网络类异常且非 4xx 才为 true，判据 `isTransientVideoMetadataFailure` 在 `video_metadata_transport.dart`）→ `_ResolvedWork.transient` → `SourceScrapeIssue.providerUnavailable` → `SourceScrapeReport.failedOnlyBecauseProviderUnavailable`；管线抛 `VideoDownloadScrapeProviderUnavailable`，刮削阶段仅此一种走任务已有的指数退避（最多 maxAttempts 次，用完落 failed）。「没配置」照旧 needsAttention。
  2. `FushiDatabase.resolveVideoMetadataWorkForCollection`（`packages/fushi_core/lib/src/database/database_video_domain.part.dart`）：合集行优先，没有时视频成员上恰好一条作品行即是；多条不猜。只读消费方（作品详情页、演职员仓库、字幕合集面板、播放页字幕检索种子）切过去；写路径（upsert 回读、索引器、TMDB 排序选择）不动。
  3. 提示词：只有明确「只要现有的 / 不用追」才填 download，「帮我下X」不填 mode，交给 reducer 按放送状态问。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_metadata_resolver_test.dart`（504 → transient、404 / 没配置 → 非 transient）、`fushi/test/media/video/download/video_download_pipeline_service_test.dart`（504 → 退避重试不停 needsAttention；既有「没配置 → needsAttention」用例不变）、`packages/fushi_core/test/video_metadata_v77_test.dart`（resolveVideoMetadataWorkForCollection 4 条）、`fushi/test/ai/ai_video_acquisition_assistant_test.dart`（mode 提示契约）。
- **备注**：已落在 needsAttention 的旧任务不会自动重试（需要用户在下载面板点重试，或等下一集下载时重刮）。刮削时主源 504 而任务身份里另有 TMDB id 时仍不换源——那是「用户确认的身份失败不回退」的既有约定，这里只让它稍后重试。
