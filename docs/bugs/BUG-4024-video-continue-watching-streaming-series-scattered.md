## BUG-4024 · 继续观看里 Netflix 等流媒体剧集按集散开、不归组
- **报告**：2026-11-02（fushi-bot 代提交 #GBDddvjDsj，QQ 群：「继续观看的时候好像不会保留剧集列表，只有单集。网飞等流媒体直接缺少剧集列表，全散出来了」；无版本 / 平台）
- **真实性**：
  - **本地合集部分 ✅ 真 bug（2026-11-04 用户实测复现，推翻先前「未复现」结论）**：先前只查了视频页「继续观看」合集主卡（`home_video_page.dart:6441` `_openSlot(target, playlistCollectionId: collection.id)`），漏了别的打开路径。播放页的剧集面板 / 上下集 / 连播完全由路由参数 `playlistCollectionId` 决定，而共享路由入口 `openLocalVideoBook`（`fushi/lib/src/pages/implementations/home_video_page.dart:200`，修前）把「没传合集 id」直接当散片单视频打开；系列上下文要靠**每个调用方**自己查归属再传，多个入口没传：
    - 侧边栏「继续观看」预览：`fushi/lib/src/pages/implementations/home_nav_peek.dart:334` `openLocalVideoBook(context:, repo:, bookUid: v.bookUid)`——侧边栏本身按合集折叠显示（`foldNavPeekByCollection`），点进去却不带合集 id。**用户报的侧边栏路径即此处。**
    - 视频页「继续观看」散片主卡 / 散卡：`home_video_page.dart:6379` `_open(book)`、`:6999` `_open(book)`——按当时的 `_primaryCollectionByEntry` 判为散片才走这里；映射加载失败时（`:1261` 置 ready 但映射为空）合集成员全部落成散片，点开同样无剧集列表。
    - 发现页本地作品：`fushi/lib/src/pages/implementations/home_page.dart:3520` 只传 `bookUid`。
    - （统计中心 `statistics_center_page.dart:609`、视频统计 `video_statistics_page.dart:406`、仪表盘 `home_dashboard_page.dart:3430` 自己查原始主归属后传入，不缺列表。）
  - **根因**：系列上下文的归属判定散落在各调用方，共享入口不持有它（`home_video_page.dart:200` 修前 `playlistCollectionId` 为 null 即单视频）。
  - **流媒体网页档部分 ✅ 真问题（缺结构，不是逻辑 bug）**：Netflix 等站点在播放页网页档里每播一集就按集落一本独立的流媒体书（`fushi/lib/src/media/video/web_video_sites.dart:216` `ensureWebVideoEpisodeBook`，文件头注释写明「按集记，不会全堆在一本 Netflix 上」），这些书不进任何合集、也不记所属剧集身份；首页 `home_video_page.dart:5731` 把没有合集归属的书一律当散卡，于是看过的每一集各占一张卡。剧集列表在播放页里是有的（`video_fushi/web_source.part.dart` `_applyWebNetflixMetadata` 按站点 metadata 现建），只是没有任何持久结构把同一部剧的各集连起来。
- **[x] ① 本地部分已修复**：共享入口 `openLocalVideoBook` 在调用方没给合集 id 时自己解析系列上下文——新增 `resolveVideoPlaylistCollectionId`（`fushi/lib/src/media/video/video_folder_collection_policy.dart:79`），与视频页折叠归属**同一判据**（原始主归属 MIN(collectionId) 经 `applyVideoFolderCollectionPolicy` 修正、合集行须存在），散片解析为 null 仍按单视频打开。侧边栏 / 散卡 / 发现页 / 外部调用一并修好，后续新入口无需记得传 id。仓库层补 `VideoBookRepository.getAllCollectionItems` / `getMediaSourceById` 透传。
- **[x] ② 本地部分已加自动化测试**：`fushi/test/media/video/video_playlist_collection_resolve_test.dart`——真 drift 内存库验解析器（成员→合集、散片→null、多合集取与库折叠相同主归属、folder / series 档目录合集）＋源码守卫（共享入口未给 id 时必经解析器再推路由、侧边栏仍走共享入口）。
- **[ ] ① 流媒体网页档部分未修复** — 需要先定方案（结构性改动，涉及合集 / 同步，未擅自实现）。可选方向：
  1. 绑定一集时若拿到站点剧集 metadata（Netflix `NetflixTitleMetadata.id` = 剧 id），按「站点 + 剧 id」找或建一个 playlist 合集（`createMediaCollection(..., collectionType: 'playlist')` + `addToCollection(userIntent: false)`，与 IPTV 导入同一范式），成员顺序按 metadata 季 / 集排；首页自然归组、续播带 `playlistCollectionId`。待定：合集只含看过的集时 Next-Up（`continueWatchingSeriesIndex`）在「最后一集看完、下一集还没落书」时整部消失；网页档带 `playlistCollectionId` 进页时剧集面板以站点 metadata 为准还是合集成员为准；合集会经互联同步到其它设备。
  2. 不建合集，给流媒体书记「剧身份」列（schema 变更）由首页按它归组，续播打开时由站点 metadata 建剧集面板。
- **[ ] ② 流媒体网页档部分未加自动化测试** — 随方案定后补（首页归组纯函数 / 绑定集落合集的仓库层测试）。
- **未验证**：本地部分未在真机 / 桌面实机复测点击路径；若用户的合集成员在 series 档下只属于被策略剔除的目录合集（无系列合集），按库折叠口径它本就是散片，解析为 null，仍不会有剧集列表——那是分组档位问题，不在本修复范围。
- **备注**：反馈正文里机器人的猜测（`_collectContinueItems` 只按合集归组）方向对，但根因在数据层缺剧集归属，改首页分组逻辑本身补不出来。存量已散开的各集需要一次回填（按书 videoPath 里的 watch id 重拉 metadata）或只对新看的集生效，也是待定项。
