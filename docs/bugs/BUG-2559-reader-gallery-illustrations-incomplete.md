## BUG-2559 · 阅读器插图画廊漏图且遮罩与书架不一致

- **报告**：2026-09-16（用户：书架上长按点开的插画齐全，但阅读器内的插图画廊不齐全，且高斯模糊效果和书架上的插画不一致）
- **真实性**：✅ 真 bug，两个症状同一个根因族——**两个插图表面各有一套枚举、各有一套遮罩判据、各写死一个模糊半径**。

  本机真书取证（`D:\hibiki-dev-data\app-documents\fushi_books`，直接跑 `EpubBook.images` 与磁盘枚举对比）：

  | 书 | 磁盘图片 | 画廊列出（修复前） |
  |---|---|---|
  | 新装版 タイム・リープ〈上〉 | 12 | **0** |
  | 無職転生 16 | 14 | **2** |
  | 無職転生 21 | 16 | **10**（漏 cover + kuchie×3 + allcover） |
  | 無職転生 4 | 16 | 15（漏封面） |
  | 漫画「3」 | 22 | 85（**同图重复 85 次**） |

  根因逐条：

  1. **漏图** — `packages/fushi_engine/lib/epub/epub_book.dart:283`（修复前）：`images` getter 只收 `<img src>`，注释自述 `SVG <image xlink:href> is intentionally NOT included yet (deferred)`。日文固定版式 EPUB 的封面与彩插（口絵）一律是 `<svg><image xlink:href>`，整类插图被丢掉；上表第一本书连一个 `<img>` 都没有，画廊全空。同时不收行内 `background-image`、不收 OPF `cover-image`。
  2. **重复** — 同一张图在书里出现 N 次就列 N 张卡（装饰分隔符在几十章里复用），而书架侧按磁盘文件天然唯一。
  3. **遮罩判据不同** — `fushi/lib/src/reader/reader_gallery_page.dart:251`（修复前）：画廊的「还没读到」只有 `ref.chapterIndex > widget.currentChapter`，章粒度；书架侧走 `IllustrationProgressIndex`（章号 + 章内归一偏移 + 封面恒已读）。当前章读到一半时，章内靠后的插图在画廊算「已读到」不遮、在书架算「还没读到」照遮——同一本书同一张图，两处一个糊一个不糊。
  4. **模糊半径写死** — `fushi/lib/src/reader/masked_illustration_cover.dart`（修复前）两处都用 `sigma: 16`，但卡片不一样大：书架 `maxCrossAxisExtent: 200` 方卡、画廊 `_kCardMaxExtent = 160` 的 0.72 竖卡。同一个**绝对**半径施在小 20% 的卡上就是更糊一档。真实像素对比（`kuchie-001.jpg` 按两侧真实卡尺寸渲染）能直接看出画廊那张细节更少。
  5. **reveal key 第四套归一** — 画廊用 `ImageRevealKey.normalize(ref.src)`，而该函数对相对路径分支**不做 percent-decode**；WebView JS 与书架磁盘路径都是 decode 过的。含 `%xx` 文件名的书，画廊揭开的图在正文/书架不同步。

- **[x] ① 已修复** — 收敛成「一份扫描 + 一份判据 + 一个与尺寸成比例的半径」：
  - `EpubBook.images` 重写为按 DOM 顺序单次遍历，收 `<img src>` / SVG `<image href|xlink:href>` / 行内 `background-image`，前置 OPF 封面（`kEpubCoverChapterIndex = -1`），按 reveal key 去重取首次出现，顺带算出章内 `normCharOffset`（与落库阅读位置同 0~10000 基准、同 `countStudyChars` 口径、跳 `<rt>/<rp>/<rtc>`）；越界引用（`../` 出书根）剔除，单章解析失败只跳该章。
  - `EpubImageRef` 新增 `revealKey`（decode 后的稳定 key，与 WebView / 书架 / Drift 同源）、`normCharOffset`、`jumpChapterIndex`（封面跳第 0 章）。
  - `IllustrationProgressIndex.build` 改为直接消费 `book.images`，删掉自己那套章节 DOM 扫描——两侧再也不可能漂移。
  - 画廊 `_unreadAhead` 改为章号 + 章内偏移，宿主 `_openGallery` 传 `currentNormCharOffset`；reveal key 改用 `ref.revealKey`。
  - `maskedIllustrationCover` 的模糊半径默认按卡片短边取比例（`kMaskedIllustrationSigmaFraction = 0.08`，即书架现有 200→16 的观感，不改任何人已习惯的强度，只把画廊对齐过来）；全屏查看器仍可钉死绝对 sigma（它另配更重的蒙层）。
  - 新增 i18n `reader_gallery_cover`（封面节头，避免写成「第 0 章」）。

  修复后真书复测：四本书画廊条目数 = 磁盘图片数，差集为空。

- **[x] ② 已加自动化测试**
  - `fushi/test/epub/epub_image_list_test.dart`：SVG 两种 href、行内背景图、同图只列一次且取最早位置、OPF 封面前置 + `jumpChapterIndex`、章内偏移落在阅读位置同一把尺上、振假名不撑偏偏移、越界引用剔除、单章不可读不毁整册。
  - `fushi/test/reader/masked_illustration_cover_test.dart`（新增）：模糊半径按短边取比例、两种真实卡尺寸下「半径 ÷ 短边」相等、显式 sigma 仍钉死、ClipRect 约束、墨水屏实心遮板分支。
  - `fushi/test/reader/reader_gallery_page_test.dart`：当前章内阅读位置前后的插图分别不锁 / 锁、偏移缺省退回章首语义、封面节头不写成「第 0 章」。
  - `fushi/test/pages/reader_gallery_guard_test.dart`：源码守卫钉住「两个表面共用 `EpubBook.images`」「进度索引不得再自己扫 DOM」「画廊判据带章内偏移且宿主真传了」「reveal key 走 `ref.revealKey`」。
  - 既有的 `illustration_progress_index_test.dart`（5 条）与 `illustrations_viewer_unread_blur_test.dart`（3 条）未改一行断言即通过——这是「换成消费同一份枚举后书架侧行为等价」的证据。
  - 定向套件 314 条通过（`test/epub/`、插图库四条、画廊、进度索引、reveal key、卷切换），`flutter analyze` 零问题。

- **备注**：相邻发现，**不在本次修复范围**——漫画「3」的 OPF/HTML 写 `OEBPS/Images/`，而 zip entry（解压后的磁盘目录）是全小写 `oebps/images/`，于是书架侧 key（磁盘真实大小写）与正文 / 画廊 key（markup 大小写）不同，同一张图的揭开状态两处不共享。这是书自身大小写不一致引发的独立机制（`EpubParser._findArchiveFile` 已为同一现象做过大小写回退），正确修法要动 `revealed_images` 的读写边界并兼容历史行，应另开一条。
