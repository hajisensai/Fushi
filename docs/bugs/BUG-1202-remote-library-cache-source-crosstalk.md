## BUG-1202 · 互联与云盘共用远端清单缓存槽，换来源后看到上一个来源的条目
- **报告**：2026-07-28（用户：项目负责人巡检）
- **真实性**：✅ 真 bug（结构上可触发，非防御性加固）。根因 `hibiki/lib/src/sync/remote_library_cache.dart:63`（`read` 只按域 `key` 定位槽，槽里不带来源身份）+ `hibiki/lib/src/sync/remote_library_cache.dart:179`（唯一的失效订阅挂在 `InterconnectSyncBackend.sessionIdentityRevision` 上）。消费点：`hibiki/lib/src/pages/implementations/home_video_page.dart:557`、`hibiki/lib/src/pages/implementations/reader_history/remote.part.dart:65`、`hibiki/lib/src/pages/implementations/home_dashboard_page.dart:553`。

### 判定过程

两种来源确实写进同一个 key。`PR#510`（TODO-2119，commit `b7a495bbd`）把 `CloudRemoteVideoClient` 收敛成 `RemoteVideoSource` 之后删掉了 `cloudVideos` 槽，于是视频页的取数主干

```dart
final RemoteVideoSource? source = await _resolveRemoteVideoClient() ??
    await _resolveCloudRemoteVideoClient();
...
await _remoteCache.read(key: RemoteLibraryCacheKeys.videos, fetch: source.listRemoteVideos);
```

对互联与云盘两种源用同一个 `videos` 槽。书侧（`RemoteLibraryCacheKeys.books`）从一开始就是这样——`InterconnectSyncBackend` 与 `CloudRemoteBookClient` 共用一个槽，比 PR#510 更早。

**失效信号覆盖不到换来源**。唯一的自动失效是 `remoteLibraryCacheProvider` 订阅 `InterconnectSyncBackend.sessionIdentityRevision`，而它只在 `_loadConfig` 发现「地址集合 / 钉扎指纹 / 令牌」变了时自增（`interconnect_sync_backend.dart:221`）。`_loadConfig` 只在 `restoreAuth` 内被调用，而：

- **关互联开关**：`_resolveRemoteVideoClient` 在 `isInterconnectEnabled()` 为 false 时**先 return null，根本不调 `restoreAuth`** → revision 不自增。
- **再开互联开关**：`restoreAuth` 跑了，但地址/令牌都没改，signature 与上次相同 → 同样不自增。
- **换云盘后端类型**（Drive → WebDAV 等）：整条路径不碰 `InterconnectSyncBackend` → 永远不自增。

三条路都没有失效兜底，TTL 60s 内命中上一个来源的清单，`fetch` 根本不执行，且不报错。

### 触发序列（用户可复现）

前提：互联已配对并启用，云备份后端（如 Google Drive）也已配好，「显示远端条目」开着。

1. 打开视频库 → 渲染出互联对端的视频占位卡，`videos` 槽装着对端清单（60s 新鲜）。
2. 去设置页**关掉互联开关**（不改地址、不改令牌）。
3. 60s 内切走再切回视频 tab（`onTabActivated` → 非 forceRefresh 的读）。
4. 页面走云盘分支，但 `read(key: videos)` 命中步骤 1 的缓存 → **在「云视频」视图里看到互联对端的片子**，云角标俱全，不报错。点下载会向云盘要一个它根本没有的 uid。

反向同理（先云盘热缓存 → 开互联 → 看到云盘的条目）。书架（`books` 槽）与首页 dashboard 共用同一份缓存，同样受影响。换云盘后端类型（Drive→WebDAV）是第三条，且 60s 后仍可能反复发生。

### 修复方案：乙（缓存 key 带来源身份）

选乙而不是甲/丙：

- **甲（恢复两个槽）治不了本 bug 的一半**。双槽只区分「互联 vs 云盘」，`cloud_videos` 一个槽仍被所有云盘后端共用 → 换后端类型照样串。而且 PR#510 的收敛本身是对的（元素类型已统一成 `RemoteVideoInfo`，域名不该再按来源拆），退回去是走回头路。
- **丙（给云盘也接失效信号）是「记得在每个入口失效」的老路**。`BUG-1180` 自己的注释就批判过这个做法并已经漏过一次；何况「翻互联开关」不属于任何一侧的「身份变了」，还得再补第三个信号。
- **乙从数据结构上消灭问题**：槽 = (来源身份, 域)。来源身份由来源自己申报，声明成接口上的**抽象**成员，新增任何远端源时编译器当场要求给出身份 —— 「忘了分槽」这个失败模式不存在。

实现：新增 `hibiki/lib/src/sync/remote_library_source.dart` 的 `RemoteLibrarySource.remoteLibrarySourceId`；`RemoteVideoSource` / `RemoteBookClient` 实现它；`InterconnectSyncBackend` 报 `interconnect`，两个云 client 报 `cloud:<backendType>`（`backendType` 成为构造必填，由已经查过 `getBackendType()` 的调用方传入）；`RemoteLibraryCache.read/invalidate/isFresh` 增加 `sourceId` 维度。

同来源同域仍共享一个槽，BUG-1180 省下的那轮网络不受影响。

**已知残留（不在本轮范围）**：同一云盘后端类型下换账号（Drive A → Drive B）身份不变，60s TTL 内仍可能串。需要后端侧给出账号级身份信号，属独立议题；量级远小于本 bug 修掉的跨来源无限期串味。

- **[x] ① 已修复** — `remote_library_source.dart`（新增）/ `remote_library_cache.dart` / `interconnect_sync_backend.dart` / `cloud_remote_video_client.dart` / `cloud_remote_book_client.dart` / `url_stream_video.dart` / `home_video_page.dart` / `reader_history/remote.part.dart` / `home_dashboard_page.dart`
- **[x] ② 已加自动化测试** — `hibiki/test/pages/home_video_remote_source_switch_test.dart`（新增，行为层：切换来源后断言**渲染出的是哪一个来源的卡**）+ `hibiki/test/sync/remote_library_cache_test.dart`（新增 5 条跨来源用例）
- **备注**：断言刻意锁**内容归属**而非「缓存被清空」。负向验证：把 `_slotKey` 退回 `=> key`（等价 PR#510 后的现状）→ 5 条转红，页面用例的失败是「云盘卡片一个都找不到（渲染的是互联那张）」；还原 → 21 条全绿。若只断言「远端区为空」或「`isFresh` 为 false」，退回修复后仍然通过，抓不住这个缺陷。
