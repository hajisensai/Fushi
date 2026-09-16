## BUG-2548 · 合集详情页丢掉全部远端成员：行头 N 项、点进去只剩本地几本
- **报告**：2026-09-15（用户：合集内没显示远端数据。截图：书架合集行头「安達としまむら 14 项」、
  行体第二张是带云角标的远端卷；点「查看全部」进详情页只剩 2 本本地书，一个云角标都没有）
- **真实性**：✅ 真 bug，且**不是**「成员行没落库」——行是在的：
  - 详情页 `MediaCollectionGridDetailPage._reload()`
    （`fushi/lib/src/pages/implementations/media_collection_grid_detail_page.dart:107`）
    读 `getCollectionItems`，host 归属早已由
    `packages/fushi_engine/lib/sync/remote_collection_adoption_service.dart:36`
    （`adoptRemoteCollectionMember`）收养落成透传成员行，云盘归属由合集同步落行。
  - 闸门在成员卡构造器：`reader_fushi_history_page.dart:2062` / `:2093`
    （`_buildCollectionMemberCard`）只遍历 `_visibleSrtBooks` / `_visibleEpubBooks`，
    本地匹配不上就 `return null`；该函数**完全没有** `RemoteBookInfo` /
    `RemoteAudiobookInfo` 分支（书架主网格的 `_buildShelfMemberCard` 早就有）。
  - 返回 null 的行被详情页静默跳过（`media_collection_grid_detail_page.dart:313`），
    全 null 时还会显示「合集为空」——在客户端把一个非空合集判成空。
  - `_openCollectionMember`（`:2110`）同样只认本地，成员即便画出来也点不开。
  - 对照组：视频侧 `CollectionEpisodeSlot`（`fushi/lib/src/media/collections/collection_episode_slot.dart`）
    早就把「本地查不到的成员键去远端清单补」做成了 union 语义，注释里点名 BUG-1704
    「把成员窄化成本地行 = 在客户端把整个合集判空」。书籍侧漏跟。
- **[x] ① 已修复** — `_buildCollectionMemberCard` 的两个 `return null` 前加远端回退
  （`_remoteBookForEntry` / `_remoteSrtForEntry`：按 `downloadId` / `identity` 比，epub 再按
  `sanitizeTtuFilename(title)` → uid 换算比一次，与主网格折叠归属注入同口径）；
  `_openCollectionMember` 同样补远端分支（点击 = 下载入库，与书架占位卡 onTap 同路径）。
  可见门控 `_detailRemoteState` 与书架主网格的 `showRemote` 逐条同源（目录未失败 +
  「显示远端条目」开关 + 同步模块启用 + 无标签筛选），两侧同门才不会出现
  「行头数字与详情页对不上」。远端卡新增 `focusIdPrefix` 参数隔离焦点 id 命名空间
  （BUG-1009：详情页 push 在书架之上，两条路由同时存活，同名 focusId 会被注册表覆盖）。
- **[x] ② 已加自动化测试** —
  `fushi/test/pages/reader_remote_collection_membership_test.dart` 两条真 widget 行为测试：
  ①「本地 1 本 + 远端 1 本」的合集，点「查看全部」后详情页里必须能找到远端占位卡；
  ②「全员远端」的合集，详情页不得显示「合集为空」。
  反向验证：把两个源文件还原成上游原版后两条全红。
- **备注**：与 [BUG-2547](BUG-2547-shelf-remote-sort-ignored.md) 同一次用户报告，同一 PR 修。
  远端成员的「移出合集」走详情页网格自身的长按/右键菜单（对任何卡片都可用）；远端卡的
  卡片级对话框不注入 `removeFromCollection`，与书架侧远端卡保持一致。
