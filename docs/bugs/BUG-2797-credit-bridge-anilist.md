## BUG-2797 · 发现详情演职员 MAL 罗马字与 TMDB 汉字认不出同一人（AniList 写法桥）
- **报告**：2026-09-30（用户：浏览 › 发现 › 视频作品详情，同一声优出现两遍；BUG-2795 只做到「不重复追加」，TMDB 那份照片 / id 补不上）
- **真实性**：✅ 真 bug。两处根因：
  1. `fushi/lib/src/media/video/metadata/anilist_video_metadata_provider.dart:377`（修前）`_name` 取 `native ?? full`，而 `_person` / 角色又把 `native` 填进 `originalName`——罗马字 `name.full` 被整个丢掉，AniList 这条人物只剩「鈴木愛奈 / 鈴木愛奈」。GraphQL 查询本来就请求了 `name { full native }`，是解析丢的；它既对不上 MAL 的「Suzuki, Aina」（在 BUG-2795 规则下被当成不可判定、直接丢弃），也当不了罗马字↔汉字的桥。
  2. `packages/fushi_engine/lib/media/video/metadata/video_metadata_merge.dart:1025`（修前）`mergeVideoMetadataCredits` 只按两边**各自**的 name / originalName 比对；两两依次合并时，第三个来源里「罗马字 = 汉字」的证据用不上，且能否认出同一人取决于 AniList 是否恰好排在 TMDB 之前。
  - Jikan `/anime/{id}/characters` 的 person 只有 `name`（罗马字），没有原文名字段，MAL 侧无可补。
- **[x] ① 已修复** — 见下
  - AniList：`anilist_video_metadata_provider.dart:380` `_name` 改取 `full ?? native`，`native` 照旧落 `originalName`（与 TMDB `name` / `original_name` 同一约定），人物与角色都留住两个写法。不新增请求。
  - 合并层：`video_metadata_merge.dart:1262` 新增 `VideoMetadataCreditNameBridge`——合并前从**全部**来源（作品级 + 分集级人物关系）收集「同一条目里并列的写法」，用并查集连成人名 / 角色名两套等价类；`_CreditIdentity.of`（`:1176`）把两边的名字按等价类展开后再走原有的同组 / 同名 / 同角色 / 书写系统判定，书写系统 = 原始写法 ∪ 桥带进来的写法（无桥时与修前逐位一致）。`mergeVideoMetadataCredits`（`:1030`）与 `supplementVideoMetadata` / 季 / 集合并新增可选参数 `names` / `creditNames`，默认 `VideoMetadataCreditNameBridge.none`。
  - 歧义保护：`_NameKeyUnion`（`:1341`）另记「同一条目里直接并列的原文写法」；一个类里的原文写法若分属两个以上直接证据组（罗马字同名的两个人：Yuu Kobayashi = 小林ゆう / 小林優），整类不当桥，退回无桥行为。
  - 接线：`fushi/lib/src/media/video/discovery/video_discovery_service.dart:303` `loadDetails` 合并前 `VideoMetadataCreditNameBridge.fromWorks(works)` 一次收齐，每步 `supplementVideoMetadata` 共用同一份——身份判定与来源排序无关。
  - 刮削协调器（`video_source_scrape_coordinator.dart`）不装配 AniList，也不传桥，走默认 `none`，行为与修前一致。
- **[x] ② 已加自动化测试** — 见下
  - `fushi/test/media/video/metadata/video_metadata_merge_test.dart` 组「BUG-2797 AniList 写法桥」7 条：三源合成一条（原名 / TMDB 照片 / mal+tmdb+anilist id 带齐）、交换补充源顺序结果不变、纯函数带桥、无桥维持现状（不重复也不挂 TMDB 照片）、同一声优两个角色按角色桥各归其位、罗马字同名两人不误并、同条目繁简 / 译名 + original_name 不算歧义。
  - `fushi/test/media/video/metadata/video_metadata_provider_contract_test.dart` AniList contract：查询含 `name { full native }`，声优 / 角色解析出罗马字 `name` + 原文 `originalName`，无 `full` 时退回 native。
  - `fushi/test/media/video/discovery/video_discovery_service_test.dart`「BUG-2797 AniList bridges…」：`loadDetails` 端到端（MAL + AniList + TMDB，提供者声明顺序打乱）得到单条人物。
  - 变异实测：`_CreditIdentity.of` 不再展开桥 → 新增合并测试与服务测试变红；还原后全绿。
- **备注**：AniList 作为发现详情主源（MAL 取不到时）时，人物显示名由原文变为罗马字，与 MAL 主源的显示一致。
