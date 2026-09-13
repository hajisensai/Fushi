## BUG-2231 · AniList 官方停用公开 API 时被显示成「连不上」并诱导用户去配代理
- **报告**：2026-09-07（用户反馈「AniList 连不上」）
- **真实性**：✅ 真 bug（上游停服本身不是我们的 bug，**把它呈现成网络故障**是）

### 现场实证（2026-09-07，curl 直连与经本机代理各打一次，结果一致）

```
POST https://graphql.anilist.co   →  HTTP 403   Server: cloudflare
{"errors":[{"message":"The AniList API has been temporarily disabled
             due to severe stability issues.","status":403}]}
```

同一时刻 `https://anilist.co/` 返回 **200**：网站活着，是**公开 API 被官方主动停用**
（AniList 在站点过载时的既有做法）。请求其实已经打到 AniList 并被它当面拒绝，
**不是**连不上。

### 根因

失败信息在两个位置被降维成「一个字符串」，类别就此丢失：

1. `fushi/lib/src/media/video/anilist_client.dart:317`（修复前）
   非 200 时 `lastFailure = 'HTTP ${res.statusCode}'` —— **响应体被丢掉**。
   而「官方停服的 403」与「被 WAF 拦的 403」状态码完全相同，唯一的区分依据正是
   响应体。信息在这里就没了，下游再想分类也无米可炊。

2. 三个 UI 入口各自把 `error.toString()` 直接摊给用户，且都不区分失败种类：
   - `airing_calendar_page.dart:126` 放送日历页 → 通用「加载失败」+ 英文异常串
   - `anime_download_dialog.dart:1596` 搜番 → `offerSettings: true` **无条件**附送
     「站点无法直连时，可在下载设置中配置网络代理」
   - `subtitle_search_panel.dart:1140` / `subtitle_collection_panel.dart:919`
     字幕降级提示只说「没在 AniList 确认上系列」，不说为什么

第 2 条里的代理提示是**主动误导**：上游停服时用户按提示去配代理，配到天亮也好不了。

### 修复

- **[x] ① 已修复** — 引入 `AniListFailureKind{apiDisabled, rateLimited, unreachable, other}`
  作为失败分类的单一真相源（`anilist_client.dart`），`searchAnime` 非 200 时保留响应体
  片段，`AniListRequestException.kind` 按「状态码 + 正文」判定；文案映射收在
  `fushi/lib/src/media/video/anilist_failure_notice.dart`，三个 UI 入口共用同一份说法。
  搜番对话框的代理提示改为**只在 `unreachable` / `other` 时出现**。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/anilist_failure_kind_test.dart`：
  钉死「403 + 停服文案 = apiDisabled」「403 但正文非停服文案 = other，不冒认官方停服」
  「传输层异常 = unreachable」「响应体必须进 failure，不得折成裸 HTTP 403」，以及
  `searchAnime` / `fetchAiringSchedulePage` 两条路径都带出类别。

### 备注

本次**不做**「日历页 API 失败回退陈旧缓存」：那是另一个改动面（缓存 TTL 语义 +
过期标注），与本 bug 的「说清楚是什么挂了」相互独立，留待单独评估。
