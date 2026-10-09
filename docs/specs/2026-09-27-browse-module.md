# 「浏览」模块：下载改名 + 发现 / 扩展收拢 + 三域在线源统一

2026-09-27 用户口径：「下载模块改名为浏览，参考一下 mihon 系软件的命名习惯。另外小说 漫画 视频 游戏模块的发现页和扩展系统的 ui 移除掉全部放到浏览那，并且统一小说漫画视频的操作逻辑和 ui，设计以目前视频的操作逻辑为主。」

追问后的拍板：
- 浏览页按**功能**分页签（Mihon：Sources / Extensions），不按媒体域分；页签内再选小说 / 漫画 / 视频 / 游戏。
- 下载中心的任务 / 订阅作为浏览里的「下载」页签（Fushi 没有 Mihon 的 More 页）；下载设置改成页头齿轮。
- 三域作品页统一成视频的形态：**默认点章节 / 集直接在线看**，小说 / 漫画 / 视频都另有「加入书架（媒体库）」与「下载」。
- 分阶段：先搬迁，再统一在线源浏览页与作品页，最后统一发现页。

## 阶段 1（本 PR）：改名 + 搬迁 + 删旧入口

| 之前 | 之后 |
|---|---|
| 顶层「下载」tab（`HomeTab.downloads` / `ModuleId.downloads`，下载图标） | 顶层「浏览」tab（`HomeTab.browse` / `ModuleId.browse`，`Icons.explore`）；**持久化键仍是 `module_downloads_enabled`、设置项 id 仍是 `system.module_downloads`** |
| `DownloadsPage` 四页签：资源 / 任务 / 订阅 / 设置（`int` 下标跳转） | `BrowsePage` 四页签：来源 / 扩展 / 发现 / 下载（`BrowseTab` 枚举跳转）；「下载」内分任务 / 订阅；设置 → `BrowseDownloadSettingsPage` |
| 书架「浏览」视图、漫画库「发现」视图、视频库「发现」分区、游戏「发现」子区 | 删除，只在浏览 › 发现 |
| 书 / 视频「导入」视图的仓库 / 扩展 / 在线源三段；漫画「导入」视图的仓库 / 扩展 / 在线源三段 | 删除，只在浏览 › 来源 / 扩展（仓库是扩展页签的「仓库」动作）；导入页只剩本地来源，漫画导入页保留互联对端那一行（不受合规边界约束） |

页签可见性：
- 来源 / 扩展：至少一个域有在线宿主且对应库模块开着时出现（小说 = `isNovelOnlineSourcesAvailable`；漫画 = `onlineMangaSource` 合规门 + `MihonRuntimeFactory.isSupported`；视频 = `isVideoOnlineSourcesAvailable`）。Linux 没有 Mihon 与 headless WebView，只剩发现 / 下载。
- 发现：书 / 漫画 / 视频 / 游戏（仅本机游戏库形态）任一模块开着时出现。
- 下载：恒在。
- iOS：整个模块不存在（`ModuleId.browse` 委托 `StoreRestrictedCapability.downloads`），页签内每个域仍各自问对应能力值（纵深防御）。

行为变化（须知）：
- 关掉「浏览」模块后，发现与在线源在所有平台上一起消失。此前各库页的发现视图跟着各自的库模块走，与下载模块无关。
- 视频发现详情「查看下载」此前落到下标 0，也就是「资源」页签，实际不是下载任务。现在落到浏览 › 下载 › 任务。

阶段 1 刻意没动的：
- 漫画发现页底部的「浏览来源」节（`MangaSourceCatalogSection`）仍在。它和发现页的来源下拉 / 热门行共用一份快照，留到阶段 3 连同发现页一起处理。
- 更新中心的「扩展更新」仍 push 独立的 `MihonExtensionsPage`。

## 阶段 2：来源浏览页与作品页统一为视频形态（已做 2a，2b 待拍板）

### 2a（本分支已实现）
- **源浏览页只剩一份**：`lib/src/media/online/online_source_browse_page.dart` 的 `OnlineSourceBrowsePage<T>`，差异收进适配器 `OnlineSourceCatalog<T>`。`MihonSourceBrowsePage`（漫画 + 视频扩展）、`LnReaderSourceBrowsePage`、`AidokuSourceBrowsePage` 三页各只剩一个适配器。
  - 列表：Mihon / LNReader 是热门 / 最新，Aidoku 是包自己声明的 listing，Aidoku 原来的页头下拉框改成分段条。
  - 筛选应用后的去向由适配器决定：Mihon 切到搜索，LNReader 回到热门并清空搜索词。
  - 翻页按视频发现页的口径：离底 600 以内自动加载下一页，保留「加载更多」格作为键盘 / 手柄兜底。
