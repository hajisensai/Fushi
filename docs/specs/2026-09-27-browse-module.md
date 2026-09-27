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

### 2b 视频「加入媒体库」「下载」（设计稿，待所有者确认）
**不升 schema**，复用 TODO-1157「流媒体书」的形态（`VideoBooks` 里 `videoPath` + `streamSpecJson` 描述怎么重开）：

- **加入媒体库**：每集一行 `VideoBooks`。
  - `bookUid` 沿用 `RemoteVideoInfo.id`（`anime-source:<包>/<源>/<集 URL>`）。播放页已按这个 id 记断点、字幕记忆与调轴，入库前后的进度自然连续。
  - `videoPath` 写一个非 http 的 `anime-source://…` 标识，避免被 `isStreamVideoBook` 误判成直链。
  - `streamSpecJson` 写 `{kind: anime-source, extensionPackage, sourceId, animeUrl, episodeUrl, animeTitle}`。
  - 同一作品的集用 playlist 类型的 media collection 归组，封面与标题取作品详情。
  - 重开时由 `stream_video_launch.dart` 新增的 anime-source 分支按描述重建 `AnimeSourceVideoClient`，取流仍走播放页的「正在连接视频流」阶段；扩展被卸载时在书架给出明确提示。
  - 刷新剧集时只补新集，不删已看的集。
- **下载**：先用宿主 `AnimeVideoLoader` 解析出选中那条流（URL + 防盗链头），再按流的类型分两路：
  - 直链 mp4 / mkv 进 `DiscoveryDownloadQueue`（已有的直链队列，任务出现在「浏览 › 下载」）；
  - HLS 走一条 ffmpeg `-c copy` 转封装任务。ffmpeg-min 已带 hls demuxer（BUG-2630）；中继的图片伪装分片处理（BUG-2609）需要复用到这一路。
  - 下完落地的文件按本地视频入库，并替换掉那一集的在线行（同 bookUid，进度保留）。
- 风险：扩展取到的流 URL 多数有时效，下载必须在解析后立即开始，失败时重新解析而不是重试旧 URL。部分源的 HLS 带 AES 加密，ffmpeg 可以解；DRM 源不支持，要明确报错。

## 阶段 3：发现页统一为视频发现页交互

以 `video_discovery_page.dart` 为准：
- 搜索防抖 350ms；
- 分类用 chip，窄屏时筛选收进底部弹层；
- 横滑行 + `SliverGrid`，滚到底自动翻页；
- 部分失败时显示横幅。

漫画发现页、书 / 游戏资源站发现页的控制区与结果形态向它靠拢。资源站没有作品详情，目录下钻保留。
