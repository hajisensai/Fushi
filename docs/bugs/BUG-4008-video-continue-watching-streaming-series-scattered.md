## BUG-4008 · 继续观看里 Netflix 等流媒体剧集按集散开、不归组
- **报告**：2026-11-02（fushi-bot 代提交 #GBDddvjDsj，QQ 群：「继续观看的时候好像不会保留剧集列表，只有单集。网飞等流媒体直接缺少剧集列表，全散出来了」；无版本 / 平台）
- **真实性**：
  - **本地合集部分 ❌ 未复现**：首页「继续观看」对合集成员按合集归组（`fushi/lib/src/pages/implementations/home_video_page.dart:5724` `_primaryCollectionByEntry` 命中即进 `grouped`），点开走 `_openSlot(target, playlistCollectionId: collection.id)`（`:6434`），播放页据此建剧集面板 / 上下集 / 连播，剧集列表在。不属于任何合集的本地单集按设计是散卡。
  - **流媒体网页档部分 ✅ 真问题（缺结构，不是逻辑 bug）**：Netflix 等站点在播放页网页档里每播一集就按集落一本独立的流媒体书（`fushi/lib/src/media/video/web_video_sites.dart:216` `ensureWebVideoEpisodeBook`，文件头注释写明「按集记，不会全堆在一本 Netflix 上」），这些书不进任何合集、也不记所属剧集身份；首页 `home_video_page.dart:5731` 把没有合集归属的书一律当散卡，于是看过的每一集各占一张卡。剧集列表在播放页里是有的（`video_fushi/web_source.part.dart` `_applyWebNetflixMetadata` 按站点 metadata 现建），只是没有任何持久结构把同一部剧的各集连起来。
- **[ ] ① 未修复** — 需要先定方案（结构性改动，涉及合集 / 同步，未擅自实现）。可选方向：
  1. 绑定一集时若拿到站点剧集 metadata（Netflix `NetflixTitleMetadata.id` = 剧 id），按「站点 + 剧 id」找或建一个 playlist 合集（`createMediaCollection(..., collectionType: 'playlist')` + `addToCollection(userIntent: false)`，与 IPTV 导入同一范式），成员顺序按 metadata 季 / 集排；首页自然归组、续播带 `playlistCollectionId`。待定：合集只含看过的集时 Next-Up（`continueWatchingSeriesIndex`）在「最后一集看完、下一集还没落书」时整部消失；网页档带 `playlistCollectionId` 进页时剧集面板以站点 metadata 为准还是合集成员为准；合集会经互联同步到其它设备。
  2. 不建合集，给流媒体书记「剧身份」列（schema 变更）由首页按它归组，续播打开时由站点 metadata 建剧集面板。
- **[ ] ② 未加自动化测试** — 随 ① 定方案后补（首页归组纯函数 / 绑定集落合集的仓库层测试）。
- **备注**：反馈正文里机器人的猜测（`_collectContinueItems` 只按合集归组）方向对，但根因在数据层缺剧集归属，改首页分组逻辑本身补不出来。存量已散开的各集需要一次回填（按书 videoPath 里的 watch id 重拉 metadata）或只对新看的集生效，也是待定项。
