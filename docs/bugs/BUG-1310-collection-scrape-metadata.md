## BUG-1310 · 合集刮削只落封面：作品资料无宿主、合集名不回写
- **曾用号**：本条一度取到 BUG-1302，因并发 PR #624 抢注（它自己从 1299/1300/1301 改号过来）而改为 1305。
- **报告**：2026-08-01（用户：「还少了数据，你看看正经怎么做的」「顺带发现、未修你也修掉」）
- **真实性**：✅ 真 bug — 根因是**数据模型缺一个宿主**，不是展示层忘了画。

  刮削资料此前只有 `video_scrape_meta` 一张表可落，它主键 `bookUid`、外键指向
  `VideoBooks` —— 承载的是**单集**资料。而简介 / 评分 / 放送日期 / 标签本质属于
  「一部作品」；在统一合集模型里，「一部作品」就是**合集**，不是它的第 7 集。

  合集没有元数据宿主，于是合集刮削分支（`cover_match_dialog.dart:341` 修复前）
  只做了一件事：`downloadCollectionCover()` 下一张海报 → 写 `cover_path`。资料
  **从未被请求**，合集名**从未回写**（详情页标题一直是文件夹名
  `Tensei Oujo ... v2 播放列表`）。

  连带的第二处浪费：TMDB 的 `backdrop_path` / `overview` / `vote_count`
  **就在已有的 `/search/multi` 响应里**（`tmdb_client.dart` 修复前整条丢弃）。
  TMDB 没有接进本流水线的详情端点，搜索响应就是它资料的唯一来源 —— 不接住就永久
  丢失。横版 backdrop 的缺失正是 [BUG-1298](BUG-1298-collection-hero-portrait-cover.md)
  「hero 只能拿 2:3 海报硬撑」的上游原因。

