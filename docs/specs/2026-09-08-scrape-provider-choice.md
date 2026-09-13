# 视频刮削 v2：离线标题索引 + 可选主源 + 有序合并 + 多季一张卡

状态：设计稿 v2（2026-09-08），对标 HAMA / MoviePilot / Jellyfin / Sonarr / Taiga / Shoko 后修订，等用户确认后实施。对应用户报告：升 2.3 后动画刮削识别失败增多、多季不归组、希望能选资料源。

## 0. 已核实的事实（Fushi 现状）

- 2.3.0 含 `9e7c1e322d`：MAL(Jikan) 主源 + TMDB 兜底，主源写死；`provider_override` 列存在但被忽略并在保存时清空。
- 识别链只有 MAL「查无 / 不可用」才问 TMDB；MAL 返回 ambiguous 即终止（测试钉死）。Jikan `titles` 只有 Default / Synonym / Japanese / English，没有中文；中文目录名在 MAL 上只能得到一堆标题不符的候选 → ambiguous → 后台记成待确认 = 「识别失败」。
- 纯集号 `01` 也被当标题搜；Jikan 搜索/分集接口本机连探 6 次全 504。
- 合集归属是扫描期按文件名系列名决定，刮削不参与；只剩集号的文件名（`01.mp4`）每集单独成条，但 v2.2.4 同样如此。MAL 真实退化：一个 MAL id = 一季，多季合集只有首季有分集资料。
- 仓内已有但未接进生产的资产：`AniDbTitleCatalog`（AniDB 每日标题包，保留所有语言含 zh-Hans，exact / prefix / similar 三档，磁盘缓存 24h）；`AnimeIdentityMapping`（已拉 Fribb anime-lists，只取 anidb→mal）；文件名标签 `{[tmdbid=…;s=;e=]}` 解析；TMDB 详情已带 `alternative_titles,translations`。

## 1. 对标结论

| 维度 | HAMA (Plex) | MoviePilot | Jellyfin / Shokofin | Sonarr / Taiga | Fushi 现状 | v2 采纳 |
|---|---|---|---|---|---|---|
| 选源形态 | 每字段一条源顺序串 | 识别源单选 + 刮削源单选 | 启用集 × 拖拽顺序 | 单源 (TVDB) | 写死 MAL | 主源二选一（= 长度 2 的顺序表）+ 每来源覆盖 |
| 标题匹配 | AniDB 全语言标题库，不分语言，LCS/Levenshtein 打分 | 归一化后**完全相等**，比较集含 alt_titles 全国家 + translations 全语种 | AniDB 插件要求全库唯一命中 | Taiga：top ≥ 1.0 且无并列才认 | 严格相等，MAL 侧无中文 | 离线 AniDB 标题库先定身份 + 唯一命中；在线侧比较集扩到 alt/translations |
| 搜索策略 | — | 计划表：季年份+季号 → 名+年±1 → 名不带年 → multi，首中即停 | id 有则直拉，无 id 才搜 | — | 单轮 | 采纳计划表 |
| 身份接力 | anidbid 为中枢 | 按名互查 | ProviderIds 接力：先到者拿到 id，后位按 id 直拉 | — | 无 | Fribb 表 anidb↔mal↔tmdb 直接换 id，不二次搜索 |
| 合并 | 标量首个有值、图片叠加、标题按语言 rank | — | 先到者独占、后到者补空、集合并集、简介按语言可覆盖 | — | `primary ?? tmdb`，仅 MAL 主源时补 | 对称补充 + 集合并集 + 简介语言感知 |
| 多季一张卡 | anime-lists `(tmdbtv, tmdbseason, tmdboffset)` | 季年份 == TMDB 某季 air_date 年 | Shokofin：Group→Series，每季一 Season | Sonarr 双键 + 歧义即放弃；Taiga anime-relations 显式集区间重定向 | 无 | Fribb 季/偏移 + anime-relations |
| 用户出口 | `[anidb-123]` 目录标签 | `{[tmdbid=…]}` 标签 + 识别词 | Identify 对话框 | 场景映射表 | 标签 + 手动确认 | 标签加 `malid=`；识别词二期 |

## 2. 身份解析管线（替换现有单轮搜索）

按顺序，任一阶段得到**唯一**身份即停：

1. **显式身份**：文件/目录标签 `{[tmdbid=…;malid=…;anidb=…;type=tv;s=1;e=1]}`（现有解析加 `malid`）、NFO `uniqueid`、已持久化身份 → 按 id 直拉，不搜索（三家一致）。
2. **离线标题索引**（新，HAMA 路线）：候选标题（文件名解析标题、父/祖父目录名；剔除纯集号标签）→ `AniDbTitleCatalog` exact → prefix → similar；要求**唯一** anidb id（Jellyfin AniDB 插件 / Taiga 规则：多命中或并列即视为未命中）→ Fribb 表得 `mal_id` / `tmdb tv id` / `season.tmdb` / `episode_offset.tmdb`。中文目录名在这一步就能定身份，不依赖 Jikan 搜索。
3. **在线搜索**（现有链，改成对称 + 计划表）：主源 → 兜底源；每源按计划表 `季年份+季号 → 名+年(±1) → 名不带年` 首中即停；比较集 = title / original ∪ alternative_titles 全国家 ∪ translations 全语种，归一化（去标点空白、小写、繁→简，现有 `TitleNormalizer`）后相等。只有「唯一精确命中」终止链；主源歧义继续问兜底源；双歧义合并候选交人工。
4. **身份接力**：任一阶段拿到一家 id 后，另一家 id 优先经 Fribb / TMDB `external_ids` 换算，换算不到才用「季年份 + 季号」对齐（MoviePilot 的 Bangumi→TMDB 办法），不再按标题二次搜索。

