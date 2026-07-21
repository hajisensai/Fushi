## BUG-1002 · 下载页字幕搜索仅按AniList id无文本回退致误报无字幕
- **报告**：2026-07-22（用户：下载选番后字幕栏显示「无字幕」，已填 Jimaku API key，质疑为何没拿 apikey 去搜、字幕不同名怎么办）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:240-242`（`_fetchJimaku`）——只调 `jimaku.searchByAnilistId(media.id)`，返回空即当「无字幕」，**缺文本回退**。Jimaku 条目只有被人工挂上 AniList id 时 `searchByAnilistId` 才命中；冷门/非标准来源（如 `とむとじぇりーごっこ` Tom & Jerry Gokko 的 YouTube WEB-DL）字幕条目常只有文本条目、未挂 id，于是 API key 有效却报「无字幕」。同仓另两个 Jimaku 入口（`jimaku_subtitle_dialog.dart:297` / `jimaku_batch_dialog.dart:154`）**都有** `searchByQuery` 回退，唯独下载页漏了——典型「特殊情况」漏写分支。
- **[x] ① 已修复** — 新增 `JimakuClient.searchEntries({anilistId, queryFallbacks})` 收敛「先 id 后文本回退」为单一真相源（`jimaku_client.dart`）；`_fetchJimaku` 改用它，回退查询串按 `media.native`（日文名，Jimaku 命中率最高）→ `romaji` → `english` 依序尝试、首个命中即停（新增 helper `_jimakuFallbackQueries`）。提交：<pending>
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/jimaku_client_test.dart` 新增 group「JimakuClient.searchEntries」，用 `MockClient` 断言：id 命中不再走文本搜；id 空→按序回退文本、跳过空串、首个命中即停（复现本 bug 的核心路径）；全空→空；无 id 仅文本。提交：<pending>
- **备注**：未改另两处已正确的 Jimaku 入口（避免行为漂移，风险最小）；文本回退命中条目后仍走既有 `chooseSubtitlesFor`/集号匹配，与「字幕不同名」的按集匹配无关——本 bug 是「连条目都没搜到」。
