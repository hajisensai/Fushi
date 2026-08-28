## BUG-1911 · 下载中的游戏不在库里占位：看不出到底加没加进来
- **报告**：2026-08-28（用户：「刚开始下载的、下载一半的应该也进到库里面占位。否则不知道是否加入了，毕竟发现已经获取到对应的名称和封面了」）
- **真实性**：✅ 功能缺口。

### 现状

游戏库页只渲染 `Galgames` 表里的行，而**入库只发生在下载完成、解压、挑出主 exe 之后**
（`discovery_import_production.dart` 的 `registerGameExes` → `galgameRepo.addAll`；
上游 `discovery_import_plan.dart` 必须先拿到完整文件树才挑得出 exe）。下载途中零写库动作，
游戏域也没有「扫描根」概念。于是用户点完下载，库里什么都不会出现，只能靠记忆判断
「我到底点了没有」。

### 设计取舍：占位是**渲染**出来的，不是**存**出来的

**刻意不往 `Galgames` 表写占位行**：

- `Galgames.exePath` 是 **NOT NULL**，且整张表**没有任何状态列**——一行存在就等于
  「本机有一个可启动的 exe」（`GalgameEntry.hasLocalExe => exePath.trim().isNotEmpty`，
  而且全仓没有任何写入点会造出 exePath 为空的行）。
- 为占位造一行意味着要么写个假路径，要么加 schema 列 + 迁移；还得回答「下载失败/取消后
  这行归谁删」「同步与墓碑怎么算」「用户点它会发生什么」。
- 而**下载队列本身就是这些条目此刻的唯一真相源**，并且随手带着用户点名的那两样东西
  （`item.title` / `item.coverUrl`）。

所以：在途下载在库页**渲染**成占位卡；下载完成走既有入库路径落成真条目，失败/取消则
自然消失，没有任何需要清理的中间状态。

### 实现与测试

- **[x] ① 已实现** —
  - `games_library_page.dart` 监听 `AppModel.discoveryDownloadQueue`（ChangeNotifier），
    在散卡网格**之前**插一段占位网格（用户刚点完下载，第一眼要能确认「加进来了」）。
  - 占位卡复用同一张 `GalgamePosterCard`：封面压暗到 0.45（与旁边可启动的真条目一眼可分）、
    底部一条进度、角标显示百分比 / 排队中 / 重试中。总大小未知时显示「下载中」而不是
    0% 或 NaN。不可点——它还不是一个能启动的游戏。
  - 逻辑抽成顶层纯函数 `pendingGameDownloads` / `pendingGameDownloadLabel` /
    `buildPendingGameDownloadCard`（同文件的 `buildGameCollectionMemberCard` 是同一范式），
    并给 `DiscoveryDownloadTask` 加了 `@visibleForTesting` 的种子构造——它的真实构造只能
    由 `enqueue` 触发并立刻开始跑网络，为测一张卡去起真下载不划算。
  - 新增 3 条 i18n（17 语言）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/games_library_pending_download_test.dart` 7 项：
  只收「游戏域 + 尚未结束」的任务（done/failed/cancelled 与别的媒体域都排除）、
  百分比/未知大小/排队/重试四种标签、占位卡真渲染出发现页的名称与进度、无封面不崩、
  以及**设计守卫**——占位路径不得出现任何写库原语（`upsertGalgame` / `addAll` /
  `setGames` / `newGalgameEntryFromExe`），且队列监听必须成对绑定/解绑。
  **变异实测**（2026-08-28）：把过滤放宽成「所有游戏任务」（= 占位卡永不消失）→ 转红。
  还原后 games library + discovery + i18n 共 113 项全绿。

### 备注

- **只覆盖发现页的 HTTP 直链队列**（shinnku / AList）。torrent 通道的游戏计划落 JSON
  文件、没有变更通知，而且 `AnimeDownloadPlan.coverUrl` 对游戏计划**恒为 null**、标题是
  从磁链 `dn=` 解析的——没有用户所说的「名称和封面」可占位。要覆盖它得先让计划存储可
  监听并在推送磁链时带上发现页元数据（`pushGenericMagnet` 的签名里现在没有这两个参数），
  是另一条独立的改动。
- 视频域有个形似但**不同**的机制 `AnimeDownloadPlan.importedEarly`（边下边播提前入库真
  条目），且对游戏显式排除（`anime_download_service.dart` 明写 keepDownloading 只对视频
  有意义）。本条不是它。
- 未做真机复测（需要真实 shinnku 下载）。纯函数 + widget 层已覆盖。
