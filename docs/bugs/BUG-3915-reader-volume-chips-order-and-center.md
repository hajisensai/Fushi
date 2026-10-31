## BUG-3915 · 导航侧板目录页的卷 chip 行顺序错乱、当前卷不居中
- **报告**：2026-10-31（用户：「目录的第一个是 5，3 在最后面，而且没有默认居中」；书是《安達としまむら》系列合集，当前在第 3 卷）
- **真实性**：✅ 真 bug（两处）。沿真实代码路径：
  1. **顺序（根因在持久化的合集序，不在阅读器）**：卷 chip 的 `labels` 来自 `_tocVolumeSwitch()`（`fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart`）→ `ReaderVolumeContext.volumes` → `loadReaderVolumeContext`（`fushi/lib/src/reader/reader_collection_volumes.dart:80-97`）按合集成员 `sortIndex` 取序——与合集详情页同一份存储序，这一层本身没错。错的是存储序：手动「建系列 / 并入合集」按选择顺序尾插，归组时的卷序自愈 `BookSeriesGrouper._healSeriesOrder` 经 `BookSeriesOrder.orderOf` 判能否定序，旧判据要求**整张合集同一系列键**（修前 `packages/fushi_engine/lib/media/collections/book_series_grouper.dart:436`）——合集里混进一本「安達としまむらSS」这类番外（系列键 `安達としまむらss` ≠ `安達としまむら`）或外传，整张合集永远不排，乱序原样落在 `sortIndex` 里、进了阅读器（目录与图库两处卷 chip 行同错）。（用户库的具体成员未取证，以上是代码上能产生该现象的路径。）
  2. **不居中**：`_buildVolumeChips`（修前 `fushi/lib/src/media/audiobook/reader_quick_settings_sheet.dart:2038`）是懒构建的横向 `ListView.separated`，没有任何滚动定位逻辑；十几卷时当前卷落在视口外。
- **[x] ① 已修复** —
  - 顺序在持久化层修（`book_series_grouper.dart`）：`BookSeriesOrder.orderOf`（:440）改认「主系列 + 番外」——主系列 = 卷数最多的系列键（并列 = 认不出），≥2 卷、卷号不重复、至多一卷无卷号；其余成员的系列键必须以主系列键开头（SS / 外传 / 汉字卷号），混了别的系列或本机没有的书（透传成员）照旧不定序。排法 `_orderSeriesInPlace`（:491）：主系列各卷在**自己占的位置**里按卷号排，番外原位不动——番外该夹在哪卷后规则判不出，那是 AI 自动排序的活（AI 只在锚点之间放置、落盘不置 `orderUpdatedAt`），若规则把番外挪到固定位置，每次归组都会冲掉 AI 的放置、再触发一轮 AI，来回翻；槽位排法对 AI 结果是不动点、对自身幂等。`_healSeriesOrder`（:354）照旧只动 `orderUpdatedAt == 0` 的合集、写库走 `reorderCollectionItemsAutomatically`（不冒充手动序），在已有自愈的位置（每次书架加载 / 导入后的 `groupAll`）运行，存量库下次打开书架即自愈；同步合并 `loadBookSeriesRuleOrder` 用的是同一个 `orderOf`，本地与共享清单同一判据。归组补卷后的 `_sortMembers`（:383）改走同一条槽位规则（只排本系列卷、其余成员原位），不再把番外按「无卷号 = 第 0 卷」插到最前。
  - 撤掉 PR 原先在阅读器展示层按书名卷号重排的 `readerVolumeOrder`：那会让阅读器与合集详情页两处顺序不一致，并静默覆盖用户手动排过的顺序。阅读器卷 chip 行恢复为存储序。
  - 居中：卷 chip 行改成 `_ReaderVolumeChipRow`（整行一次建完的 `SingleChildScrollView` + `Row`），首帧布局后量当前卷 chip 的渲染对象，只对最近这层横向滚动视图 `ScrollPosition.ensureVisible(alignment: 0.5)`，一个面板会话只做一次，时长取 `fushiMotionDuration(FushiMotion.short)`（减弱动态效果直接落位）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/collections/book_series_grouper_test.dart`：主系列 + SS（用户实际加入顺序 5,8,7,6,4,3,2,1,SS）自愈成 1..8,SS、`orderUpdatedAt` 仍为 0、第二次归组不写库；外传夹在卷之间时只排主系列、AI 式放置（`reorderCollectionItemsAutomatically`）是不动点；手动排过的「主系列 + 番外」不动；别的系列 / 两系列并列 / 主系列两卷无卷号不动；`orderOf` 槽位语义与透传成员返回 null。原「混了外传不自愈」用例按新契约改写。
  - `fushi/test/reader/reader_collection_volumes_test.dart`：阅读器卷上下文原样等于 `getCollectionItems` 的存储序（无展示层重排）；同一乱序合集经 `BookSeriesGrouper.groupAll()` 自愈后阅读器显示 1,2,3,4,SS,5..8、`currentIndex` = 2。
  - `fushi/test/reader/reader_volume_switch_widgets_test.dart`：8 卷 chip 行在 400 / 1000 宽下当前卷 chip 中心落在视口中心（±1 px）、首 / 末卷贴边、居中只做一次。
- **验证**：改动只在合集卷序自愈、导航侧板卷 chip 行，不碰正文 WebView、分页 / 滚动 / VN 三种 view mode 的排版几何。未在真机 / 桌面实例人工看过 UI。
