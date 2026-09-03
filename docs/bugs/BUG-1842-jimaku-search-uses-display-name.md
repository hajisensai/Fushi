## BUG-1842 · Jimaku 搜索拿显示名去猜，刮削存下的 AniList ID 从没被用过
- **报告**：2026-08-15（用户实测，原话「这里字幕轨搜索的时候没有根据罗马音/英语搜索」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart`
  的 `_jimakuQuery()`（只回一个显示名字符串）+ `jimaku_subtitle_dialog.dart` 的 `_search()`
  （拿这个字符串去 `AniListClient.searchAnime`）
- **[x] ① 已修复** — 见本轮提交
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_search_seed_test.dart`（8 例）+
  `fushi/test/pages/jimaku_search_identity_test.dart` 的「BUG-1842 身份优先检索」组（3 例）
- **备注**：与 [BUG-1843] / [BUG-1844] / [BUG-1847] 同一批用户实测反馈，同一个对话框。
  develop 自己在 `BUG-1782` 的「备注（本次未修）」里点名过这条治本项
  （「入口就把身份扔了……`JimakuSubtitleDialog` 构造器压根没有 `anilistId` 参数」）。

### 复现

播放 Re:Zero 第四季（库里显示名是中文「Re：从零开始的异世界生活 第四季 丧失篇」）→ 字幕菜单
→「获取字幕」→ 番剧名预填为该中文串 → 搜索 → 0 结果。
用户手动把番剧名改成日文「Re:ゼロから始める異世界生活」后立刻搜到（截图里 7 个系列、满屏候选）。

### 根因

不是「中文搜不了」——实测 AniList 用纯中文「从零开始的异世界生活」**能**命中（靠 synonyms）；
但「译名 + 季度 + 篇名」的整串匹配不上：

| 查询串 | AniList 结果 |
|---|---|
| `从零开始的异世界生活` | 命中 Re:Zero 系列 |
| `Re：从零开始的异世界生活 第四季 丧失篇` | **0 条** |

真正的问题是**拿显示名去猜**：`_jimakuQuery()` 用 `parseVideoFilename(basename).series`，
那个解析器是针对西文/日文发布名写的，中文标题里的「第四季 丧失篇」和全角冒号剥不掉，整串原样
丢给 AniList；AniList 空 → 没有 anilist_id → 退回文本搜（Jimaku 条目名只有 romaji/英文/日文，
中文同样搜不到）→ 双双落空。

而这个视频**刮削过**：`video_metadata_provider_identities` 里存着 `provider='anilist'` 的
`externalId`，`video_metadata_works` 里存着 `originalTitle`（日文原名）。播放页从未读过它们——
全页 + 18 个 part 里 grep 不到任何 `getVideoMetadataWorkBy*`。

### 修复

新增 `fushi/lib/src/media/video/subtitle/subtitle_search_seed.dart` 的 `SubtitleSearchSeed`
+ 播放页 `_buildJimakuSeed`：

- 有外部 ID 就**直接按 `anilist_id` 检索**，完全跳过「显示名 → AniList 模糊匹配」这一环；
- 搜索词优先级改为「日文原名 → 刮削作品名 → 显示名 → 合集名」，主词以外的候选经
  `VideoSubtitleSearchRequest.alternateTitles` 下发给 provider 依次再试（Jimaku 的
  `searchEntries` 本来就吃 `queryFallbacks`，此前一直只喂到一个显示名）；
- 用户手动改过番名则一律按他的词搜，不再套用刮削 ID（判据只有 `queryFallback == initialQuery`
  这一条，id / alternateTitles / tmdbId 三处共用）。

归属坑（表 CHECK 约束）：合集里的一集，元数据挂在**合集**上，用该集 bookUid 查恒为 null，必须走
`widget.playlistCollectionId`。元数据读不到一律降级为纯文本检索（= 旧行为），不挡住搜索，但要留
`ErrorLogService.logDiagnostic`——静默降级会让「身份优先永远没生效」这种故障彻底隐身。

种子**不绑定 provider**：id 与备选词经 `VideoMediaReference` / `alternateTitles` 交给
`VideoSubtitleRegistry`，Jimaku 与 OpenSubtitles 各取所需。TMDB id 按数字 + `isMovie` 两个字段
携带，不在数据层拼 `tv:<id>` 这类 provider 私有编码。

### 变异实测

把 `_search` 的 `directSeriesId` 去掉种子那一支（回到只认用户手点的系列）→
「刮削存下的 AniList id 直接用于检索」转红；还原后文件 sha256 与变异前一致。
