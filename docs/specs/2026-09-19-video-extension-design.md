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
| UI | 浏览页 `MihonSourceBrowsePage` 按 `manager.kind` 分派调用面与详情页（预览安装流程天然可用）；`AnimeSourceDetailPage`（详情 + 剧集 → 选线路 → `VideoFushiPage.neutralizedRemote`）；视频「导入」视图（`MediaSourcesPage`）顶部分段选择器 `ImportPageSegmentBar`（本地 / 仓库 / 扩展 / 在线源，与漫画来源页同构），仓库与扩展段复用 `MihonExtensionsPage(sections:)`、在线源段复用 `MihonInstalledSourcesSection`（原独立页 `VideoOnlineSourcesPage` + 入口卡已于 2026-09-19 并入）；`StoreRestrictedCapability.onlineVideoSource` 合规门（`video_online_sources_gate.dart`） | `mihon_source_browse_page.dart`、`media/video/online/*`、`media_sources_page.dart`、`media/import/import_page_segments.dart`、`store_compliance.dart` |
| Android | gradle `prepareAniyomiSourceApi`（把 sidecar vendored 的 `animesource/**` + `util/lang/CoroutinesExtensions.kt` 编进 app，零下载、与桌面同 ABI）；Loader 认 `tachiyomi.animeextension`、lib 14 门、`AnimeSource`/`AnimeSourceFactory`；ChannelHandler anime 分支；ModelBridge / PreferenceBridge 泛化；proguard keep `animesource.**` | `fushi/android/app/build.gradle`、`.../mihon/*.kt`、`proguard-rules.pro` |
| 默认仓库 | **yuzono/anime-repo**（`https://raw.githubusercontent.com/yuzono/anime-repo/repo/index.min.json`，Anikku 维护者，GitHub 原仓、有签名指纹、2026-09 日更、内容是已消失的 Kohi-den 的超集） | `kMihonDefaultAnimeStoreIndexUrl` |

## 2. 宿主 ABI：lib 14 + lib 16 并集（2026-09-19 二修，BUG-2600）

- 第一版只收 extensions-lib 14，判据是索引里的 `version` 主号（yuzono 239/254 写 14）。**判错了**：这批 `v14.x` APK 的 dex 全部引用 `getHosterList` / `Hoster` / `seasonListParse`，它们编译的是 `komikku-app/aniyomi-extensions-lib@f5961b5`（Anikku 系），公开面就是 lib 16——`Video` 是 data class `Video(videoUrl, videoTitle, resolution, bitrate, headers, preferred, subtitleTracks, audioTracks, timestamps, mpvArgs, ffmpegStreamArgs, ffmpegVideoArgs, internalData, initialized)`，老构造只作 deprecated 兼容；`SEpisode` 多 `fillermark / summary / preview_url`，`SAnime` 多 `background_url / fetch_type / season_number`。在纯 lib 14 宿主上：KickAssAnime 取流 `NoSuchMethodError: Video.getVideoTitle()`（被扩展的 `parallelCatchingFlatMap` 吞成 0 条）、AniDB 剧集列表炸在 `fillermark`——就是用户报的「进不去源 / 播不了」。
- 现在 `third_party/m_extension_server/overlay/.../animesource/**` 是两代 ABI 的并集（桌面 sidecar 与 Android `prepareAniyomiSourceApi` 同一份源码，Android 的 Sync 任务把 overlay 叠在 upstream_src 上）：lib 16 的构造 / `copy` / `componentN` 描述符逐字对齐 stub，lib 14 的 deprecated 构造、`Video.url` / `Video.quality`、`videoUrl` setter、`getVideoList(episode)` / `videoListParse(response)` / `getVideoUrl` / `videoUrlParse` 保留；一代声明 abstract 而另一代不认识的成员全部 `open` 带抛默认，否则 JVM 拒绝实例化另一代的类。`AnimeHttpSource.getHosterList` 用反射判「宿主 ABI 包之下有没有类 override `hosterListParse`（Parsed 还看 `hosterListSelector` / `hosterFromElement`）」决定走 Hoster 请求还是把 lib 14 视频表包成 `NO_HOSTER_LIST`——不靠先发请求再看它失败。
- 取流统一走 `animesource/host/AnimeVideoLoader.kt`（Hibiki 自己的，非 lib 成员），与 Aniyomi 播放器同口径：`getHosterList` → `sortHosters` → 每个 hoster `videoList ?: getVideoList(hoster)` → `sortVideos` → 每条 `resolveVideo`（未 `initialized` 才跑）→ 仍未解析则 lib 14 `getVideoUrl`；lazy hoster 只在 eager 一条都没出时展开；解析不出的候选丢弃、全死才抛第一个真实异常。桌面 `DalvikHandler` 与 Android `MihonChannelHandler` 的 `getVideoList` 都改走它，通道投影加 `videoTitle / resolution / bitrate / preferred / mpvArgs`。
- 选流与 Aniyomi `HosterLoader.selectBestVideo` 同口径：`preferred` 优先，否则扩展排好的第一条（扩展设置里的画质 / 语言偏好由它自己的 `sortVideos` 落实）。第一版「行数最高」会把用户在扩展设置里选的画质整个作废，已改。
- 安装门收 14 / 15 / 16（`MihonMediaKind.anime.supportedLibVersions`、`InspectHandler.supportedLibVersionLabel`、Android `MihonExtensionLoader.supportedLibVersionLabel` 三处同表）。Aniyomi 主线再往后的 `HttpServer` / `ThumbnailInfo` / `SAnimeEpisodeUpdate`（lib 17 域）未 vendored，仍拒。
- 同类适配参考：只读子模块 `references/mangayomi/`（Mangayomi 当前上游 sidecar 也做 Hoster 展开 + `getVideoUrl`，桌面端还多一层本机 `/video/{token}` 代理——Hibiki 本期未做代理，防盗链头经 `RemoteVideoStreamHeaders` 直接下发 libmpv）。

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
- 真实扩展（2026-09-19 二修）：用 overlay 构建的桌面 sidecar 直接打 yuzono APK（探针脚本：起 java sidecar + `FUSHI_MIHON_TOKEN`，POST `/dalvik` 带 base64 APK 与 `__mangatan_bridge_context__` 偏好项，走「`sourcesAnime` → `getPopularAnime` → `getDetailsAnime` → `getEpisodeList` → `getVideoList` → 带扩展 headers 的 Range 拉流」）。基线（旧 ABI）：KickAssAnime 0 条视频 + `NoSuchMethodError Video.getVideoTitle()`；修后结果记在 PR 描述。sidecar 单测 `AnimeVideoLoaderTest`（5 例）+ `AnimeResponseTest`。
- 真机 UI 全链路（来源 → 视频源 → 浏览 → 作品 → 播放页起播）：仍未做。anidb.app 于 2026-09-19 整站 503 维护中，该源需站点恢复后复测。
