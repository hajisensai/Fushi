# 动画刮削参考与 provider 边界

> 2026-10-14 从根 `CLAUDE.md` 原样迁出；代码注释里的「CLAUDE.md「动画刮削参考与 provider 边界」」指的就是本文件。

- `references/ShokoServer/` 固定官方 `ShokoAnime/ShokoServer`，是动画文件识别、作品/分集模型、缓存和补源编排的长期参考。它是 git submodule：不得复制进 Fushi 构建、不得修改其源码来实现 Hibiki 功能；升级 gitlink 前必须先审上游差异并在本仓提交中说明采用了什么架构变化。
- 作品资料主源**用户可选**（全局偏好 `video_metadata_primary_provider` + 来源级 `provider_override`），白名单 `kSelectableVideoMetadataProviders = [anidb, mal, tmdb]`。**2026-09-20 用户拍板对齐 Shoko 形态：默认主源 AniDB**（`kDefaultVideoMetadataPrimaryProvider`；哈希给出的 aid 直接就是作品身份、不经 Fribb，anime XML 出核心资料与全集播出日，TMDB 恒为补充 / 兜底：AniDB → TMDB），**MAL 保留为可选主源**（MAL ↔ TMDB 互为兜底），AniDB 主源下 MAL 只是交叉引用（anime XML `<resources type="2">` = Shoko `CrossRef_AniDB_MAL`，Fribb 一对多映射不落交叉引用、不算歧义）。此前 2026-09-07「MAL 为主」/ 2026-09-08「默认 MAL」的决定已被覆盖。识别链只在**唯一精确命中**时终止：主源歧义继续问兜底源，双歧义合并候选交人工，不再「主源一歧义就截止」（BUG-2268）。MAL 经 Jikan 只读接口取得，匹配成功保留主源已有字段，缺项可由严格匹配的另一源补充。**已确认 / 已落库 / NFO 默认 / 显式路径 / 手动输入的身份只要来自这三家就直取不换源、不重搜**（协调器 `acceptsCanonical`、resolver `_acceptsIdentity`、`searchManualCandidates` 同一判据）——默认从 MAL 切到 AniDB 后存量 MAL 作品照旧由 MAL provider 续刮；只有 `isPrimary` 的落库身份才算「旧主源」，仅有 NFO 索引交叉引用的作品没有可退役的主源。TMDB 的 /movie 与 /tv 是两个 id 空间：`<movie>` NFO 的 TMDB id 不能成为剧集单元的规范身份。设计与分批见 `docs/specs/2026-09-08-scrape-provider-choice.md`、`docs/specs/2026-09-19-shoko-anidb-tmdb-parity.md` 第 10 节。
- **AniDB 保留真实 ED2K 文件哈希识别**，返回文件/作品/分集原生身份；不得把标题匹配称作哈希识别。集信息（播出日 / 三语集名）首选 AniDB HTTP anime XML（`AnimeDoc_{aid}.xml` 落盘 `<support>/anidb_anime/`，24h 内直接用、过期才远程、远程失败或封禁回旧 XML），UDP `EPISODE` 只是 XML 拿不到这一集时的兜底。跨站映射仅唯一明确 ID 才自动采用，AniDB 集号不能未经验证直接套到 MAL/TMDB 集号——季集由 AniDB 集在 TMDB 逐集链接决定（Shoko `MatchAnidbToTmdbEpisodes`）。Shoko 是哈希/协议/缓存/编排分层参考。
- 动画元数据刮削不装配 Bangumi、Douban、AniList、Fanart.tv 等并行资料源。这些历史 provider 字符串只作只读交叉引用兼容，不恢复其生产链；Jikan 是 MAL 传输接口，持久身份统一使用 `mal`。
- 本地 `.nfo` sidecar 是用户已有资料的离线兼容输入。同一作品可保持字段权威；与手动确认的新身份冲突时不混入新作品，保留原文件并提示，继续遵守覆盖保护。历史 ID 不能触发已退役 provider 网络请求。
- 发现、字幕、资源搜索与元数据刮削是不同域：AniList 若仍用于发现/字幕身份，不得进入刮削 registry；Nyaa/Torznab/OpenSubtitles/Jimaku 等资源或字幕模块不受“刮削 provider”清单约束。Fushi 发现页不得装配或展示 Bangumi source。
- AniDB 协议必须遵守其客户端注册、限流和缓存规则；没有已登记的 client identity 或所需凭据时必须在发请求前判 unavailable，不得冒用 Shoko 的 client 标识，也不得靠无界重试绕过限流。
