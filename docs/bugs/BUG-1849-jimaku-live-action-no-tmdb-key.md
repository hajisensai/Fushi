## BUG-1849 · Jimaku 真人剧检索没有权威关联键：TMDB id 被解析器丢弃，只能靠标题模糊命中
- **报告**：2026-08-25（接入 Jimaku 真人剧分类时自查发现，非用户报告）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/media/video/jimaku_client.dart` 的
  `parseJimakuEntries`（只取 `id` / `name` / `english_name` / `anilist_id`，把 API 明确返回的
  `tmdb_id` / `japanese_name` / `flags` 直接丢掉）+ `searchEntries` 没有 TMDB 检索键
- **[x] ① 已修复** — `fushi/lib/src/media/video/jimaku_client.dart` 补 `JimakuEntry.tmdbId` /
  `japaneseName` / `flags`（`JimakuEntryFlags` + `parseJimakuEntryFlags`）、`jimakuTmdbId` 编码、
  `searchByTmdbId`，`searchEntries` 增加 `tmdbId` 检索键（排在 AniList 之后、显示名之前）；
  `fushi/lib/src/media/video/jimaku_subtitle_provider.dart` 增加 `tmdbIdFor`
- **[x] ② 已加自动化测试** — `fushi/test/media/video/jimaku_client_test.dart` 新增 group
  「TMDB 精确匹配（BUG-1849）」8 例；`fushi/test/media/video/jimaku_subtitle_provider_tmdb_test.dart`
  新增 5 例（`tmdbIdFor` 编码 + provider 真发请求时检索键与分类过滤各归各位）
- **备注**：实现取自孤儿分支 PR #955 的 `feat(jimaku): 客户端支持 Live Action 分类与 TMDB 精确匹配`，
  但**只移植 TMDB 检索键那一半**。见下方「为什么丢弃 PR #955 的 JimakuSearchScope」。

### 根因

Jimaku 的 entry 模型里带 `tmdb_id`（服务端 schema `pattern = (tv|movie):(\d+)`）、
`japanese_name` 和 `flags`（服务端 `models.rs` 把内部 u32 bitfield 在 API 层展开成 dict）。
`parseJimakuEntries` 三个字段一个都没取，`searchEntries` 也就无从按 TMDB 精确查。

于是真人剧的检索链只剩两级，且第一级恒空：

1. `anilist_id` —— AniList 是动画专属库，真人条目上永远没有这个 id；
2. `queryFallbacks` —— 拿显示名去服务端模糊搜。

结果是：**Hibiki 从 TMDB 拿到了一个权威数字 id，却只能把标题字符串扔回给 Jimaku 去猜。**
日剧的中/英/日三套名字互不相同（`最愛` / `Saiai` / `Beloved`），显示名命中率天然低，
而 id 是精确的——这不是「匹配不准」，是把手里已有的精确键扔了。

（`anime` 硬过滤那一半已由 develop 的 BUG-1694 独立修掉，本条不重复。）

### 修复

- `JimakuEntryFlags` + `parseJimakuEntryFlags`：按 API 的 dict 形态解析，缺字段按 `false`
  （与服务端 `#[serde(default)]` 同语义）。只认对象形态——站点页面里的 u32 bitfield 不是本
  客户端的输入，不为不存在的情况写解析分支。
- `JimakuEntry` 补 `tmdbId` / `japaneseName` / `flags`；`name` 在 romaji 与英文名都空时回退
  `japanese_name`（真人条目常无 romaji 名，此前会显示成 `#<id>`）。
- `jimakuTmdbId({required bool movie, required int tmdbId})`：TMDB 的电影与剧集是两个独立
  号段，种类必须与数字一起编码。
- `searchByTmdbId` / `searchEntries(tmdbId: ...)`：权威 ID 键排在模糊标题之前，命中即停。
- `JimakuVideoSubtitleProvider.tmdbIdFor`：把发现层的裸数字 id + `mediaKind` 编码成 Jimaku
  的形态。注意用的是 `mediaKind` 而非 `discoveryCategory`——动画剧场版是 `movie` 号段。

### 为什么丢弃 PR #955 的 `JimakuSearchScope`

PR #955 里这套实现自带一个 `JimakuSearchScope{anime, liveAction, all}` 枚举 +
`JimakuVideoSubtitleProvider.scopeFor`。develop 在 `131c823058`（BUG-1694 收尾）刚刚因为
「Jimaku 分类过滤存在两个真相源」踩过一次真 bug，并把多余那个入口删掉了：

> 修法不是让两者同步，是删掉传了不生效的那个入口……留着一个「传了没用」的参数多久，
> 这个 bug 就能复发多久。

把 `JimakuSearchScope` 搬进来等于立刻造出第三个真相源。所以本次只移植**检索键**，分类过滤
仍然唯一地由 develop 的 `JimakuAnimeFilter{anime, liveAction, either}` +
`_animeFilterFor(request)` 决定：

- `searchByTmdbId` 复用 `_searchWithAnimeFilter`，缺省 `either`；
- `either` 是**顺序回退**（先 anime 再 liveAction，命中即停），比 PR #955 的 `all`
  并发合并少一次请求，且 UI 与远端 handler 已全线接上这个语义——不改它。

检索键与分类过滤是正交两轴，代码里也照此分层：`tmdbIdFor` 只产键，`_animeFilterFor` 只定范围。
