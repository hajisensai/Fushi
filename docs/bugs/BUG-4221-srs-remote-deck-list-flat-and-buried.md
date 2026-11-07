## BUG-4221 · srs-remote-deck-list-flat-and-buried
- **报告**：2026-11-07（用户：群反馈「复习已配对设备卡组一点进去就发现 bug 了，并没有使用树状结构，并且藏的有点深」）
- **真实性**：✅ 真 bug。远程牌组列表是另写的一份平铺列表：`fushi/lib/src/pages/implementations/srs/srs_remote_review_page.dart` 的 `_SrsRemoteDeckListPageState._buildBody` 只按 `deck.depth` 加左内边距，没有父子折叠、层级竖线、徽章，与本机牌组树（`srs_deck_list_page.dart` `_DeckList` / `_DeckRow`）两套实现分叉；入口是同步按钮「⋯」菜单第 4 项、再经「选主机 → 牌组列表」两层页面。
- **[x] ① 已修复** — 按用户拍板的方案 A 重做入口：复习首页本机牌组下面加「已配对设备」分区（`srs_deck_home_paired.dart`），每台主机一组，展开就是它的牌组树，直接复用本机的 `_DeckRow`（`remote: true` 时菜单只留自定义学习 / 浏览 / 牌组设置），树的折叠判定抽成本机与远程共用的 `_srsDeckHiddenByCollapse`；删掉旧的两层页面与同步菜单入口。主机与连接状态由牌组页持有（`_SrsPairedHosts`），不随懒列表项重建而重连。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_remote_review_test.dart`「复习首页「已配对设备」…」：展开后子牌组带层级竖线、父牌组可收起 / 展开，复习 / 浏览 / 添加笔记 / 牌组设置读写主机库、不碰本机库；另一条钉住没有可用主机时不出分区。
- **备注**：主机的计数不并进本机「今日计划」（用户同日拍板不要「另有 N 张」那行）。
