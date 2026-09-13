# 漫画「Fushi 互联」来源合集：对端扩展源经对端代理浏览

- 日期：2026-09-13
- 状态：已拍板（用户 2026-09-13 决策，「根本性做完」：批 1 + 批 2 一起落地）
- 相关 bug：BUG-2515（对端漫画库浏览页裸英文错误、无「去配对」出路）
- 相关设计：`2026-09-12-manga-download-first-design.md`（下载后才能看，本设计的章节全部走那条管线）

## 1. 决策

1. 漫画「来源」页里的「Fushi 互联」不再是无开关的直跳入口，改成**合集**：头行 = 合集总开关 + 展开箭头；展开后子项各自可关——「对端漫画库」（对端已下载的漫画，既有能力）+ 每个对端**借出的扩展源**（Mihon / Aidoku 跑在对端，本机经它代理热门 / 最新 / 搜索 / 过滤器 / 详情 / 章节 / 页图 / 封面）。
2. 发现页对互联来的东西**特殊标记**：「浏览来源」卡片、来源热门行行头、聚合搜索段行头、代理源浏览页都带「互联 · 经 <设备>」徽标；下拉选项带「· 互联」后缀。
3. 对端漫画库浏览页未配对态：本地化文案 + 「去配对」按钮（推「配对与设备」设置页），不再给永远失败的「重试」。
4. 代理源的作品身份 **不含对端设备**：`(runtime='interconnect_source', 包=fushi.interconnect 占位, 源=对端源 id, 作品 key)`。同一个源经哪台对端代理都是同一本书；对端只是传输层，运行时按「谁在线且有这个源」选（与既有互联源「不把对端地址烧进 bookKey」同一条红线）。
5. iOS：经对端代理浏览第三方扩展源合规上仍是「在线漫画源宿主」，代理源子项与发现页卡片走 `StoreRestrictedCapability.onlineMangaSource` 同一道门（iOS 不出现）；「对端漫画库」子项不受门。
6. Cloudflare 挑战页只能在跑着扩展的那台对端上弹，本机不做解题 UI：对端把 `cloudflare` 结构化传回，本机文案直说「去 <设备> 上打开该源完成验证」。

## 2. 数据结构

### 2.1 host（`packages/fushi_engine/lib/sync/manga_sources/`）

- `HostMangaSourceHost` 可选服务接口（app 实现，无头服务端 / iOS 留 null）：`capability()` / `listSources()` / `filters()` / `browse()` / `details()` / `pages()` / `pageImage()` / `coverImage()`。
- wire 形状：作品 / 章节直接用 app 侧 `OnlineMangaSeries.toJson` / `OnlineMangaChapter.toJson`；页是对端运行时的不透明 JSON（Mihon `{index,url,imageUrl}`，Aidoku 原生页 map + `index`），原样往返。过滤器 = Mihon bridge JSON + `values / stateBoolean / children`（`mihonFilterToWire` / `mihonFilterFromWire`）。
- 路由 `POST /api/manga-sources/<id>/{browse,details,pages,page-image,cover}`、`GET /api/manga-sources[/<id>/filters]`；鉴权走 server middleware；`HostMangaSourceException` → `source_not_found` 404 / 其余 502 + `{error:{code,message}}`。能力位 `capabilities.mangaSources = {version, runtimes}`。
- 源 id：`mihon:<包名>:<源 id>` / `aidoku:<包 id>`；只列**对端当前已启用**的源（源 enabled 且扩展 enabled；Aidoku 已启用包）。

### 2.2 client（`fushi/lib/src/media/manga/interconnect/`）

- `InterconnectMangaSourceClient`：按 `FushiClientUrl` **定向**打对端（`InterconnectSyncBackend` 是「第一台可达」模型，不适用）；`probe()` 并发探全部已启用对端，只留带 `mangaSources` 能力位的。
- `InterconnectMangaSourceRegistry`（AppModel 单例 ChangeNotifier）：聚合各对端源清单、按源 id 去重（保留先探到的对端）、订阅互联总开关广播与偏好；`ensureFresh()` 2 分钟节流、`resolve(id)` 未命中重探一次。
- `OnlineMangaRuntimeKind.interconnectSource('interconnect_source')` + `InterconnectSourceMangaPageRef` + `InterconnectSourceLibraryAdapter`：`app_model.dart` 分派一个分支，作品页 / 下载 worker / 更新探针零改动接上。
- 偏好（本机，不随服务配置同步）：`manga_interconnect_sources_enabled`（合集总开关，默认开）/ `manga_interconnect_library_enabled`（默认开）/ `manga_interconnect_disabled_source_ids`（存「关掉的」，对端新装的源自然是开的）。

### 2.3 UI

- 来源页：`InterconnectMangaSourceRow` 合集（头行开关 / 刷新 / 折叠；子行开关）。
- 发现页：`MangaSourceCatalog.interconnectLibrary / interconnectSources`，id `interconnect:library` / `interconnect:<源 id>`；`interconnectDiscoverySourceFeeds` 热门行；`InterconnectGlobalSource` 参与聚合搜索；详情页「按标题匹配」也把代理源列进来。
- `InterconnectSourceBrowsePage`（仿 Mihon 浏览页：热门 / 最新 / 搜索 / 过滤器分页）→ `InterconnectSourceMangaDetailPage` → `MangaSeriesPage(SourceMangaSeriesTarget)`。

## 3. 刻意不做

- 不改 `InterconnectSyncBackend` 的会话模型；不把对端设备烧进 bookKey；不做 iOS 例外；不做边下边读；本机不弹对端的 Cloudflare 挑战页；不把源清单落库（真值只有对端）。
