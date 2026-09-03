## BUG-1782 · Jimaku 搜索时好时坏：AniList 失败被静默吞成空结果，退化成跨季文本搜索

- **报告**：2026-08-23（用户：截图两张 + 「更新之后筛选怎么坏了 之前没问题的」，紧接着「起了怪了，现在又行了 不知如何触发」；Windows debug rolling `12067-075d4f3`）
- **真实性**：✅ 真 bug（根因不是「更新引入」，是一条**一直存在**的静默降级路径；用户观察到的「时好时坏」正是它的指纹）

### 症状

「获取字幕（Jimaku）」搜 `Yuru Yuri`，结果区把四个不同季/系列的 entry 平铺在一起（`Yuru Yuri` / `Yuru Yuri San Hai!` / `Yuru Yuri♪♪` / `Yuru Yuri Nachuyachumi!+`），按 E01/E02/E03 交替排列。过一会儿又自己好了，用户找不到触发条件。

jimaku.cc 上这五个 entry 确实各自独立存在，所以多 entry 是数据侧的真实情况——问题在于**这次搜索本该用 anilist_id 直查、只命中一个 entry**。

### 根因

`fushi/lib/src/media/video/anilist_client.dart:270-294`（修前）的 `searchAnime`：

- `:284` `if (res.statusCode != 200) continue;` —— 含 **429 rate limit**；
- `:290` `catch (_) {}` —— 裸吞，连日志都不打；
- `:294` 最终 `return const <AniListMedia>[]`。

于是**「AniList 说没有这部番」与「这次根本没问上」共用同一个空列表**，调用方无从区分。链条：

```
AniList 挂/被限流 → searchAnime 返回 []
  → _search() 传 anilistId: media.isNotEmpty ? media.first.id : null  = null
  → provider searchEntries(anilistId: null)
  → JimakuClient.searchByQuery("Yuru Yuri")   ← 文本回退
  → jimaku.cc 上 5 个 entry 全量平铺
AniList 恢复 → searchByAnilistId → 单 entry → 「现在又行了」
```

同一份代码两种结果，**无任何用户可见信号，也无日志可查**——这就是「不知如何触发」。

限流预算的现实来源：`AniListClient` 被放送日历页共用（`airing_calendar_page.dart`），它按 `perPage: 50` 翻页拉 airingSchedules。讽刺的是同一个 client 里 `fetchAiringSchedulePage` **明确不吞 429 并上抛**（`anilist_client.dart:178`/`:322` 的注释把这个「有意不同」写死了），于是日历烧掉配额、字幕搜索静默降级。

截图侧佐证：AniList 空 ⇒ `_seriesMatches` 空 ⇒ 系列消歧区不渲染（要求 ≥2 条）。用户截图左栏正没有系列列表，是 AniList 空的指纹。而这意味着**用户在最需要消歧的那一刻，恰恰拿不到任何消歧手段**。

同族第二触发条件（此时系列列表**会**出现）：AniList 有结果，但盲取的 `media.first` 那一季的 Jimaku entry 没挂 anilist_id → `searchByAnilistId` 空 → 同样回退文本 → 同样平铺。

**已排除的假设**（逐条给了依据，见调查记录）：`_selectedSeriesId` 未重置（`_search()` 开头就清，且对话框每次 `showDialog` 新建）；候选被缓存（搜索路径无任何缓存层）；手敲番名 vs 元数据带入走不同分支（两者都只是 `_queryCtrl` 的值）；Jimaku `anime` 硬过滤（BUG-1694）相关（Yuru Yuri 是动画不会被滤）。

### 修复

