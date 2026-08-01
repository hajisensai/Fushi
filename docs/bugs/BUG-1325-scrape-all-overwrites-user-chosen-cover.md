## BUG-1325 · 「全部刮削」会把用户手动纠正过的封面一并覆盖
- **报告**：2026-08-01（用户原话：「所以『全部刮削』会把你手动纠正过的一并覆盖，修复这个问题」）
- **真实性**：✅ 真 bug（数据破坏级：用户的人工纠正被无人值守流程冲掉）

  **根因：封面来源标记把「用户亲手选的」和「程序自动刮的」记成了同一个值。**

  - 用户在匹配弹窗里点「使用」某候选 → `applyCandidateToBooks` → `_applyCandidate`
    写 `CoverMeta(origin: CoverOrigin.scraped)`
    （旧代码 `hibiki/lib/src/media/video/scraper/cover_scraper_service.dart` 的 `_applyCandidate`，
    调用点 `hibiki/lib/src/media/video/cover_ui/cover_match_dialog.dart:354`）；
  - 后台自动刮削 high 命中落盘 → `_applyResolved` → 同一个 `_applyCandidate` →
    **同样**写 `CoverOrigin.scraped`；
  - 于是 `cover_meta.json` 里两者**同形**，系统事后分不出哪张封面是人选的；
  - 整库刮削的保护判据只挡 `manual` / `sidecar`，`scraped` 在 `rescrapeScraped: true`
    下整体解锁 → 用户手动纠正过的封面被一起覆盖。

  **号称的兜底靠不住**：别名缓存 `_resolveAliasCandidate` 用 `parsed.title` 重搜该源、
  再按 entryId 过滤取回用户当初选的条目；而用户会去手动纠错**正是因为**文件名标题搜
  不出正确条目——重搜命中不到 → 返回 null → 直落模糊匹配 → 照样覆盖。
  **兜底恰好在最需要它的场景失效。**

  只把覆盖门槛提高到「标题一模一样且全库唯一」是治标：门槛再高也仍在猜，
  真正缺的是「这张封面是谁定的」这个事实本身。

- **[x] ① 已修复** — 给封面来源按**决定者**分开做标记（根治，不是收紧门槛）：
  - `hibiki/lib/src/media/video/scraper/scraper_types.dart`：`CoverOrigin` 拆出
    `autoScraped`（程序自动刮到）与 `userScraped`（用户在弹窗里亲手选定）两个值；
    旧值 `scraped` 降级为**存量专用**（读不出决定者的历史记录），新代码不再写入。
    同文件新增 `CoverOverwritePolicy` + `CoverOriginBatchPolicy.batchOverwritePolicy`：
    「能不能被批量覆盖」由来源唯一决定，穷尽 switch，新增来源时编译器逼着人做决定。
  - `cover_scraper_service.dart`：`_applyCandidate` 的 `origin` 改成**必填**参数——
    `applyCandidateToBooks`（唯一由用户拍板的路径，含合集分发）传 `userScraped`，
    自动匹配与别名命中传 `autoScraped`。
  - `cover_scraper_service.dart` 的 `scrapeLibrary` 是**唯一**的覆盖决策层
    （后台自动刮、页头「全部刮削」都过这里，不在任何单个 UI 入口挡）：
    `manual` / `userScraped` / `sidecar` → 永不覆盖，**与覆盖开关无关**；
    `autoScraped` → 只有 `rescrapeScraped: true` 才覆盖；
    `autoFrame` / 无记录 → 随时可覆盖；
    存量 `scraped`（来源未知）→ 即便开了覆盖开关，也必须过「唯一归一化精确标题」。
  - 存量口径：历史记录**一律按「来源未知」处理**，不猜、不回填、不迁移，
    走 `legacyStrict`——宁可少刮一本，也不改掉可能是人选的那张。
  - `home_video_page.dart` 不再自己传 `requireUniqueExactTitle`：页面只表达「用户显式
    要求重刮」，判据留在 `scrapeLibrary` 一层，避免两处各说一套。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/scraper/cover_scraper_service_test.dart`：
  用户手选封面在「全部刮削 + 覆盖开关打开」下不被覆盖（且保护标记不被抹掉）/
  `applyCandidateToBooks` 落的是 `userScraped` / 自动刮来的旧封面在开关打开时**会**被更新
  （防把功能一起挡死）/ 开关关着时不动 / 存量未知来源仍走唯一精确闸门四例 /
  自动刮削路径（`autoFrame`）判据不变（防过度收敛）。
  接线守卫 `hibiki/test/media/metadata/scrape_all_entry_guard_test.dart`。已做变异实测。
- **备注**：
  - 该来源标记落 `video_covers/cover_meta.json`（`CoverMetaStore`），**不是** Drift 列，
    因此本修复无 schema 变更、不占迁移步号。
  - 书 / 漫画域批量刮削已有 override 封面就整本跳过，游戏域批量传
    `replaceExistingCover: false`，两域天然不覆盖用户已有封面；本 bug 只在视频域成立。
  - 同批顺带修的另两处（都在本 PR 自己新增/改动的代码里，未合入 develop 前发现）：
    1. `hibiki/lib/src/media/metadata/scrape_batch.dart` 的计数吞没——收尾动作抛错会把
       已真实写盘的累计计数整个换成 `failed: 1`，500 本已落盘会显示成「应用 0 / 失败 1」。
       改为沿用最后一次进度回调的累计值，非条目级异常只进错误日志，不伪造条目计数。
    2. `hibiki/lib/src/mining/galgame_scrape_dialog.dart` 的 `_downloadScrapedCover`：
       新增 `replaceExistingCover` 时把 `await File(existingPath).exists()` 写成了**无条件**
       求值，显式覆盖路径（`replaceExistingCover: true`，即弹窗里点「使用」）根本不消费它，
       却因此多插一轮真实文件 I/O，打破 develop 既有用例
       「封面下载失败静默降级」（`galgame_scrape_dialog_test.dart:253`，pumpAndSettle 超时）。
       改成惰性求值后显式路径与 develop 语义逐字节一致。
