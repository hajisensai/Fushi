## BUG-1054 · 手动匹配弹幕「弹幕加载失败」：拉弹幕与搜索共用 8s 超时，且非 2xx 被吞成空列表
- **报告**：2026-07-24（用户：截图——视频页「匹配弹幕」搜索 `Bad Girl 08` 已列出《坏女孩》TV动画 第8话，点选后左上角弹「弹幕加载失败，请稍后重试」）
- **真实性**：✅ 真 bug。根因在 `hibiki/lib/src/media/video/dandanplay_client.dart:375-398`（原 `fetchCommentsForMatch`）与其调用方 `hibiki/lib/src/pages/implementations/video_hibiki/danmaku.part.dart:174-203`（原 `_bindDanmakuEpisode`）。

  **定位过程（真实代码路径 + 实测）**
  1. 那条 toast 文案唯一来源是 `danmaku.part.dart` 里 `_bindDanmakuEpisode` 的 `catch`（i18n key `video_danmaku_manual_bind_failed`），即 `client.fetchCommentsForMatch(...)` **抛了异常**。
  2. 实测 `https://api.dandanplay.net/api/v2/comment/{id}`：无签名时 **403、约 330ms、body 空**；`/api/v2/search/episodes` 同样 403。而原 `fetchCommentsForMatch` 把任何非 2xx **`return const <VideoDanmakuItem>[]`**——**不抛异常**。故用户看到的报错**不可能**来自服务器拒绝。
  3. 用户截图里搜索在同一秒成功 → DNS / TLS / 内置凭据 / v2 签名全部正常（生产库 `preferences` 里无 `video_danmaku_config`，走的是构建期注入的内置凭据）。
  4. 排除下来，`_bindDanmakuEpisode` 的 `catch` 只可能被 `TimeoutException` / `SocketException` / `ClientException` 触发。而这条路径上唯一的超时是 `DandanplayClient` 的**全局 8s**：搜索（几 KB JSON）与拉弹幕**共用同一个值**，且 `http.get().timeout()` 计的是**整个响应体下载完**的时间；`/api/v2/comment/{id}?withRelated=true` 要由服务端聚合第三方弹幕源，正片响应体可达数 MB。这是「搜索成功、拉弹幕失败」最自洽的解释，也是本 bug 的直接触发点。

  **同一处契约还埋着两个静默 bug（与超时同源：失败被压成空列表）**
  - `_bindDanmakuEpisode`：403/404/5xx 时不报错反而走「成功」分支——面板关闭、`episodeId` 落库、弹幕为空、零提示；下次自动加载还会记住这个错的集。
  - `_loadDanmakuForVideo`：记住的集拉到空列表就当「缓存失效」，退回整文件匹配，白算一次 16MiB 文件 MD5 + `/api/v2/match` 再失败一遍。

- **[x] ① 已修复** — 根因是**契约**：`fetchCommentsForMatch` 用裸 `List` 做返回值，让「0 条弹幕」和「拉取失败」不可区分；超时按 client 一刀切而不按请求量级分档。改法：
  - `fetchCommentsForMatch` 改返回带状态的 `DandanplayFetchResult`（非 2xx → `serverError` 且把状态码放进 `error`；IO/超时 → `networkError`；2xx 且 `comments` 是 List → `hit`，`items` 允许为空表示「该集有效但暂无弹幕」）。
  - `DandanplayClient` 拆两档超时：`timeout`（轻量 match/search，默认 8s 不变）与新增 `commentTimeout`（拉弹幕，默认 30s）。
  - `fetchBestDanmakuForFile` 如实上抛拉弹幕的失败状态（此前被吞成「hit 且 0 条」），同时保留已匹配到的集供 UI 展示。
  - `_bindDanmakuEpisode` 按状态分流：失败 → 不落 `episodeId`、不关面板、按类型给具体文案（`video_danmaku_manual_network_error` / 新增 `video_danmaku_manual_bind_server_error`）；成功但 0 条 → 正常绑定并提示新增的 `video_danmaku_manual_bind_empty`。
  - `_loadDanmakuForVideo` 只在「记住的集有效但确实 0 条」时才退回整文件匹配。
  - 顺带把三处各写四个 `on ... catch` 的重复分支收敛成共用的 `_statusForError`。
  - 新增 2 个 i18n key 经 `hibiki/tool/i18n_sync.dart` 同步 17 语言并重跑 `dart run slang`。
  - 提交：`<待填>`

- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/video/dandanplay_client_test.dart`：非 2xx（403/404/500）→ `serverError` 且 `error` 带状态码；网络异常 → `networkError`；有效集 0 条弹幕 → 仍是 `hit`；**只把轻量 `timeout` 压到 1ms、`commentTimeout` 用默认值时拉弹幕仍成功而搜索超时**（谁再让两者共用一个超时即红）；`fetchBestDanmakuForFile` 在匹配成功但拉弹幕 403 时上报 `serverError` 而非 hit。
  - `hibiki/test/pages/video_danmaku_wiring_guard_test.dart`：源码守卫钉住 `_bindDanmakuEpisode` 必须先按 `result.status != hit` 分流并 `return`（早于 `setVideoDanmakuEpisodeId`）、三类文案都在；以及 `_loadDanmakuForVideo` 只在「hit 且 items 为空」时才退回整文件匹配。
  - 定向验证：`flutter test test/i18n test/media/video test/pages/video_quick_settings_sheet_test.dart test/pages/video_settings_schema_guard_test.dart test/settings/settings_schema_coverage_test.dart --no-pub` → 1925 passed / 2 skipped；`flutter analyze` 全绿。

- **备注**：**用户那次的确切异常文本没有取到**——`DebugLogService` 默认关闭且只存内存（`hibiki/lib/src/utils/misc/debug_log_service.dart:45`），无法回溯。上面第 4 步是排除法结论（403 已实测不抛异常、搜索同秒成功已排除网络与凭据），不是抓到的异常栈。修复本身不依赖这个结论：超时分档修掉最可能的触发点，而带状态的返回值让**任何**残留失败都会以「网络错误」/「服务器拒绝」/「暂无弹幕」自报类型，不再是一句笼统的「请稍后重试」。仍需在真机复测原始失败路径（Windows 视频页 → 匹配弹幕 → 搜《坏女孩》→ 选第8话）确认弹幕真正出现。