- **作品页版式只剩一份**：`lib/src/media/online/online_work_detail.dart`，从视频源作品页抽出。
  - 头部：120×170 封面 + 标题 / 元信息 / 类型标签 + 主操作区，简介在头部下方整宽；条目区是小标题加一行一条，点行即在线打开。
  - 视频：主操作「播放 / 继续观看 · 第 N 集」，落点按播放页合集模式的远端断点键 `(成员 id, 0)` 取最新一集。
  - 小说：「在线阅读 / 继续阅读」「加入书架 / 移出书架」「下载」三个动作。「加入书架」只建在线书、不开阅读器；此前它其实是整本下载，与漫画的语义不一致。移出书架和漫画共用书架长按删除的确认框（`online_shelf_removal.dart`）。
  - 漫画：`MangaSeriesPage` 头部改用同一套版式，原有的继续阅读、加入 / 移出书架、下载全部、OCR 动作与章节列表不变。

### 2b 视频「加入媒体库」「下载」（已实现，2026-09-27 所有者：直接一次性做完）
**没有升 schema**，复用 TODO-1157「流媒体书」的存法。代码在 `fushi/lib/src/media/video/online/anime_source_library.dart` 与 `anime_episode_downloader.dart`，路径判据在 `packages/fushi_engine/lib/media/video/anime_source_video_path.dart`。

- **加入媒体库**（`AnimeSourceLibrary.addToLibrary`）：每集一行 `VideoBooks`。
  - `bookUid` = `AnimeSourceVideoClient.episodeVideoId`（入库前后断点连续）。
  - `videoPath` = `anime-source://<包>/<源>/<作品名> - E03`，最后一段只为可读。
  - `streamSpecJson` = `AnimeSourceBookSpec`，包含包、源、作品 JSON、本集 JSON。
  - 分组：经 `RemoteCollectionAdoptionService.adoptVideo` 归进以作品名命名的 playlist 合集。
  - 封面：经扩展取（`fetchRemoteCover`），每集写一份自己的封面文件（删行只回收自己的），另写一份合集封面。
  - 再点一次只补新集；「移出媒体库」只删在线行，已下载的集保留。
- **重开**（`buildAnimeSourceLaunch`，`VideoFushiPage._init` 的 anime-source 分支）：
  - 读打开时所在合集里同一作品的在线行，按行里的规格重建 client，不联网拉剧集。
  - client 的集 id 直接沿用各行的 bookUid（新参数 `episodeIds`），不按子集重算撞车后缀。
  - 这些行作为连播成员；扩展被卸载 / 停用时提示 `video_online_extension_unavailable`。
  - 合集连播时，进度写进当前那一集自己的行（此前写进起播那一集的行）。
- **不再当本地文件的地方**：凡是按 http 前缀判断「是不是本地文件」的门都改用 `isNetworkOnlyVideoPath` / `isAnimeSourceVideoPath`。
  - 涉及：资源缺失校验、抽帧、刮削（两处）、ffprobe 规格、备份可达性（Dart 判据与 merge SQL 同改）。
  - 互联 host 的 `listVideos` 不下发这类行：对端没有这个扩展，拿到也放不了。
- **下载**（`AnimeSourceVideoClient.downloadRemoteVideo` + `AnimeEpisodeDownloader`，任务交给 `InterconnectDownloadManager`，出现在「浏览 › 下载」）：
  - 每次（重）跑都重新向扩展取流（BUG-2617），挑线路与起播同一口径。
  - 直链走 `ResumableDownloader`。
  - HLS 在 Dart 端逐分片下载：master 取最高码率变体，`#EXT-X-MAP` 初始化段，`#EXT-X-KEY` AES-128 用 pointycastle 解，图片伪装前缀按 BUG-2609 同一判据剥掉。分片进度记在 `.hls.progress`，可断点续传。
  - HLS 下完后本地 `ffmpeg -c copy` 转封装为 mp4；转封装失败时原样保留分片流。
  - URL 没有 `.m3u8` 后缀但下回来是播放列表时，改走分片下载。
  - 独立音轨 master、BYTERANGE、SAMPLE-AES / DRM 如实报「不支持」。
  - 下完 `registerDownloaded`：同 bookUid 覆盖在线行（改成本地文件、清掉规格），默认字幕落在视频旁；之后作品页点这一集直接播本地文件。