- **[x] ① 已修复** —
  - **数据层**（schema v63 → v64）：新表 `collection_scrape_meta`
    （`packages/hibiki_core/lib/src/database/tables.dart`），主键 `collectionId`、
    FK cascade，字段对齐 `video_scrape_meta` 并**多一列 `backdrop_path`**（横版背景
    本地路径 = BUG-1298 的数据层根治）。迁移为纯新增表，不动任何既有表/列：旧库升级
    后本表为空 = 全部合集未刮削，详情页回落旧形态，逐像素不变。
  - **契约层**：`ScrapeCandidate` 增 `backdropUrl` / `summary` / `rating` /
    `ratingCount`；新增 `CollectionScrapeResult`（封面 + 横版背景 + 条目资料）。
  - **TMDB**：读满 `backdrop_path`（`original` 档）/ `overview` / `vote_average` /
    `vote_count`；无背景图不使候选作废（冷门条目常无背景，海报才是必需品）。
  - **刮削层**：`CoverScraperService.applyCandidateToCollection()` 取代只下海报的
    `downloadCollectionCover`。失败分三级：海报失败→抛；**背景失败→咽掉留 null**
    （锦上添花不该拖垮已成功的封面+资料）；详情端点失败→由候选降级拼一份，保证
    「刮过就有行」。仍**只写合集自己**，成员一个不碰（守住 BUG-1211）。
  - **落库层**：`collection_scrape_apply.dart` 的 `applyCollectionScrape()` —— 封面列 /
    资料行 / 合集名三处写入包在**一个事务**里同成同败（半截状态会让「已刮过」的判据
    与实际不符，下次进页面又当没刮过）。
  - **合集名回写 —— 改名前必须弹确认**（复议后的最终口径，落地时修正了首版实现）：
    首版按「手动入口即明确表达」直接回写，用户否决。理由成立：菜单/弹窗一字未提改名、
    改完无法撤销，而 `renameMediaCollection` 还会给旧 (name,type) 写合集级墓碑，同步
    出去会**删掉其他设备上的旧名副本**；系统又分不出当前名字是文件夹名还是用户亲手
    起的。故改为：`applyCollectionScrape` 的名字**只认 `confirmedTitle` 这个必填参数**
    （`required String?`，没有默认值，将来多一个调用点也会被编译器逼着表态）；
    `null` = 只写封面 + 资料行，合集名一字不动、**也不产生任何旧名墓碑**。UI 侧在
    `cover_match_dialog.dart` 的 `_use()` 里、落库之前弹
    `CollectionRenameConfirmDialog`，两行明示「当前名称 → 新名称」，默认动作是保留
    （点弹窗外/返回键都等于拒绝）。
    判据是纯函数 `proposedCollectionRename()`（同名 / 空正名不问），**刻意不做任何
    「名字看着像自动生成就直接改」的启发式** —— 系统既然分不出来，确认弹窗就是唯一
    防线，任何猜测都会把静默覆盖放回来。自动刮削 `VideoScrapeAutoService` 全程不碰
    合集，本就没有后台改名这条路。原始条目名独立存在 `collection_scrape_meta.title`，
    用户拒绝改名或事后手改合集名都不篡改「刮到的是什么」。
  - **展示层**：hero 改 Jellyfin 式 —— 有 backdrop 时用它作背景（**正确槽向**）+ 左侧
    独立 2:3 海报卡；无 backdrop（Bangumi / 离线库的常态）回落 `LandscapeCoverImage`
    且不再另放海报卡（同图不在同屏出现两次）。文字区补：原名、年份 · 全 N 话 ·
    ★评分 · N 人评分 · 已看完 x/N、**作品标签 chips**、简介（3 行截断）。
    资料缺失逐项跳过，不占位、不写「未知」。
  - 顺带修一处真缺陷：详情页此前只认**进页快照** `widget.collection`，刮削改写的
    名字与封面不会生效；改为以 DB 行为真相源（`_collectionRow`）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/database/collection_scrape_meta_test.dart`（12 例）：全字段往返（含
    backdrop）、**确认后才改名**、**未确认 → 名字一字不动且墓碑表一条都不多**（契约 ①，
    直接查 `collection_member_tombstones`，因为改名的破坏面在同步而不在本地）、
    **自动刮削源码零合集写入调用**（契约 ②，源码扫描守卫）、`proposedCollectionRename`
    三态、空正名保护、原始条目名独立、重刮覆盖、**FK cascade**、未刮过返回 null、
    JSON 列损坏降级。
  - `hibiki/test/database/migration_test.dart`：新增 fresh v64 建表 + **真实 v63→v64
    迁移**（既有合集行一列不改、新表可读写、user_version 正确）。
  - `hibiki/test/pages/collection_hero_scrape_meta_test.dart`（6 例）：元数据渲染、
    确认改名后标题用正名、**未确认改名时资料照常显示但标题仍是原合集名**、
    未刮削回落旧形态无空占位、有/无 backdrop 两条背景路径互斥。
  - `hibiki/test/media/video/scraper/tmdb_client_test.dart`：富字段映射 + 缺失为 null。

  **变异实测**（4 轮，全部按预期红/绿）：① 反转名字回写条件 → 3 例红；
  ② `_heroBackdrop` 恒 null → 仅「有 backdrop」红；③ TMDB 丢弃 `backdrop_path`
  → TMDB 富字段红；④ `_heroCover` 改回读进页快照 → 两条背景路径红。

  测试过程另抓到一处**测试自身**的假绿风险：`NativeDatabase.memory()` 默认
  **关闭外键**（生产在 `applyPragmas` 里开），不显式开的话 cascade 用例会「通过得
  毫无意义」。已在建库处显式 `PRAGMA foreign_keys = ON` 并复现红→绿。

- **备注**：本条与 [BUG-1298](BUG-1298-collection-hero-portrait-cover.md) 是同一问题的
  两层 —— 1298 是渲染层止血（宽槽拿到竖图时不被裁烂），本条是数据层根治（让宽槽
  一开始就有横图可拿）。1298 的 `LandscapeCoverImage` 并未因此作废：Bangumi 与离线库
  永远只有竖版海报，那条回落是它们的常态路径。
