# PDF 阅读器 + 文本层查词 —— 实现计划

> 状态：**Phase 0-5 全部已实现**（Phase 0 已落 develop `e8eaca236`；Phase 1-5 在 PR #352，
> 分支 `worktree-pdf-reader`）。`flutter analyze`（含 test）干净，34 项测试绿。
> **仅 Windows 静态 + 单测验证；真机与 Android/iOS/macOS/Linux 待验。**
>
> 与原计划的偏差（实现时按真实代码调整）：
> - Phase 2 未手写命中测试：pdfrx 自带文本选择 + `onGeneralTap` 直接给文档坐标，
>   命中用其公开的 `charRects.containsPoint` / `distanceSquaredTo`，并用 pdfrx 原生选区
>   做命中词高亮（零手绘）。
> - 分句复用既有 `extractSentenceAt`（未新写工具）；PDF 换行用**等长替换**规避误分句。
> - Phase 5 的**竖排重排未做**：无真实竖排样本可验证，不做投机性几何重排（见「主要风险 2」），
>   如实留作已知限制。
> - Phase 5 额外做了书签（复用 `Bookmarks` 表）与页码指示器。

## 目标

在 Hibiki 里新增一种「PDF 书」：真渲染 PDF 页面，点选日语文字→查词→（复用现有）弹词典/制卡/朗读，
阅读进度按页码保存。首个验收样本：`prince.pdf`（文本 PDF、内嵌字体、无图、横排）。

不在本期范围：扫描图 PDF 的 OCR（无文本层的 PDF 判定为「无法查词」并提示）。

## 核心判断（Linus 式）

- **值得做**：用户明确要；且 Hibiki 的查词/制卡/书架/进度基础设施几乎全可复用，PDF 只是「第二种书身份」。
- **关键数据结构**：`bookKey` 是全系统书身份轴，`ReaderPositions.sectionIndex` 泛化成「页码」即承接 PDF 进度，
  `computeBookProgress` 在「全书字数为 0」时已回退到 `sectionIndex/chapterCount` 章级比例——**进度模型几乎零改**。
- **消除特殊情况**：PDF 作为 `EpubBooks` 表的一行（加 `format` 判别列），复用 `ReaderPositions`/`Bookmarks`/
  书架 provider/删除事务/墓碑，避免另建平行表打断 `Bookmarks` 外键与整套管线。
- **查词本质同构**：pdfrx 给「屏幕点→字符索引→子串」，`AppModel.searchDictionary` 给「子串→最长日语词」，
  两段拼起来就是点选查词，**不需要 PDF 侧做词切分**（与 EPUB 划词等价）。

## 选型

- **渲染库：pdfrx**（`espresso3389/pdfrx`，MIT；底层 PDFium BSD-3）。唯一同时满足
  「五平台 + 现成 Flutter widget + 暴露**字符级文本坐标**(`loadStructuredText()` 的 `charRects`) + 可编程选区」。
  - Android/Linux/Windows：Dart native assets（构建期链接 PDFium）。
  - iOS/macOS：CocoaPods/SwiftPM 链接 PDFium XCFramework。
- 淘汰：pdfx（仅位图无文本层）、flutter_pdfview（无文本层）、syncfusion（商业许可 + 选区 API 弱）。

## 集成锚点（file:line）

- 查词入口（复用零改）：`hibiki/lib/src/pages/base_source_page.dart:211`
  `searchDictionaryResult({searchTerm, selectionRect, ...})` → `AppModel.searchDictionary`
  (`hibiki/lib/src/models/app_model.dart:3233`) → 弹窗栈/朗读/加载更多。PDF 页 tap 后组装
  `searchTerm`+`selectionRect` 调它即可。
- 媒体源范本：`hibiki/lib/src/media/sources/reader_hibiki_source.dart`（照抄写 `ReaderPdfSource`）；
  抽象：`media_source.dart` / `media_type.dart` / `source_types/reader_media_source.dart` /
  `types/reader_media_type.dart`。PDF 归到**同一个 `ReaderMediaType`**（同一书 tab / 书架）作并列 source。
- 导入：`hibiki/lib/src/media/audiobook/book_import_dialog.dart` 扩展名白名单加 `pdf` + `_importPdf` 分支；
  平行写一个轻量 PDF importer（探测页数、抽首页缩略图当封面、落库），不复用 EPUB 解压。
- 数据：`packages/hibiki_core/lib/src/database/tables.dart`（`EpubBooks:284` / `ReaderPositions:104` /
  `Bookmarks:118`）。加 schema v51：`EpubBooks` 增 `TextColumn format`（`withDefault('epub')`，老行零破坏）。
  PDF 行 `format='pdf'`、`chapterCount`=页数、进度 `sectionIndex:=pageIndex`。

## 主要风险

1. **【高】pdfrx native-assets 五平台构建**（Android/Linux/Windows native assets；iOS/mac CocoaPods XCFramework）。
   必须 **Phase 0 先在五平台各出一次包验证**，尤其远程 Mac（cocoapods 1.12.1 钉版）与 Windows（与现有
   CMake 下载/代理并存，走 `127.0.0.1:34151`）。**这是能否落地的决定性前提。**
2. **【中】竖排日语文本抽取顺序**：PDFium 对 tategaki 字符顺序可能非视觉序，句子提取（制卡）需按 charRects
   几何重排；横排（prince.pdf）无此问题。
3. **【中】EPUB 专属路径门控**：复用 EpubBooks 方案下，`epub_parser`/spread/WebView 拦截/BookCustomCss 必须按
   `format` 早退，漏一处会让 PDF 行走进 EPUB 解压逻辑崩溃 → 加源码扫描守卫测试。
4. **【低】扫描图 PDF 无文本层**：按 `fragments` 为空判定并禁用查词提示，不做 OCR。

## 阶段拆分

- **Phase 0（spike，最高优先）**：加 pdfrx 依赖，`prince.pdf` 在 Android + Windows + 一台 Apple 上渲染 +
  native-assets 五平台构建全绿。**先打通构建再谈功能。**
- **Phase 1**：`ReaderPdfSource` + `format` 列（schema v51）+ PDF importer（页数/封面/落库）+ 书架出书 + 打开渲染。
- **Phase 2**：点选查词 tap→`globalToDocument`→page→charIndex→`fullText.substring`→`searchDictionaryResult`；
  `charRects`→`selectionRect` 锚点 + 选区高亮。
- **Phase 3**：页码进度写 `ReaderPositions.sectionIndex` + resume + 书架百分比（复用 `computeBookProgress`）。
- **Phase 4**：制卡（`fullText` 标点分句 + 页位图裁剪当图 + 接 creator/mining）。
- **Phase 5**：打磨（Bookmarks 复用、TOC 用 pdfrx outline、竖排处理、阅读设置）。

## 待确认点（给用户）

1. Phase 0 是否先做（构建 spike）——建议**是**，风险 1 决定成败，先花小代价验证五平台可编译再投功能。
2. 竖排 PDF 支持优先级：先只保证横排（prince.pdf）查词，竖排排序留 Phase 5？（建议是）
3. 是否本期就要制卡（Phase 4），还是先查词+阅读（Phase 0-3）验收后再说？