拒绝规则（Sonarr / Taiga）：多候选并列、区间两端落不同目标、集数未知导致上界不定 → 不自动决定，保留原状标「待确认」。

## 3. 数据与配置

| 项 | 设计 |
|---|---|
| 全局偏好 | `video_metadata_primary_provider` ∈ `mal` / `tmdb`，默认 `mal`（不推翻 09-07 决定）。 |
| 来源级覆盖 | 复用 `provider_override`：NULL 跟随全局；`mal` / `tmdb` 生效；历史值回落 NULL。无迁移。 |
| 兜底映射 | `videoMetadataFallbackProvider`：`mal ↔ tmdb`，其它 null（AniDB 等单源）。 |
| 离线数据 | AniDB 标题包（已有，24h）；Fribb `anime-list-full.json` 7.5 MB（已拉，扩展解析 `thetvdb_id / themoviedb_id / season / episode_offset`，周更）；erengy `anime-relations.txt` ~50 KB（新增，MAL id 集区间重定向，545 条，2026-08 仍更新）；三者都走 `createAppHttpClient`，带 TTL 与失败沿用旧包。 |
| 淘汰 | 不引入 TVDB、不解析 Anime-Lists 的 range 映射（One Piece 类 `a` 型交人工）。 |

## 4. 识别器与协调器

- `VideoMetadataResolveRequest.fallbackProvider`（默认 null = 单源）；`providerChain`；`_acceptsIdentity` 按链。TMDB 补充查询与哈希映射重试仍单源。
- 协调器 `primaryProvider` 缺省取 `config.primaryProvider`；`_EffectiveSourceSettings` 尊重 `provider_override`；手动搜索 / 手动 ID 按来源链；`hasProvider` 链上任一可用；歧义候选 lookup 按 `candidate.provider`；十几处 `== mal` 统一为 `twoSourcePolicy` / `chain.contains`。
- `_titleCandidates`：文件派生候选若是纯集号标签（解析器无标题且解出集号）则丢弃；目录名候选保留。
- 合并（`video_metadata_merge.dart`）：补充对称（TMDB 主源时 MAL 补评分 / 标签 / 制作方 / 日文原名）；genres / studios / tags 并集去重；`plot` / `tagline` 语言感知：主源给出的非首选语言简介可被兜底源的首选语言简介覆盖（Jellyfin `ResultLanguage` 规则）；**标题 / 分集名同一规则**（2026-09-11，BUG-2454 后续）：MAL 只有日/英/罗马字三种标题，资料语言为 `ja` / `en` 时取本语言，其它语言先落日文原文、再由按资料语言投影的 TMDB 译名替换，被换下的原文保留为 `original_title` 并进别名池；语言不明的主源（AniDB）标题不动。其余标量先到者独占。

## 5. 多季一张卡

- **分组键**：Fribb `themoviedb_id`（TV）。同一来源下多个本地合集 / 单季作品解析到同一 `tmdb tv id` 时，展示层聚合成一张卡（复用 `collection_member_policy` 的多成员合集：海报归容器、成员保各季）；每季保留各自 MAL id 与资料，不合并身份（Shokofin Group→Series→Season 形态）。
- **季内集号**：第 N 季分集 = TMDB `season.tmdb` 从 `episode_offset.tmdb + 1` 起切片（Frieren S2 = tmdb S1 offset 28，Oshi no Ko S2 offset 11，Kusuriya S2 offset 24，实测 Anime-Lists 三例一致）。
- **绝对集号跨季**（`[Sub] Title - 25.mkv`）：首选 anime-relations 显式表 `MAL:from-to -> MAL:from-to`（含 `!` 自映射）；其次 Jikan `/full` 的 `Sequel` 链按各季 `episodes` 累加推导；AOD `relatedAnime` 只作候选不定方向。拒绝条件照 Sonarr / Taiga：落进多目标、区间跨目标、续作集数未知、评分不唯一 → 保留原 MAL id + 原绝对号并标未验证。
- **主条目**：同 `tmdb tv id` 组内首播最早者提供剧级字段与封面（HAMA `anime_core` / Shoko `MinAirDate`）。
- 不做：沿关系图无限闭包（Shoko 无上限但 MAL 关系噪）、TVDB 中枢、Scanner/Agent 双份逻辑。

## 6. UI 与 i18n

