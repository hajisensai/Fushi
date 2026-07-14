## BUG-804 · 书架继续阅读hero排除有声书永不更新
- **报告**：2026-07-14（用户：「书架的继续阅读一直不更新」；追问确认「刚读的那本是有声书/带字幕同步的书」）
- **真实性**：✅ 真 bug。根因链（BUG-777 修的是「读 importedAt 序、写 updatedAt」字段错位，已入 develop；本 bug 是另一条独立缺陷——候选集把有声书整类排除）：
  - `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:924-929` — `epubBooks` = `books` 里剔除「bookKey ∈ srtBookKeys」的书。有声书 = EPUB 正文行 + SRT 字幕行同 bookKey，故被剔出 `epubBooks`（本意只为主网格卡去重：有声书渲染成单张 SRT 卡，别再画一张 EPUB 卡）。
  - 同页 `:1125`（改前）— 继续阅读 hero + 概览统计 `_buildShelfOverviewSection(epubBooks, srtBooks)` 只吃 srt 过滤后的 `epubBooks`；`:717/:727`（改前）hero 候选 `inProgress` 只遍历它。于是有声书虽有真实 EPUB 进度（`position/duration`，来自 `hibikiBooksProvider`）、也有 `lastReadAt`（`reader_positions.updatedAt`，EPUB/SRT 同走 bookKey，BUG-723 已确认同源），却永远进不了 hero 候选——读多少遍有声书，「继续阅读」都不会变成它，表现为「一直不更新」。
  - `mostRecentlyReadCandidate`（`shelf_sort.dart:127-141`）在候选全 miss（`?? 0`）时退化返回列表首位（importedAt 倒序第一本），进一步坐实「冻在同一本」的观感。
  - 数据边界：纯字幕、无 EPUB 正文的书（无 `books` 行 → 无 `position/duration`）本就无进度维度，不进候选，属诚实边界，非本 bug。
- **[x] ① 已修复** — hero/概览统计改吃**未过滤的全量 EPUB-backed `books`**（含有声书），主网格卡渲染仍用过滤后的 `epubBooks`（卡片零变化，不重复渲染）。`_buildShelfOverviewSection(progressBooks, libraryTotal)`：`progressBooks=books`、`libraryTotal=epubBooks.length+srtBooks.length`（有声书作单张 SRT 卡只计一次）。在读/读完/候选分类抽成纯函数 `tallyShelfProgress`（`shelf_sort.dart`）。提交 82fa99682。
- **[x] ② 已加自动化测试** — `hibiki/test/media/shelf_sort_test.dart` 新增 `tallyShelfProgress` 组：分类正确性 + **复现场景「全量列表里最近读的有声书当选 hero」** + 空候选；`hibiki/test/pages/unified_collections_architecture_guard_test.dart` 新增 BUG-804 源码守卫：概览 section 调用点必须传未过滤的 `books`、正则禁 `_buildShelfOverviewSection(epubBooks`、分类必走 `tallyShelfProgress`。提交 82fa99682。
- **备注**：
  1. 与 BUG-777 是两条独立缺陷，勿混：777 已修 hero 在**纯 EPUB 内**按最近阅读选书；804 修 hero **候选集**把有声书整类漏掉。两者叠加前，有声书用户「继续阅读」双重失灵。
  2. 真机复测：读一本有声书（翻页/听书推进进度）→ 返回书架 → 「继续阅读」应更新成这本、显示其已读 %；再对照读一本纯 EPUB 仍正常。
  3. 纯字幕无正文的有声书（若存在）无 EPUB 进度维度，仍不进候选，属边界；用户所报「带字幕同步的书」是文本+音频型，有正文行，本修复覆盖。