- **[x] ① 已修复** — commit `<填>`
  - `anilist_client.dart` 新增 `AniListSearchOutcome{media, failure}`；`searchAnime` 改为返回它，**空结果与失败不再共用同一个返回值**。失败判定按「**所有**候选查询都没能给出成功响应」（`anySuccess` 而不是 `lastFailure` 决定）：只要有一次拿到 200 并解析成功，哪怕结果为空也算「AniList 明确答了没有」，避免把「先答了没有、后一个保守回退词 429」误报成降级。
  - `jimaku_subtitle_dialog.dart`：降级时记 `ErrorLogService.logDiagnostic`（与 Jimaku 侧既有诊断口径一致，此前**这条路径零日志**），并在结果区顶部如实告知「这次没能确认系列，结果可能混入同系列其他季」+ 就地重试。**不改结果本身**——回退结果仍然有用，总比什么都不给强；只是不再让降级和正常长得一模一样。只有降级时才多包一层，正常路径 widget 树与改动前一致，不碰 BUG-279 的有界高度/滚动不变量。
  - `anime_download_dialog.dart`：非 200（含 429）此前被吞成空列表、走不到它自己的 catch，于是**限流被显示成「无结果」**；现在如实并入既有失败态，用户拿到重试 + 原因。这是同一根因在另一个入口的第二个受害者。
  - `jimaku_batch_dialog.dart`：同样在降级回退前留诊断日志。
  - i18n 经 `i18n_sync --add` 加 1 键 × 17 语言 + `dart run slang` 重生成。
- **[x] ② 已加自动化测试** — commit `<填>`
  - `fushi/test/media/video/anilist_client_test.dart` 新增 5 条：`200 空结果 = 明确答了没有，不是降级` / `429 限流 = 降级且带得出原因` / `网络异常 = 降级` / `先失败后成功：只要有一次问上了就不报降级` / `先成功答没有、后一个回退查询 429：仍不报降级`（后两条正是锁 `anySuccess` 语义）。
  - `fushi/test/pages/jimaku_series_lookup_degraded_test.dart` 新增 2 条 widget 用例（候选复刻用户截图的跨季混排）：降级时提示条 + 重试可见且**不顶掉结果列表**；正常时不显示提示（不吓唬用户）。为此加了 `debugInitialSeriesLookupFailed` 注入点，与既有 `debugInitialCandidates` / `debugInitialSeriesMatches` 同款。
  - **变异实测**：① 把 `searchAnime` 的非 200 分支改回 `continue`（旧的静默吞）→「429 限流 = 降级」精确转红，还原后 `anilist_client.dart` sha256 `ecebe9598acd9a58afd6c6a3c314aca5eec2d363f148352d8c8523cbe6ed9437` 一致；② 把提示条条件改成 `if (true || …)` → 降级用例转红，还原后 `jimaku_subtitle_dialog.dart` sha256 `8a666cb95a476c679cd1c6a1ef6def9130ba18279ee94ecc332d99662698ca40` 一致。
  - 邻域回归：10 个 Jimaku / AniList 测试文件经 `flutter_test_failures.dart` 跑出 `VERDICT: PASSED - 71 tests ran`。

### 备注（本次未修，但同一条链上的真实缺口）

1. **入口就把身份扔了**（治本项，值得独立 PR）。`_jimakuQuery()`（`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart:672-689`）只从 `parseVideoFilename(basename).series` 取**文本**，`JimakuSubtitleDialog` 构造器压根没有 `anilistId` 参数——明明库里存着刮削身份（`video_metadata_works` + `video_metadata_provider_identities`，已有 DAO `getVideoMetadataProviderIdentities(workId:)`），手动入口还要拿文件名去 AniList 猜一遍。**带上 anilistId 后 AniList 挂掉也不影响这条路径**，比本次的「让降级可见」更根治。
   对照组：自动补字幕路径做对了——`scrapedMediaReference`（`fushi/lib/src/media/video/subtitle/scraped_subtitle_targets.dart:68-100`）原样带 anilistId / originalTitle / discoveryCategory，其文档注释写着「缺一件准确率就塌一层」。**两条路径对同一问题给了相反的答案。**
2. **整条字幕链零相关度排序**。`deduplicateVideoSubtitles` 只按 providerPriority → downloadCount；`buildSubtitleVersionGroups` 只按语言 → 机翻 → 上传时间 → 下载量，**没有任何标题/季号贴合度**。所以即使有了 B1 的版本卡，错季的卡照样能压在正确季前面。现成可复用：BUG-1548 已为资源搜索造了同形状的 `parseVideoResourceIdentity` / `rankVideoResourcesByRelevance`（`fushi/lib/src/media/torrent/video_resource_relevance.dart`），从未接进字幕链路。
3. 用户说的「更新之后坏了」是归因不是事实：`for (entry in entries)` 的平铺从 2026-06-05 首版就在，`v2.0.0..v2.1.1` 之间这几个文件零改动。真正变的是 AniList 那边通不通。