- 已知限制：
  - 下载任务在进程被杀后不自动接回（流地址会过期，续传必须回到作品页重新解析）；已下完的分片仍在，重点下载会接着下。
  - 依赖 `mpvArgs` 的流下载可能失败。

## 阶段 3：发现页统一为视频发现页交互（已实现）
共享件在 `fushi/lib/src/pages/implementations/discovery/discovery_widgets.dart`，三页都在用：
- `DiscoverySearchDebouncer`：输入停 350ms 搜索，输入一变就作废在途请求；
- `discoveryShouldLoadMore`：离底 600 自动翻页，只认纵向滚动；
- `DiscoveryProviderWarningBanner`：部分失败横幅，印来源展示名，文案按失败性质选；
- `DiscoveryShelf`：横滑行，外包 `HorizontalDragScrollable`，加载中照样占住行高；
- `DiscoveryLoadMoreFooter`：翻页尾巴。

视频发现页改用这些共享件，key 与行为不变。

各页：
- **书 / 有声书 / 游戏资源站**
  - 输入停 350ms 自动搜索（清空路径栈，BUG-1768）；
  - 滚动自动翻页，「加载更多」保留作兜底；
  - 追加页失败保留已有结果、页码回退，给重试；此前会推翻整页、页码不回退；
  - 异常和全部失败用 `FushiPlaceholderMessage` 加重试；部分失败用共享横幅。
  - 下钻、面包屑、来源卡片网格、列表行都不变。
- **漫画**
  - 「全部来源」改为 `CustomScrollView`，热门行用共享 `DiscoveryShelf`；
  - 行失败汇总成页首横幅，全部失败时给整块提示加重试；
  - 单源网格按源的 `hasNextPage` 自动翻页（feed 新增 `loadPopularPage`）；
  - 空态和错误态统一用 `FushiPlaceholderMessage`。
  - 搜索**只在提交时**触发：漫画搜索是 push 全源聚合搜索页，防抖等于每停顿一下就推一页、给所有源各打一轮请求。
  - 「浏览来源」节保留：mokuro.moe / Aidoku / OPDS 没有热门行，这一节是它们在发现页唯一的入口。

## 2026-09-28 追加：发现排第一 + 四域 AI 下载

用户口径：「浏览模块无论是视频 小说 游戏 漫画都支持 ai 下载，浏览模块的排序发现改为排在第一个。」

- **页签顺序**：发现 → 来源 → 扩展 → 下载（`BrowseTab` 枚举与 `_visibleTabs` 列表字面量同改，守卫 `downloads_center_contract_guard_test` 钉住两处）。打开浏览默认落在发现。
- **AI 下载**：视频域沿用既有「AI 下视频」对话页；小说 / 漫画 / 游戏三个发现页的搜索行末尾各加一颗 ✨（`media-discovery-ai-acquire` / `manga-discovery-ai-acquire`），进 `AiMediaAcquisitionPage`。
  - 新 AI 功能指派 `AiFeature.mediaAcquire`（与视频分开指派；iOS 与视频同一合规门隐藏）。未指派时点按钮先引导去「设置 › AI」（`pushAiSettingsPage`，首页的 `_pushAiSettings` 也委托它）。
  - 流程：一句话 →（AI）最多 3 个搜索词 →（本地）各后端并发搜 →（AI）在按做种数排好的前 40 条里挑 ≤3 条推荐 → 用户逐条点「下载」。AI 任一步失败不挡流程：按原文搜、按本地分排。
  - 后端（`lib/src/media/acquisition/media_acquisition_backends.dart`）只复用既有下载路径：发现源 → `startDiscoveryItemDownload`（从发现页 `_download` 抽出，两处共用）；Mihon 漫画 → 加入书架 + 全部未锁章节进漫画下载队列（与作品页「下载全部」同一服务）；LNReader 小说 → 作品页同一个整本下载对话框。在线源是否参与与「来源」页签同一门；漫画在线源另需 Mihon 运行时。
  - 已知限制：Mihon / LNReader 只搜各源第 1 页；AI 推荐不做跨源同作品合并。

