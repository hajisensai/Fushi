## BUG-1662 · 合集缺重新刮削入口：详情页无刮削项、单集无条目信息、菜单文案不含刮削
- **报告**：2026-08-15（用户：「缺一个刮削置顶合集的按钮，有个视频刮削错了，我没办法重新刮削」）
- **真实性**：✅ 真 bug。三个根因（改前 `develop@cc6ca656b5`）：
  1. 视频合集刮削全仓唯一入口是库页合集卡长按/右键菜单的 extraListActions
     （`fushi/lib/src/pages/implementations/home_video_page.dart:5118`），文案叫
     「在线匹配封面」（`video_scrape_online_match`）——内部就是整套合集刮削
     （`applyCollectionScrape`，资料 + 封面），但字面不含「刮削」，想重刮的用户
     按字面找不到。
  2. 合集详情页 AppBar 管理菜单（`media_collection_detail_page.dart:2334`）没有任何
     刮削项：原「刮削分集资料」死按钮在 `0288c2745e`（TODO-2791）删除后没有补
     「刮削合集」的活入口，「置顶合集 → 详情」这条唯一逃生路是断头路。
  3. 详情页集卡右键菜单（`media_collection_detail_page.dart:2221`，原
     `_EpisodeMenuAction` 只有 download/openBangumi/removeFromCollection）没有
     「条目信息/重新刮削」——合集语境下单集刮错了没有任何 UI 路径可重刮（库页
     墙上只有合集卡，摸不到成员）。
- **[x] ① 已修复** — 把合集刮削流程从 home_video_page 抽成共享
  `showCollectionScrapeDialog` + `runCollectionRelationsScrape`
  （`fushi/lib/src/media/video/cover_ui/collection_scrape_dialog.dart`，行为不变：
  只写合集自身不动成员 BUG-1211、fire-and-forget 拉相关作品 TODO-2484）；
  `MediaCollectionDetailPage` 新增注入位 `onScrape` / `onEpisodeScrapeInfo`
  （null = 不出菜单项，与 `onDeleteMembersMedia` 同一纪律），管理菜单首项出
  「刮削资料与封面」、集卡菜单出「条目信息」（复用库页 `_openScrapeInfo` 的
  删资料行 + forget + 重刮状态机）；`VideoWorkDetailPage` 透传；库页与放送日历页
  两个调用方接线；库页合集菜单文案改用新 i18n key `video_collection_scrape`
  （「刮削资料与封面」）。提交见本分支（worktree-collection-rescrape-entry）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/collection_detail_scrape_entry_test.dart`
  （widget 行为层）：管理菜单出「刮削资料与封面」且点击真触发回调；集卡菜单出
  「条目信息」且回调带对被右键的那一集；不注入回调时两项都不出现（不给死项）。
  已变异实测：把两个菜单项条件改恒假 → 两条正向守卫红、负向仍绿；还原后文件
  sha256 与变异前逐字节一致。
- **备注**：「置顶合集」= 视频首页最上方单元（无 pinned 持久化字段，纯「最近在看」
  推导）；hero 轮播 `_buildHeroCarousel` 自 #792 起是死代码，现役置顶卡（继续观看
  行首卡）本就接合集菜单，用户找不到的实际断点是上面三条。库页页头缺「全部刮削」
  按钮（`showVideoScrapeAllDialog` 全仓无调用者）属 TODO-2547 首页反馈批范围
  （用户自做首页），本轮不动。
