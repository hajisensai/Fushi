## BUG-5459 · 视频合集详情页：剧集只在媒体服务器上（未入库）时没有「加入媒体库」，只有入库后的「移出媒体库」
- **报告**：2026-11-25（用户：视频 tab 打开 Jellyfin / Emby 剧的合集详情，已入库的给「移出媒体库」，只在服务器上的却没有「加入媒体库」）
- **真实性**：✅ 真 bug。根因：
  - `fushi/lib/src/pages/implementations/media_collection_detail_page.dart:2433`（修复前）`_heroSecondaryActions` 只有「移出媒体库」一项，门是 `_mediaServerWorks`（`:2448`），它只从**本地行** `_members` 的 `streamSpecJson` 解析作品；只在服务器上的集是远端槽（`CollectionEpisodeSlot.remote`，本机没有 `video_books` 行），对称的「加入」从没实现。
  - `fushi/lib/src/media/collections/collection_episode_slot.dart:322` `CollectionRemoteContext` 不带任何媒体服务器能力，远端成员 `RemoteVideoInfo` 也只有叶子 id、不含剧 id，详情页结构上就无从走 `MediaServerVideoLibrary.addToLibrary(browser, work)`（它要服务器浏览器 + 作品条目）。
- **[x] ① 已修复** — `CollectionRemoteContext.mediaServer`（`MediaServerBrowser?`，视频库页在远端来源是媒体服务器时传入，与 `playedMark` 同一能力口径）；新增 `MediaServerVideoLibrary.addWorksOfItems(browser, itemIds)`：叶子 → `itemDetail` → 集取 `seriesId` 再取剧、电影取自身 → 走同一条 `addToLibrary`（整部剧全部季、剧名合集、剧海报），同剧其余叶子已有行即跳过、不再联网。详情页 hero 次按钮在「移出」之前加「加入媒体库」（`MediaDetailSecondaryButton`、`FushiIcons.libraryAdd`、`t.video_online_library_add`，key `collection-hero-library-add`，与服务器详情页同组件同图标同文案；成功 toast `video_online_library_added`），加完重读、换成「移出媒体库」；剧部分在库时二者并列（与服务器详情页一致）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/collection_detail_media_server_library_test.dart`（真 widget：出「加入」、点了整部剧入库并换成「移出」、部分在库并列、非媒体服务器来源不出）；`fushi/test/media/video/media_server/media_server_library_test.dart`「BUG-5459」组（集回溯到剧且同剧只问两次详情、电影按自身、取不到详情抛出不落行）。
- **备注**：真机 / 真实 Jellyfin 复测由委托方在开发沙箱截图验证。
