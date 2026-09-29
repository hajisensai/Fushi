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
- **[x] ③ 二期：下载确认的身份持久化（同日）** — 只靠任务重试不够：Jikan 宕机常以小时计，6 次退避（约 10 分钟）用完仍会落 failed；而库内补刮既按标题搜（用不上下载确认的身份），又把任何失败记成「已尝试」挡 7 天。根治：
  1. `packages/fushi_engine/lib/media/video/download/download_confirmed_identity.dart`：「任务 → 作品」判据（`downloadJobWork`，合集 id / 唯一路径匹配 / 多电影只给主片）从管线抽出成共享函数，管线 scrape 阶段与刮削协调器共用；`downloadConfirmedLookupsForWorks` 按落地文件反查任务身份（多任务身份不一致则不选）。
  2. 协调器 `_scrapeSourceUnlocked`：作品没有规范身份（`hasCanonicalVideoMetadataIdentity`，与补刮同一判据）且调用方没显式给身份时，按下载确认的身份直取——补刮 / 整源刮削不再对下载来的作品按俗称搜。已有规范身份的作品不覆盖。
  3. 补刮：下载确认过身份的作品即使标题是集号标签也进批次；只因资料源临时不可用失败的作品（`SourceScrapeIssue.workKey` + `providerUnavailable`）撤出记账（`VideoScrapeSweepLedger.forgetAttempts`），下次触发就重试。
  4. 管线：临时故障重试次数用完 → 下载任务 completed（文件已入库），刮削交给补刮；不再落 failed 留一个永远不会自己好的「出错」。
  测试：`fushi/test/media/video/download/download_confirmed_identity_test.dart`（6 条）、`fushi/test/media/video/metadata/download_confirmed_identity_coordinator_test.dart`（2 条，变异实测：去掉注入正向用例变红）、`video_library_scrape_sweep_test.dart`（+2）、`video_download_pipeline_service_test.dart`（+1 用完判 completed）。
- **备注**：本修复之前已落在 needsAttention 的旧任务仍需在下载面板点一次重试（或等补刮：它现在会用那条任务确认的身份）。刮削时主源 504 而任务身份里另有 TMDB id 时仍不换源——那是「用户确认的身份失败不回退」的既有约定，靠重试与补刮收敛。
