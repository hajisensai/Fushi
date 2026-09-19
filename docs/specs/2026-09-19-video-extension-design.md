# 视频在线源扩展：复用 Mihon 扩展系统跑 Aniyomi 扩展

> 起因：用户指令「复用漫画那套扩展系统，视频这块也做扩展」「顺便像漫画那样内置个最活跃的仓库」（2026-09-19）。
> 拍板：基线 `upstream/develop`；第一期桌面 + Android 全链路；Aidoku 已无宿主（iOS/macOS 先后砍掉），不涉及。

## 0. 核心判断

Aniyomi 扩展与 Mihon 扩展**同一套打包与分发**（APK + `index.min.json` / `repo.json`），只在两处分岔：manifest feature（`tachiyomi.animeextension`）与源接口（`AnimeSource` / `SAnime` / `SEpisode` / `Video`）。桌面 sidecar 上游 M-Extension-Server 本就带完整 anime 调用面（`sourcesAnime` … `getVideoList`，Mangayomi 用它跑真实扩展），Android 宿主是本仓自写的，缺 anime 分支。所以**不是新系统**：运行时、仓库索引客户端、安装/信任签名/预览、偏好、代理策略、Cloudflare、封面取图全部复用，新增的只有「anime 调用面 + 视频侧的播放接线 + UI」。

## 1. 已落地（本 PR）

| 层 | 改动 | 位置 |
|---|---|---|
| 持久化 v107 | `manga_extension_stores` / `manga_extensions` / `manga_online_sources` 加 `media_kind`（`manga`\|`anime`，默认 `manga`），三张表按它分片；查询加 `mediaKind` 过滤参数 | `packages/fushi_core/.../tables.dart` / `database.dart` / `database_library.part.dart` |
| 桌面 sidecar overlay | `/inspect` 读 `tachiyomi.animeextension.class`、回 `kind`、lib 门按生态；`/dalvik` 把 `AnimeFilterList` 走同一 wire、`List<Video>` 投影成五字段（headers 摊成 map，`@Transient` 进度不过通道）；`/source-image` `/source-data/clear` 认 `AnimeHttpSource` | `third_party/m_extension_server/overlay/...` + `AnimeResponseTest.kt` |
| Dart 运行时 | `MihonMediaKind`、`MihonAnime` / `MihonAnimePage` / `MihonEpisode` / `MihonVideo` / `MihonVideoTrack`、`MihonCatalogueEntry`；`AnimeMihonRuntime` 独立接口（不动 `MihonRuntime`，既有 11 个测试 fake 不受影响），`MihonBridgeRuntime` 实现 | `fushi/lib/src/media/manga/mihon/mihon_models.dart` / `mihon_runtime.dart` / `mihon_bridge_runtime.dart` |
| 管理器 | `MihonManager(kind:, ownsRuntime:)`：按 kind 读表、`WRONG_MEDIA_KIND` 生态门先于 `UNSUPPORTED_LIB`、`listSources` 按 kind 分派、默认仓库与「已装配」偏好位按生态各一份；`AppModel` 持一份共享 runtime + `mihonManager` / `animeMihonManager` 两个 manager | `mihon_manager.dart` / `app_model.dart` |
| 视频接线 | `AnimeSourceVideoClient implements RemoteVideoClient, RemoteCoverFetcher, RemoteVideoStreamHeaders`：一集一条 `RemoteVideoInfo`（id = `anime-source:<pkg>:<sourceId>:<episodeUrl>`，进度按集稳定）、同作品的集以 `playlist` 合集成员给播放器连播、取流选最高画质（可钉线路）、防盗链头经新能力接口 `RemoteVideoStreamHeaders` 下发到 libmpv（`UrlStreamVideoClient` 也改实现它，播放页不再特判具体类）、字幕同站才带头、封面经扩展 OkHttp | `fushi/lib/src/media/video/online/anime_source_video_client.dart`、`sync/remote_video_client.dart`、`video_fushi_page.dart` |
| UI | 浏览页 `MihonSourceBrowsePage` 按 `manager.kind` 分派调用面与详情页（预览安装流程天然可用）；`AnimeSourceDetailPage`（详情 + 剧集 → 选线路 → `VideoFushiPage.neutralizedRemote`）；`VideoOnlineSourcesPage`（内嵌扩展页 + 源列表）；视频「来源」视图加入口卡；`StoreRestrictedCapability.onlineVideoSource` 合规门 | `mihon_source_browse_page.dart`、`media/video/online/*`、`media_sources_page.dart`、`store_compliance.dart` |
| Android | gradle `prepareAniyomiSourceApi`（把 sidecar vendored 的 `animesource/**` + `util/lang/CoroutinesExtensions.kt` 编进 app，零下载、与桌面同 ABI）；Loader 认 `tachiyomi.animeextension`、lib 14 门、`AnimeSource`/`AnimeSourceFactory`；ChannelHandler anime 分支；ModelBridge / PreferenceBridge 泛化；proguard keep `animesource.**` | `fushi/android/app/build.gradle`、`.../mihon/*.kt`、`proguard-rules.pro` |
| 默认仓库 | **yuzono/anime-repo**（`https://raw.githubusercontent.com/yuzono/anime-repo/repo/index.min.json`，Anikku 维护者，GitHub 原仓、有签名指纹、2026-09 日更、内容是已消失的 Kohi-den 的超集） | `kMihonDefaultAnimeStoreIndexUrl` |

