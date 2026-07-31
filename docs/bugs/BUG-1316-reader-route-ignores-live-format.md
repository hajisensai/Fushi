## BUG-1316 · 跳回原文按写死的 EPUB 源打开：漫画/PDF 书用错阅读器
- **报告**：2026-08-01（用户：PR#502 阶段二前置审查项②）
- **真实性**：✅ 真 bug，**且不是转化引入的**——原生漫画 / PDF 书**今天**就已经踩到。

  阅读器路由的唯一真相源是 `EpubBooks.format`，它只在 `_bookToMediaItem`
  （`hibiki/lib/src/media/sources/reader_hibiki_source.dart:506`）被翻译成
  `MediaItem.mediaSourceIdentifier`（`reader_ttu` / `reader_pdf` / `reader_manga`）。
  三种书共用 `mediaIdentifier = hoshi://book/<bookKey>`，路由**只认**
  `mediaSourceIdentifier`。凡是绕过这处翻译、手上只有 `bookKey` 就自己造 `MediaItem`
  的入口，都会把书当成 EPUB 打开。

  根因两处（均为写死 EPUB 源、从不查 format）：

  1. **收藏句 / 制卡句「跳回原文」** —
     `hibiki/lib/src/pages/implementations/collections_page.dart:92-105`
     （`buildCollectionReaderMediaItem` 写死
     `mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey`）
     + `collections_page.dart:465-470`（`openMedia(mediaSource:
     ReaderHibikiSource.instance)` 再写死一次）。该页从不读 `EpubBooks`，
     `_load()` 只装 SRT 书标题。
     → 在漫画里制的卡，从收藏/制卡列表点「跳回原文」**永远**打开 EPUB 阅读器；
     而漫画行的 `epubPath` 是 `manga.json`、`chaptersJson` 是 `'[]'`，EPUB 阅读器
     在解析路径直接失败。PDF 同理。
  2. **首页「正在听书」迷你条「回到书」** —
     `hibiki/lib/src/models/app_model.dart:4661-4667`：第 4665 行已经通过
     `mediaItemForBookKey` 拿到 format 正确的 `MediaItem`，却把
     `mediaSource: ReaderHibikiSource.instance` 写死传给 `openMedia`。

  「书 ↔ 漫画转化」（PR#502 落库层 `updateEpubBookFormat`，
  `packages/hibiki_core/lib/src/database/database.dart:4797`）不会新增这个缺陷，
  只会把它从「导入即错」放大成「转化后突然错」——因为它就地改 `format` 而
  `bookKey` / `mediaIdentifier` 全不变。

- **[x] ① 已修复** — 把「format → 阅读器源键」收敛成唯一派生点
  `ReaderHibikiSource.mediaSourceKeyFor(BookFormat)`
  （`hibiki/lib/src/media/sources/reader_hibiki_source.dart`），书架列书与两个
  「跳回原文」入口共用它：
  - `_bookToMediaItem` 改调 `mediaSourceKeyFor(format)`（原地内联的三元删除）；
  - `buildCollectionReaderMediaItem` 新增 **required** `BookFormat format` 参数
    （必填、不给默认值——默认成 EPUB 就是把缺陷改写成静默回退），`_openBook`
    改为 async、现查 `getEpubBook(bookKey)` 得到**当前** format，并用
    `mediaItem.getMediaSource(appModel:)` 反查源，不再写死；
  - `openBackgroundListeningBook` 改用 `item.getMediaSource(appModel: this)`。

- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/sources/collections_open_book_test.dart`：三种 format
    各自的源键、`mediaIdentifier` 与 format 无关、且与 `mediaSourceKeyFor`
    逐一相等（钉住「两条入口不得各写各的」）；`mediaSourceKeyFor` 三态互异。
  - `hibiki/test/media/manga_routing_guard_test.dart` /
    `hibiki/test/media/reader_pdf_routing_guard_test.dart`：原「源码里必须有那串
    三元」的语料锚点升级成**直接调公开派生函数**的行为断言（语料锚点会被等价
    改写绕过），另加一条扫描守卫钉住 `_bookToMediaItem` 必须走
    `mediaSourceKeyFor(format)`、不得再内联。

- **备注**：同源但**未在本条修复**的两处，各自独立记档（BUG-1317 / BUG-1318）：
  - override 书名 / 自定义封面的偏好键把源键烧进去了
    （`hibiki/lib/src/media/media_source.dart:440,449`），而读取侧
    `reader_hibiki_source.dart` 的 `_overrideTitleForIdentifier` 恒用 `reader_ttu`
    合成键，与编辑弹窗按真实源写入的键不一致 → 漫画/PDF 书改名后首页/统计/通知
    显示旧名。
  - `media_items.unique_key = '<源键>/<mediaIdentifier>'`
    （`hibiki/lib/src/media/media_item.dart:49`）把源键烧进历史身份；书今天不落该表
    （三个书源 `implementsHistory: false`），阶段二若改为落表则转化必然分裂成两条。