- 设置 → 视频 · 媒体库：下拉「主资料源」（MAL（经 Jikan）/ TMDB），副标题说明另一源自动兜底；写入走 `commitVideoMetadataRuntimePreference`；`home_page.dart` 两处配置指纹加入 `primaryProvider`。
- 来源刮削设置对话框：只读说明行换成下拉「主资料源：跟随全局默认 / MAL / TMDB」，保存写 `provider_override`。
- i18n 已执行：新增 `video_metadata_primary_provider(_hint)`、`video_metadata_provider_mal/tmdb`、`video_source_scrape_provider_follow_global`；删除 `video_source_scrape_provider_policy`。多季卡片与识别词的 key 随各批次加。

## 7. 分批与验收

| 批次 | 内容 | 验收 | 状态（2026-09-08，分支 `feat/scrape-provider-choice`） |
|---|---|---|---|
| A1 | 主源可选 + 对称链 + 歧义不短路 + 纯集号不搜 + UI | 识别器 / 协调器 / UI 定向测试；Windows 真机中文目录名来源两种主源各跑一次 | 已提交 `b450030c83`（+ 数据层 `16f11be7c8`）；真机复测待做 |
| A2 | 离线标题索引阶段（AniDB 标题包 → Fribb → mal/tmdb id 直拉）+ 身份接力 | 中文目录名离线命中不搜索；MAL 504 时换 TMDB id；歧义退回搜索；MAL→TMDB id 接力 | 已提交 `4831c29f34`（`anime_offline_identity_resolver.dart` + `offline_identity_coordinator_test.dart`） |
| A3 | 年份 ±1 + 去年份重搜 + 合并对称 / 并集 / 简介语言感知 | 计划表用例；merge 单测；`mal_hash_coordinator_test` 简介断言随语义改为 TMDB 中文 | 已提交 `f8f3146cb7` |
| B | 多季一张卡（Fribb 季序列逐季抓 MAL 分集 + anime-relations 重定向 + 按季集数累加 + 越界只警告） | `multi_season_coordinator_test.dart`：季目录 / 绝对集号 29→S2E1 / 无规则 30→S2E2 / 99 越界未验证 | 已提交 `f1e7696569`。**范围收敛**：只在**一个本地合集内**逐季对齐（成员 (季, 集) 覆盖经 `localEpisodeKeyFor` 三处共用）；跨合集的展示层聚合（S1、S2 两个独立合集并成一张卡）未做——扫描期同名即已并组，拆开的多是文件名本身缺番名，需用户改名或手动并合集 |
| C（二期） | 识别词（屏蔽 / 替换 / 集偏移）、字段锁、每来源语言覆盖 | — | 进行中 |
| 顺手修 | BUG-2285 Fribb 字段形状、BUG-2286 纯集号文件名归组 | 见下 | 已提交 `535b9828da` / `cd1189403b` |

## 9. 真网络探针（2026-09-08）

离线标题索引对 15 个中文 / 日文 / 罗马字标题的实测（真 AniDB 每日标题包 + 真 Fribb 表，探针脚本一次性、未入库）：

| 指标 | 值 |
|---|---|
| 命中 | 12 / 15 |
| 拿到 MAL id | 12 |
| 拿到 TMDB id | 12（修 BUG-2285 前是 0） |
| 15 次查询耗时 | 2.1 秒（标题包已缓存） |

抽查正确：Frieren 209867、药屋 220542、千与千寻 129、你的名字 372058。未命中的三个：`我推的孩子` / `间谍过家家` 因 AniDB 标题包里 S1 与 S2 同名判歧义（按 Sonarr / Taiga 纪律放弃，退回在线搜索），`无职转生` 标题包无此中文名。

**这条探针是必需的**：BUG-2285 的错误解析让 TMDB id 恒为 null，而依赖它的两条路径都写成「拿不到映射就安静退回旧行为」，单测 fixture 又用同样的错误形状，双错相消——没有打真实数据的探针就永远发现不了。

## 10. 已知边界

- 同一目录混着不同番的纯集号文件会被 BUG-2286 的修复并到一组（那种整理方式本来就无法从文件名区分），用户可在合集里拆分。
- 跨合集展示聚合（S1、S2 两个独立合集并成一张卡）**不做**：扫描期同名即已并组，BUG-2286 又补上了纯集号这一路；剩下真正分开的多是用户有意分开的目录结构，自动并卡会覆盖用户组织。
- AniDB 标题包里 S1 / S2 同名的作品在离线阶段判歧义，靠在线链兜底。若要消歧，可用「同一 TMDB 剧 + 首播最早」再收一层，属二期。

## 8. 兼容性

- 默认仍 MAL 主源；A1 用户可感知变化只有「MAL 歧义多问一次 TMDB」「纯集号不搜」。
- 已持久化身份不重识别：TMDB 主源下历史 MAL 主身份仍在链内。
- AniDB 单源测试语义不变；旧 `provider_override` 历史值静默回落。
- 离线数据拉取失败沿用旧包，缺包时跳过第 2 阶段直接在线搜索。