## 2. lib 版本钉定：只收 extensions-lib 14

- 实测（2026-09-19）：Kohi-den 镜像 240/240 扩展 lib 14；yuzono 254 里 239 个 lib 14、15 个 lib 16（Secozzi 的 Jellyfin / Stremio / Torbox 与 Mapple 等正在迁）。
- lib 16 换了 `Video` 构造签名（`Video(videoUrl, videoTitle, resolution, …)`）并改走 Hoster API（`getHosterList(episode)` → `getVideoList(hoster)` → `resolveVideo`），与 sidecar vendored 的 lib 14 ABI 不兼容——装进来会在第一次取流时炸。所以桌面 `/inspect` 与 Android `inspect()` 都在**安装门**拒掉并说明原因（`UNSUPPORTED_LIB`）。
- **升级路径**（后续独立 PR）：Aniyomi 主线 `source-api/src/commonMain` 是 14/16 超集宿主（lib 14 方法以 `@Deprecated` 共存）；把 sidecar 与 Android 的 `animesource` 源码换成它、`MihonInvoker` / `MihonChannelHandler` 加 Hoster 分发、`MihonVideo` 加 `videoTitle/resolution/preferred`，即可两代并存。届时把 `MihonMediaKind.anime.supportedLibVersions` 放开到 `['14', '16']`。

## 3. 平台矩阵

| 平台 | 视频扩展 | 说明 |
|---|---|---|
| Windows / macOS | ✅ | 桌面 sidecar（与漫画共用一个 JVM 进程） |
| Android | ✅ | 原生宿主，dex 加载 |
| iOS | ❌ | `StoreRestrictedCapability.onlineVideoSource`（与漫画在线源同一条合规理由） |
| Linux | ❌ | 无 Mihon 宿主（同漫画） |

## 4. 刻意不做（本期）

- **入库/收藏**：浏览态零入库，作品页只播不存；收藏建行（对齐漫画 `OnlineMangaLibraryEntry` 的范式，落 `VideoBooks` + 集状态）是二期。
- **下载离线**：`downloadRemoteVideo` 抛 `UnsupportedError`（直链可下、HLS 要分片合并或 ffmpeg remux）。
- **观看统计**：远端条目同样进学习统计（BUG-2587 起互联/Jellyfin 远端一律计，采集器按 `_watchStatsIdentity` 建），`media_key` = `anime-source:<pkg>:<sourceId>:<episodeUrl>`、按集独立；只有看完标记/单集完成上报因无 VideoBooks 行不发。
- **全局搜索 / 发现页热门行**：漫画有 `MangaGlobalSearchRunner`，视频侧本期只做单源浏览。
- **lib 16**：见 §2。

## 5. 验证

- Kotlin：sidecar `tool/mihon/build_desktop_runtime.ps1`（`:server:test` 含 `AnimeResponseTest` 4 例）BUILD SUCCESSFUL；Android `:app:compileDebugKotlin` 通过。
- Dart：`mihon_anime_models_and_bridge_test`（wire 契约）、`mihon_manager_media_kind_test`（生态门 / lib 门 / 分片 / 默认仓库 / 共享 runtime 不被误关）、`anime_source_video_client_test`（id 稳定、选流、headers、字幕同站、封面走扩展）、`anime_source_detail_page_test`（浏览 → 作品页 → 起播、多线路选择、无流不起播）、`migration_v107_extension_media_kind_test`；既有 Mihon 定向测试 148 例绿。
- 真机：**未做**（本机无 Aniyomi 扩展可用的验证站点；桌面 sidecar 包已在本机构建出 `mihon_bridge`，装一个 yuzono 扩展走「来源 → 视频源 → 浏览 → 作品 → 播放」即可复测）。