## 阶段 4：发现 / 来源 / 扩展加回库页子标签（2026-10-01）
起因：社区用户找不到漫画 / 小说的 OPDS（它只在「浏览 › 发现」里），并认为「往库里加东西」应该挂在各自的库下。所有者 / 用户拍板：**浏览模块保留、不回滚**，把发现 / 来源 / 扩展同时做成各库页的子标签，两处复用同一组组件。

| 库页 | 子标签（顺序） |
|---|---|
| 书架 | 书架 / 发现 / 来源 / 扩展 / 导入 / 设置 |
| 漫画库 | 书架 / 发现 / 来源 / 扩展 / 导入 / 设置 |
| 视频库 | 首页 / 系列 / 全部视频 / 媒体服务器 / 发现 / 来源 / 扩展 / 导入 / 设置 |
| 游戏（本机库形态） | 首页 / 游戏库 / 工作台 / 发现 / 导入 / 设置 |

- 共享件从 `browse_page.dart` 抽成公开：`visibleOnlineSourcesDomains` / `onlineSourcesDomainLabel` / `openOnlineSourceStores` / `BrowseSubPage`（`browse_online_sources_view.dart`），`discoveryAiAcquireAction`（`discovery_ai_acquire_action.dart`）。库页的来源 / 扩展是 `LibraryOnlineSourcesView`（页头主位放库页分段条，「扩展」页头挂「仓库」）。
- 门：发现过 `externalDiscovery`；来源 / 扩展过 `isOnlineSourcesDomainAvailable(域)`；游戏只在 Windows 本机库形态存在，不另过门。**不依赖浏览模块开关**——库页入口跟着库模块走，与 9/27 之前一致。
- 漫画发现页的「浏览来源」在库页里切到本库「来源」子标签（`MediaLibraryViewKind.onlineSources`），不再落到「导入」。
- 视频库「发现」与浏览页签共用 HomePage 的同一个生产发现端口实例。
- 游戏「发现」访问过才构建（`IndexedStack` 会急切构建全部子区，不能一开游戏 tab 就联网）。
- 未动：`browse_moved_notice.dart`（升级前关着「下载」的用户的一次性提示）。库页入口回来后它说的「搬到了浏览」只剩一半成立，是否删掉待所有者定。

## 2026-10-09 追加：下载方式 / 外部来源标注 + 下载前说明

起因：海外用户分不清浏览页里的下载是内置 BT 还是直链、要不要挂 VPN；所有者要求每个下载项醒目标出「外部来源」，用户追加游戏资源站的风险提示。

- **标签**（`fushi/lib/src/media/downloads/download_source_method.dart`）：`DownloadTransferMethod` = BT / 磁力 · P2P、直链 · HTTP、扩展源；`DownloadSourceTags` = 方式标签 +（可选）「外部来源」，点按弹一句技术说明。外部来源判据 `isExternalDiscoverySource`：内置发现源是第三方站点；用户自配的 OPDS / Audiobookshelf 不标。
- **挂在哪**：发现页结果行（四域）、AI 下载候选行、视频资源搜索结果区顶部（全是 BT，只放一条）、`DownloadTaskCard`（视频管线 / 旧番剧计划 / host 代下载 = BT；发现直链队列 = 直链；漫画 Mihon / Aidoku = 扩展源，mokuro.moe = 直链，互联对端 = 直链不标外部；扩展视频剧集 = 扩展源，互联 / 媒体服务器 = 直链不标外部）、三域在线作品页头部 chip（漫画互联对端除外）、游戏库在途下载占位卡。
- **说明框**（`fushi/lib/src/pages/implementations/download_notice.dart`，同一组件按 `DownloadNoticeKind` 换文案，各自记「不再提示」，勾选框默认不勾，取消 = 不下载）：
  - `p2p`：所有 BT 入口（发现页 torrent、旧番剧对话框推送与通用磁力、手动添加任务、视频资源搜索的下载 / 交给 host / 建订阅）。文案按事实写：IP 对同种子的人可见、开启上传才会上传（内置引擎默认关上传，外接 qBittorrent 按它自己的设置）。
  - `gameResource`：从第三方游戏资源站下载前（`startDiscoveryItemDownload` 一处，覆盖游戏库「发现」、浏览 › 发现 › 游戏、游戏域 AI 下载、`fushi_cli discover get`）。
- 偏好 `p2p_download_notice_dismissed` / `game_resource_notice_dismissed` 是本安装级，排除出 Profile 快照。
- iOS 没有这些入口（合规门不变）。
