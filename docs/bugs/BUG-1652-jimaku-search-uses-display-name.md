## BUG-1652 · Jimaku 搜索拿中文显示名去猜，刮削存下的 AniList ID 从没被用过
- **报告**：2026-08-15（用户实测，原话「这里字幕轨搜索的时候没有根据罗马音/英语搜索」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart`
  的 `_jimakuQuery()`（只回一个显示名字符串）+ `jimaku_subtitle_dialog.dart` 的 `_search()`
  （拿这个字符串去 `AniListClient.searchAnime`）
- **[x] ① 已修复** — commit `9bfe4cdd95`
- **[x] ② 已加自动化测试** — `fushi/test/media/video/jimaku_search_seed_test.dart`（7 例）+
  `fushi/test/pages/jimaku_search_identity_test.dart`（4 例）
- **备注**：与 [BUG-1653] / [BUG-1654] 同一批用户实测反馈，同一个对话框。

### 复现

播放 Re:Zero 第四季（库里显示名是中文「Re：从零开始的异世界生活 第四季 丧失篇」）→ 字幕菜单
→「获取字幕（Jimaku）」→ 番剧名预填为该中文串 → 搜索 → 0 结果。
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
丢给 AniList；AniList 空 → 没有 anilist_id → 退回文本搜 Jimaku（Jimaku 条目名只有 romaji/英文/
日文，中文同样搜不到）→ 双双落空，且**没有任何降级重试**。

而这个视频**刮削过**：`video_metadata_provider_identities` 里存着 `provider='anilist'` 的
`externalId`，`video_metadata_works` 里存着 `originalTitle`（日文原名）。播放页从未读过它们
（全页 + 18 个 part 里 grep 不到任何 `getVideoMetadataWorkBy*`）。

### 修复

新增 `fushi/lib/src/media/video/jimaku_search_seed.dart` 的 `JimakuSearchSeed` + 播放页
`_buildJimakuSeed`：

- 有外部 ID 就**直接按 `anilist_id` / `tmdb_id` 检索 Jimaku**，完全跳过文本匹配这一环；
- 搜索词优先级改为「日文原名 → 刮削作品名 → 显示名 → 合集名」（Jimaku 是日语字幕站，条目名与
  上传文件名基本是日文或罗马音，中文译名命中率最低）；
- 用户手动改过番名则一律按他的词搜，不再套用刮削 ID。

归属坑（表 CHECK 约束）：合集里的一集，元数据挂在**合集**上，用该集 bookUid 查恒为 null，必须走
`widget.playlistCollectionId`。元数据读不到一律降级为纯文本检索（= 旧行为），不挡住搜索。
