## BUG-2433 · 合集右键重新刮削对单成员/无集号合集必然死胡同
- **报告**：2026-09-10（用户：截图——视频库页合集卡上弹出「这个合集不在任何本地视频来源的刮削计划里」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/metadata/video_library_scrape_sweep.dart:50`（旧 `planScrapeWorkForCollection` 只按 `work.stableKey == 'collection:<id>'` 字面匹配）。

  计划器 `VideoSourceWorkPlanner.plan`（`fushi/lib/src/media/video/metadata/video_source_work_planner.dart:57`）对同一个合集有**两种同样合法**的表示：成员数 ≥2（`collection_member_policy.dart:41` 的 `multiMemberCollectionIdByVideoUid`）**且**文件名解析出集号（`video_source_work_planner.dart:88`）时，整个合集是一个 `collection:<id>` 单元；否则每个成员各自是一个 `book:<uid>` 单元。单成员合集、剧场版合集、目录合集（`sourceFolderPath != null`）全部落在后者。

  旧查询只认前者，于是对后者一律返回 null，调用方 `_rescrapeCollection`（`fushi/lib/src/pages/implementations/home_video_page.dart:6443`）弹一句 toast 就 return——**而且这句提示是假话**：成员明明在刮削计划里，只是以 book 单元的形式。用户拿到的是一条无出路的死胡同。

  用户真实数据（读 `D:/APP/HIBIKI_date/support/fushi.db` 快照实测）：合集 68「Kimi no Na wa 播放列表」`playlist`，**成员恰好 1 个** `video/Kimi no Na wa - S00E01`（`source_id=3`，video/local/`series` 模式，路径 `D:\video\Kimi no Na wa\Season 00\Kimi no Na wa - S00E01.mkv`）；`video_metadata_works` 里 `collection_id=68` 无行，该成员有一条 `book_uid` 锚定行。单成员 → 被 ≥2 判据剔除 → 计划里只有 `book:video/Kimi no Na wa - S00E01`。

  **不能用「放宽计划器判据、让合集始终成为作品单元」来修**（调查结论，三条独立的破坏性）：
  1. `video_metadata_works` 的 `collectionId` / `bookUid` 是互斥锚定（`packages/fushi_core/lib/src/database/tables.dart:1601` 的 `CHECK`），而 `_hasCanonicalIdentity`（`video_library_scrape_sweep.dart:179`）只按 `work.collection != null` 二选一、无回退 → 历史已刮的单成员合集会被判「从未刮过」重新补刮；落库时 `_removeBookOwnedWorksForCollection`（`video_metadata_database_store.dart:166`）按成员 bookUid 物理 DELETE 旧行（identities/seasons/episodes cascade），且 `existingWork` 查不到导致**用户字段锁失效**。
  2. `collection != null` 会把 `kind` 强制成 tv（`video_source_scrape_coordinator.dart:798`），而 resolver 有硬类型门（`video_metadata_resolver.dart:458/475`）→ 剧场版按电视剧搜，movie 条目全被拒 → notFound。
  3. 无集号成员在合集单元下会被静默跳过、不写任何 `VideoScrapeMeta`（`video_metadata_database_store.dart:986`、`:924`），比原先作为独立 movie 单元时更差；海报归属还会与 `collection_member_policy.dart` 的「单成员合集不受影响」口径打架。

  另有既有测试 `fushi/test/media/video/video_source_work_planner_test.dart:96`「任意多片 m3u 合集不会被误判为电视剧作品」明确钉死了这条设计意图。所以根因在**查询的定位方式**，不在计划器。

- **[x] ① 已修复** — `planScrapeWorkForCollection` → `planScrapeWorksForCollection`，改按**成员归属**定位并返回候选列表：存在合集级单元就只返回它（既有行为一字不变），否则返回该合集成员对应的全部 `book:<uid>` 单元。调用方三分支：0 个 → 保留提示（此时才是真话）；1 个 → 直接走原绑定 + 重刮；N 个 → 弹选择列表（新增 `collection_rescrape_pick_work`），不再默选第一个也不再死胡同。搜索种子在「整个合集就是这一个作品」时改用合集名（成员标题可能是 `S00E01` 这种纯集号标签）。计划器、stableKey、canonical 锚定、封面归属**一律未动** → 零数据迁移、零回归。提交 `c81ba126bc`
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_library_scrape_sweep_test.dart`：单成员合集回落 book 单元（按用户真实数据形状构造）、多片无集号合集返回全部候选、合集级单元存在时只返回它、非 local 来源返回空、以及既有三条改成列表口径。共 16 条全绿。
- **备注**：多候选的选择列表是同一条路径的另一半死胡同（多片播放列表、目录合集右键重刮原本同样只能拿到那句 toast），一并修掉。
