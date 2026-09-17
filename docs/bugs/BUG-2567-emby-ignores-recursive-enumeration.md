## BUG-2567 · Emby 兼容服务器忽略 Recursive/IncludeItemTypes 导致剧集库在影片页整库为空
- **报告**：2026-09-16（用户：「我嘗試用 jellyfin，fushi 這裡也設定好了，但為什麼影片那裡就是沒有任何東西，我確定我有影片在底下」「電腦上的登入卻不會顯示，好像是電腦版的刷新不了沒辦法獲取」）
- **真实性**：✅ 真 bug（两条独立根因），用用户提供的真实账号沿真实代码路径复现并验证修复。
  测试服务器 `https://v1.uhdnow.com` = `UHD Media Server 4.9.3.0`（Emby 兼容的第三方实现，
  非原版 Emby；`/System/Info/Public` 的 `ProductName` 自报）。

### 根因 A：服务器忽略 `Recursive` / `IncludeItemTypes`，枚举结果全被过滤掉

`fushi/lib/src/sync/jellyfin_video_client.dart:483`（`JellyfinApi.recursiveVideoItems`）
按 `/Users/{uid}/Items?ParentId=…&Recursive=true&IncludeItemTypes=Movie|Episode` 拉全库叶子，
消费端 `jellyfin_video_client.dart:959`（`listRemoteVideos`）用
`JellyfinItem.isPlayableVideo`（只认 `Movie` / `Episode`）过滤。

这台服务器**两个参数都当没看见**，`/Users/{uid}/Items?ParentId=X` 永远只返回 X 的直接子级。
实测（同一账号、同一 header 组合）：

| 请求 | 期望 | 实际 |
|---|---|---|
| 电影库 + `Recursive=true&IncludeItemTypes=Episode` | 0 条 | 返回 `Movie` |
| 剧集库 + `Recursive=true&IncludeItemTypes=Episode` | 分集 | 返回 **`Series`** |
| 剧集库 + `IncludeItemTypes=Series` / 无类型 / 无 `Recursive` | 各不相同 | 三者返回**完全一致** |
| 各库 `TotalRecordCount` | 按类型不同 | Movie 轮与 Episode 轮**恒等** |

于是剧集/动漫库只吐 `Series` 文件夹 → 全部通不过 `isPlayableVideo` → 整库在影片页表现为
「一个条目都没有」。**电影库正常**（直接子级恰好就是 Movie），所以症状是「有的库有、剧集库全空」，
用户只勾了动漫库时就是彻底空白。`/emby` 路径前缀同样无效。同族问题见 BUG-2254（飞牛影视）。

出路：`/Shows/{seriesId}/Episodes?UserId=` 在这台服务器上**完全正常**——返回真 `Episode`，
带 `SeriesName` / `ParentIndexNumber` / `IndexNumber` / `RunTimeTicks` / `ImageTags` / `UserData`，
且跨季一次返回、`StartIndex`/`Limit` 分页均生效。

### 根因 B：桌面端根本没有手动刷新入口

`fushi/lib/src/pages/implementations/home_video_page.dart` 的页头「刷新」按钮此前被删，
理由写在源码注释里：「下拉刷新（`_pullToRefresh`）仍是手动同步入口，页头不再为它单占一格」。

该理由在桌面端不成立：唯一入口 `RefreshIndicator`（`home_video_page.dart:3360`）只响应
`ScrollBehavior.dragDevices` 里的设备，而 Flutter 默认集合**不含 `PointerDeviceKind.mouse`**，
本页也没有任何 `dragDevices` 覆写。结果：桌面用户手里一个手动刷新入口都没有——媒体服务器登录后
清单被 `RemoteLibraryCache` 的 TTL 挡住、或用户在设置里关掉「进影片页时自动列出」（BUG-1891 那个开关）
时，桌面端就永久卡在空库上。这正是用户报的「電腦版的刷新不了沒辦法獲取」，与手机端的差异也在此
（手机能下拉，桌面不能）。

- **[x] ① 已修复** —
  - A：`recursiveVideoItems` 首页即用 `JellyfinApi.ignoresRecursiveEnumeration`（「非空 + 一个可播
    叶子都没有 + 至少一个容器」三条同时成立）判定服务器不认递归，转入新的
    `_hierarchicalVideoItems` 自己走层级：BFS 队列只放容器，`Series` 一发
    `seriesEpisodes()`（`/Shows/{id}/Episodes`，跨季一次拿全）取分集，季/合集/文件夹用
    `children()` 列直接子级再入队。三道闸：`kMaxHierarchyRequests = 400` 请求预算、
    既有 `kMaxRecursiveItems = 20000` 条目上限、`visited` 容器去重防环，任一触发都置
    `truncated`。`/Shows/{id}/Episodes` 失败时回落 `children()`——一次 404 不能把整个库变成空。
    **原版 Jellyfin / Emby 走不到这条分支，一发请求都不多付。**
  - B：页头刷新按钮补回（`ValueKey('video-library-refresh')`），接新的 `_refreshFromHeader`，
    它只是 `_pullToRefresh` 外面加一层 `_headerRefreshBusy` 记账（全库枚举动辄几十秒，
    不标 busy 就是「按了没反应、于是连按五次发五轮枚举」）。刻意不另写刷新逻辑，
    否则手动同步 / TTL 穿透 / 封面回填记账清空迟早在其中一边漏掉。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/jellyfin_hierarchy_fallback_test.dart`（新增 6 条）：用 MockClient 复刻
    「忽略 Recursive」的服务器形状，钉住 ① 剧集库不再为空且按剧名折叠成合集、
    ② **守规矩的服务器一发都不多打**、③ 预算闸生效且报 `truncated`、
    ④ `/Shows/…/Episodes` 404 时回落列子级不致空库、⑤ 单容器彻底失败不拖垮整库、
    ⑥ 容器成环必须终止。
  - `fushi/test/pages/home_video_refresh_remote_guard_test.dart`（追加 2 条）：页头刷新按钮
    存在且带 busy 门控；`_refreshFromHeader` 必须委托 `_pullToRefresh`、不得自绕取数。
- **备注**：
  - **真机实测**（真实客户端 + 真实账号打 `v1.uhdnow.com` 的「追」库，133 部剧）：
    修复前该库直接子级 = 133 个 `Series`、**可播叶子 0 个**；修复后 `listRemoteVideos()`
    枚举出 **12314 集**、耗时 68 秒、折叠成 133 部剧，标题（`灵境行者 S01E01 …`）、时长、
    封面、季×10000+集 组内序全部正确；直连流 URL 带正确 `MediaSourceId`，
    `remoteVideoDetail` 补齐到真实文件大小 919 MB。
  - 该服务器的流 / 封面端点返回 302 / 301 重定向（跳 `v1-vod1.uhdnow.com` CDN），
    `package:http` 默认跟随，实测 206 `video/mp4` 与 200 `image/jpeg` 均正常，不需改动。
  - 超大服务器（实测单库 4131 部剧）上层级回退必然撞 400 请求预算并截断——这不是缺陷而是
    该服务器不肯递归的必然代价，正解仍是 BUG-1891 的「在设置里点名要枚举的媒体库」。
