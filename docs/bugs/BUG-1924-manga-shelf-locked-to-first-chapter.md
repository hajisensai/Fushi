## BUG-1924 · 漫画加入书架后只能看第一章：书架没有作品页、阅读器不换章
- **报告**：2026-08-29（用户：「漫画添加到书架以后只能看第一章了，需要设计一下漫画的首页」）
- **真实性**：✅ 真 bug。不是单点缺陷，是**书架侧根本没有作品页**这一层缺失的直接后果。
- **[x] ① 已修复** — `ace0c0290d`（schema v89）/ `c5ed34b4f7`（实体 + 作品页）/ `94ed49ad65`（接线）/ `df2194177f`（Aidoku + 详情页合并）
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/online_manga_library_test.dart`
- **备注**：本条同时修掉三个连带缺陷（进度条量纲、换章丢进度、新章不出现），见下。

### 根因

`EpubBooks` 的一行**同时扮演「作品」和「当前那一章」两个角色**。用户看到的现象与我在
排查中挖出的三个连带缺陷，全部是这个二义性的直接后果。

**主症状：只能看第一章**，由三处叠加而成，缺一都不至于卡死：

1. 书架点开 = 直接钻进某一章。`manga_library_page.dart:47` 的书架就是
   `ReaderFushiHistoryPage(mangaOnly: true)`，卡片 onTap 走
   `AppModel.openMedia` → `MangaFushiSource.buildLaunchPage` → `MangaFushiPage`，
   中间**没有任何页面**。
2. 第一次开书就把「第一章」钉死。`mihon_library.dart:286` 的 `initialChapterIndex`
   在 `currentChapterIndex == null` 时返回 `chapters.length - 1`（源按新→旧排，
   末尾 = 最旧那话 = 第 1 话），随后 `manga_fushi_page.dart:1228` 立刻
   `selectChapter()` 把它写进 `sourceMetadata`。从此每次从书架开都是这一章。
3. 阅读器里没有任何换章入口。`manga_fushi_page.dart:1961` 的
   `_applyMangaTurnStep` 到最后一页是 `clamp` 后 `target == _currentSpread` 直接
   `return`——**死钳位**，既不翻章也没有任何提示。全文件 4225 行里 `chapter` 只出现在
   加载/缓存/身份校验，没有 next/prev。

章节列表其实**一直完整存在** `sourceMetadata.chapters[]` 里，只是没有任何界面展示它；
唯一的章节列表藏在 `MihonMangaDetailPage`（`mihon_source_browse_page.dart:361`），
而它的构造要求 `MihonSourceContext`——只能从 发现→来源→搜索→点封面 进，书架手上只有
`bookKey`，**够不着**。

**连带缺陷（同源，一并修掉）**：

- **书架进度条量纲错配**：`reader_fushi_source.dart:581-601` 对页码型书算
  `sectionIndex+1 ÷ chapterCount`。但在线条目里 `chapterCount` 写的是**章数**
  （`mihon_library.dart:185`），`sectionIndex` 存的是**当前章内页码**
  （`manga_fushi_page.dart:3405`）。于是「第 3 话第 8 页 ÷ 共 128 话」= 6%，
  翻页乱跳、换章反而回退。
- **换章即丢进度**：`ReaderPositions.bookUid` 是 `unique()`，一本书恒一行位置，
  表达不了「第 37 话读到第 8 页」。`mihon_library.dart:260-268` 的 `selectChapter`
  因此只能把它清零——上一章位置永久丢失，也无从知道哪些章读过。
- **新章永远不出现**：书架和阅读器都只读缓存的 `sourceMetadata`，从不调
  `getChapters`；唯一的刷新入口是「从源浏览页重新进详情页」。
- **Aidoku 完全进不了书架**：`aidoku/` 全目录零 `insertEpubBook`，章节列表只活在
  widget state 里、页面 pop 即丢，进度也不落库。根因是 `MihonLibraryEntry` 硬绑
  `MihonManga`/`MihonChapter`，Aidoku 的无类型 map 塞不进那个形状。

### 修复

按「先把数据结构做对，再谈 UI」的顺序：

1. **schema v89 新增 `manga_chapter_states`**（`packages/fushi_core/.../tables.dart`）。
   把「章」升成一等实体，身份 `(bookUid, chapterKey)`；`readAt != null` = 已读，
   `lastPage/lastFraction` 让换章不再丢进度。`chapterKey` 用源内稳定身份而不是
   index——源刷新后顺序会变。纯新增表，旧库升级后表为空 = 沿 v88 行为，零破坏。
2. **`OnlineMangaLibraryEntry` 取代 `MihonLibraryEntry`**：runtime + 归一化
   series/chapters + 保留运行时原生 `raw`（回灌 `getPages` 要用）。`tryParse` 同时
   吃 v1 `hibiki-mihon`，存量条目零改动继续可用。`bookKeyFor` 的 Mihon 分支
   **逐字节保持 v88 推导**（NUL 分隔、`mihon-` 前缀）——这串既是主键也是磁盘目录名。
3. **`OnlineMangaRuntimeAdapter`** 把 Mihon/Aidoku 收成一个契约，失败按
   `sourceDisabled / platformUnsupported / runtimeFailure` 分类。
4. **`MangaSeriesPage` 作品页**：只吃 `bookKey`，先离线渲染（首屏零网络调用）再后台
   刷新，失败只挂可重试提示条。书架、源浏览、Aidoku 三条入口共用同一个页面。
5. **阅读器补「章」这一维**：到头不再死钳位而是换章、章节列表按钮、每章进度挂在
   `_persistPosition` 这个唯一收口上。
6. **进度条改走章级**（在线条目），本地 mokuro 卷两个量纲一致，继续走页级。

关键取舍：作品页**刻意不走 `openMedia`**。那条路是媒体会话语义（沉浸模式 /
wakelock / audio handler），作品页是可浏览的库页面，当媒体会话打开会让它顶着隐藏的
系统 UI、亮着屏。真正的会话仍由作品页内部 `openMedia` 开阅读器时启动，与 v88 逐字相同。

`AppModel.onlineMangaLibraryService` 的 Aidoku 分支刻意不碰 `mihonManager`：平台矩阵
不重合（Mihon = Android/Windows/macOS，Aidoku = macOS/iOS），在 iOS 上取它会抛
`UnsupportedError`，把「打开这本书」变成崩溃。

### 测试

`fushi/test/media/manga/online_manga_library_test.dart`（取代 `mihon_library_test.dart`），
把这次最危险的几条不变式钉住：

- **`bookKey` 与 v88 公式逐字节一致** —— 测试里独立重算一遍 sha256，不调被测代码
  （两侧同源取值的比较恒真）。这条一旦破，全部存量在线漫画条目会变成主键与磁盘目录
  都对不上的孤儿。
- **v1 描述符仍可解析**，且 `raw` 原样保留。
- **选章不再清零 `reader_positions`** —— 行为变更，必须钉死。
- **刷新按 `chapterKey` 重定位当前章**（源插入新话后下标会漂移）。
- 无 `key` 的章节被丢弃，不会挤进同一个空 `chapterKey` 主键。
- `resumeChapterIndex` 四态；两个运行时的字段归一化（Aidoku 是复数 `scanlators`
  列表 + 蛇形 `chapter_number`，标题为空回退到话号）。

另外 40 处硬编码的 `schemaVersion` / `PRAGMA user_version` 断言 88→89，
`migration_v63` 的新表清单守卫登记 `manga_chapter_states`。

**未验证缺口**：Aidoku 侧只跑了单元测试与 `dart analyze`——它只在 macOS/iOS 可用，
本机是 Windows，入库→读章的端到端未在真机走过。
