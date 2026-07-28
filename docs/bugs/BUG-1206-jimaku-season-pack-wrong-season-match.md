## BUG-1206 · 整季包字幕按标题猜集号导致错季配对且条数无上界
- **报告**：2026-07-28（用户：审查 abcbab36 对 PR#515 的跟进）
- **真实性**：✅ 真 bug。根因是**配对发生在还不知道包里有哪些文件的时候**。
  `NyaaTorrent`（`hibiki/lib/src/media/torrent/nyaa_client.dart:31`）只有标题 +
  体积，**没有文件列表**；种子要到用户点推送、`addTorrent` 之后引擎才给元数据，
  而字幕在 `anime_download_dialog.dart:_push`（旧 L753-789）就已经下完了。于是
  `chooseSubtitlesFor`（`anime_download_matching.dart:264`）只能靠标题猜：
  - **错季**：整季包（`TorrentEpisodeScopeKind.season`）走 `_seasonEpisodes`
    「取最前 cap 个」，Jimaku 条目用绝对集号编号（S2 编 13-24）时照样交出 13-24
    的字幕，UI 画成「有字幕」——PR#515 只能把它降级成 `~` 不确定态，没根治。
  - **条数无上界**：`seasonSubtitleCap`（同文件 L176）只有「标题自报 `全13話`」
    与「AniList `media.episodes`」两个自述来源，两个都没有就 `return null`
    = 不设上界；条目 24 集、包只 12 集时下满 24 条，多的永远配不上任何视频
    （落位 `pairSubtitlesToVideos` 要求集号严格相等）。
- **[x] ① 已修复** — 把配对推迟到种子 add 拿到元数据之后，按**包内真实视频文件名**
  反查：
  - 新纯函数 `matchJimakuFilesToVideoNames`
    （`hibiki/lib/src/media/torrent/anime_download_matching.dart`）：视频集号走
    `parseVideoFilename`、字幕集号走 `parseSubtitleEpisode`，**集号严格相等才配**；
    只在「1 视频 + 字幕侧唯一确定」时做 1v1 兜底，且双方都有集号却不等时不兜底。
    条数上界天然 = 真实视频文件数，不再需要任何自述上界启发式。
  - 计划只记**意图**：`AnimeDownloadPlan` 新增 `jimakuEntryId` /
    `jimakuEntryName` / `jimakuLanguage` / `subtitleStatus` / `subtitleNote`
    （`none` / `pending` / `resolved` / `unavailable`）。
  - 补取发生在完成钩子：`AnimeDownloadService._resolveSubtitles` →
    `JimakuPlanSubtitleResolver`（`anime_download_subtitle_resolver.dart`），此刻
    `_finishPlan` 手上已有引擎给的真实文件列表。
  - **向后兼容**：老计划（无 `subtitleStatus`）decode 落 `resolved`/`none`，
    完成时 resolver **不被调用**、已有 `subtitles` 不被重取或覆盖；
    `_placeSidecars` 的「该集已有 sidecar 就跳过」原样保留（老档/手放档不动）。
  - **降级不静默**：反查一条不配 / Jimaku 取不到 / 没接 resolver → 落
    `subtitleUnavailable` + `subtitleNote`，任务行显示「字幕：未匹配到（可手动补）」，
    视频照常入库不判失败。推送时 snack 说明「字幕将在下载完成后按包内实际文件配对」。
  - 订阅路径（`anime_download_subscription.dart`）**未改行为**：它只追单集种子，
    且有「要字幕却取不到就整条不下」的产品门，改成延迟会把该门变成「先下完再说
    没字幕」；仅补齐 `subtitleStatus` 语义。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/torrent/anime_download_matching_test.dart`（group
    `BUG-1206 matchJimakuFilesToVideoNames`，11 条）：**错季不再配上**（S2 包
    01-12 × 绝对编号条目 13-24 → 结果为空）、**条数被真实文件数收敛**
    （条目 24 集 × 包 12 集 → 恰好 12 条且集号是包里的）、部分覆盖、三种文件名
    写法、语言偏好、1v1 兜底与「不猜」边界。
  - `hibiki/test/torrent/anime_download_subtitle_resolver_test.dart`（5 条）：
    集成层用 MockClient 断言**发出去的请求**——错季时一个 `/f/` 下载请求都不发；
    条目 24 集时只发 12 个下载请求且不含第 13 集。
  - `hibiki/test/torrent/anime_download_service_test.dart`（4 条）：完成时才调
    resolver 且喂的是真实视频绝对路径、sidecar 只贴到对应那一集、失败落
    `unavailable` + 原因且视频仍入库、**老计划 resolver 不被调用且旧字幕不被覆盖**。
  - `hibiki/test/pages/anime_download_dialog_discovery_ux_test.dart`：推送时
    **不发任何字幕下载请求**、计划落 `pending` + `jimakuEntryId`、snack 说明时序。
  - **变异实测**（退回修复确认断言真转红）：① 退回「按字幕侧顺序取最前 N 条」→
    4 条红；② 退回「条数无上界」→ 6 条红；③ 退回「完成时不补取」→ 3 条红；
    ④ 退回「计划不记 Jimaku 意图」→ 1 条红。
- **备注**：PR#515 的 `~` 徽标 / 中性配色 / 确认页「集号未核对」提示行**全部保留**，
  未回退。理由：选种阶段的不确定性是**真的**（那一刻确实还没有文件列表），根治
  消除的是「错配真的落到磁盘上」，不是「选种时就能确定」。确认页额外恒显示一行
  时序说明；确定态的落点改到任务行（完成后显示真配好的结果 / 未匹配）。
  绝对集号偏移换算（审查建议 (a)）与条目季号校验（建议 (b)）**未做**——前者在
  本方案下已无必要（对不上就不配，不猜），后者属条目选择层，另立。
