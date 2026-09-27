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

## 阶段 2：来源浏览页与作品页统一为视频形态

- 现有三份几乎同形的浏览页：`MihonSourceBrowsePage`（漫画 + 视频共用）、`LnReaderSourceBrowsePage`、`AidokuSourceBrowsePage`。收成一个吃适配器的 `OnlineSourceBrowsePage`，适配器接口为 fetchPage / filters / cover / openDetail / cloudflare。筛选语义差异由适配器表达：LNReader 筛选作用在热门上，Mihon 筛选切到搜索。
- 从 `AnimeSourceDetailPage` 抽出作品页骨架，结构是封面 + 元数据、简介、条目列表，页头放网站 / 刷新；点行即在线打开。主操作区三个槽：在线开始 / 继续、加入书架、下载。
  - 小说：`LnReaderNovelDetailPage` 本来就是这个形态，迁到骨架上。
  - 漫画：Mihon / Aidoku 详情不再直接进 `MangaSeriesPage`，改走骨架。点章用在线直读；加入书架用 `OnlineMangaLibraryService.add`。已在库时按钮变成「打开书架页」，进 `MangaSeriesPage`，OCR / 已读 / 订阅 / 自动下载留在那里。
  - 视频（阶段 2b，另起设计稿）：在线集目前只以 `RemoteVideoInfo` 记进度、不进库表。「加入媒体库」需要新的持久模型，大概率升 schema；「下载」复用 `AnimeVideoLoader` 取流 → 下载队列 → 按本地视频入库。

## 阶段 3：发现页统一为视频发现页交互

以 `video_discovery_page.dart` 为准：
- 搜索防抖 350ms；
- 分类用 chip，窄屏时筛选收进底部弹层；
- 横滑行 + `SliverGrid`，滚到底自动翻页；
- 部分失败时显示横幅。

漫画发现页、书 / 游戏资源站发现页的控制区与结果形态向它靠拢。资源站没有作品详情，目录下钻保留。
