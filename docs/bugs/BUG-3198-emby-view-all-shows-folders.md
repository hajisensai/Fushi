## BUG-3198 · Emby「查看全部」显示文件夹而不是剧
- **报告**：反馈 x6ycN--g3l（截图：「新番连载」行的「查看全部」进去是两个「动漫」文件夹）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/media_server/media_server_home_view.dart` 的 `_openLibrary` → `MediaServerGridView` → `JellyfinVideoClient.listChildren(parentId: 库 id)`，即 `/Users/{uid}/Items?ParentId=<库>` 不带 `Recursive`。Emby 库下面挂的是库路径对应的物理文件夹（一个库配两条路径 = 两个同名文件夹），返回的就是文件夹。Emby 官方客户端 / Jellyfin web 的「查看全部」按库类型递归取作品。
- **[x] ① 已修复** — 本 PR：新增可选能力 `MediaServerLibraryItems.listLibraryItems`（`media_server_browser.dart`），Jellyfin/Emby 实现按库类型递归取：剧集库 `Recursive=true&IncludeItemTypes=Series`、电影库 `Movie`（单值，BUG-2254），混合库仍按文件夹树；忽略 Recursive 的兼容层（BUG-2567）回直接子级时原样展示。「查看全部」与首页库行兜底都走它；网格页头保留「按文件夹浏览 / 按作品浏览」切换。Plex 分区本来就是作品，不实现该能力。
- **[x] ② 已加自动化测试** — `fushi/test/sync/jellyfin_library_items_test.dart`（协议层：剧集 / 电影 / 混合库请求形态，按文件夹浏览仍列直接子级）。
- **备注**：用户的库若是 Emby「混合内容」类型，仍会显示文件夹（没有单一作品类型，与 Jellyfin web 一致）——需用户确认库类型。
