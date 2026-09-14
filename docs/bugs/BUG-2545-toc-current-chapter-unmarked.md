## BUG-2545 · 阅读器导航「章节列表」不标当前章节
- **报告**：2026-09-15（用户：「没显示当前章节」，附 Android 阅读器「导航」抽屉截图：
  「安達としまむらSS」9 条目录 `表紙 / 目次 / 一章…五章 / あとがき / 奥付`，页脚进度
  21.7%，列表里**一条勾都没有**，且列表停在首行「表紙」——「打开即滚到当前章」也没发生）
- **真实性**：✅ 真 bug。根因在
  `fushi/lib/src/media/audiobook/reader_quick_settings_sheet.dart:1294`（修复前）
  `_buildCurrentTocSection` 的当前章判据是**精确相等**：
  ```dart
  final int? currentIdx = widget.readerProgress?.$1;  // = _currentChapter，spine 章号
  …
  selected: !toc[i].isHeader && currentIdx == toc[i].index,
  ```
  而 `TtuTocEntry.index` 是 `flattenTtuTocEntries` 经 `EpubBook.chapterIndexForHref`
  把 nav href 解析出的 spine 下标，**目录是 spine 的稀疏映射**：同一章横跨多个 xhtml 时
  只有头一个进目录，章间插图页 / 扉页 / 后记页根本不在目录里。本机真书取证（读 OPF spine
  + NCX）：
  - `無職転生 4 (MFブックス)`：spine **35** 项，NCX 只指向 `part0000/0005/0008/0012/0014/
    0016/0018/0020/0022/0024/0028/0032` **12** 个 spine 位置 → 剩下 **23** 个位置上读书时
    `currentIdx` 与任何 `toc[i].index` 都不相等；
  - `無職転生 21`：spine 16 项，NCX 指向 5 个 xhtml（其余靠 `#anchor`）。

  于是**绝大多数阅读位置整张列表一行都不标**；同一条判据还喂着滚动锚点
  `_currentTocRowKey`（`toc.indexWhere(... e.index == currentIdx)` 返回 -1 → GlobalKey
  挂不上任何行），`_buildNavigationSideSheet` 的 `ensureVisible` 因此静默 no-op ——
  正是截图里「列表停在表紙」。同文件外两处**已经**是 floor 口径，只有这张列表是例外：
  `ReaderFushiPage._currentChapterLabelFor`（页脚章名 / 收藏落库的 `chapterLabel`）与
  `reader_audiobook_panel.dart:486` 有声书「章节」tab 的当前章标注。
- **[x] ① 已修复** — `f140a7b1de`：新增纯函数
  `resolveCurrentTocChapter`（`fushi/lib/src/reader/ttu_toc_flatten.dart`）——取**最大的
  不晚于当前位置的目录项 index**（floor），目录为空 / 当前位置早于首条目录项 / 无位置时返
  null（不标任何行）；`_buildCurrentTocSection` 只把那一行 `final int? currentIdx = …`
  换成它，下游 `selected` / `autoExpanded` / `currentRow` 三处判据一字未动。
  精确命中时 floor == 当前 spine 章号，**与修复前逐字同解**（含「一个 xhtml 装整卷、目录靠
  `#anchor` 分节」那类同 index 多行：照旧全部标当前、锚点取第一条，BUG-2384 的 GlobalKey
  契约不受影响）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_toc_current_chapter_bug2545_test.dart`：
  6 条纯函数用例（稀疏目录章内任意 spine 位置、精确命中同解、首条之前 / 无位置 → null、
  `index < 0` 标题行不参与、目录项顺序错乱取最大而非末条、同 index 锚点多行共解）+ 1 条
  真面板 widget 用例（`ReaderQuickSettingsSheet` + `sideSheetNavigation`，稀疏目录
  `[0,1,2,6,10,14]` 读在 spine 4 → 恰好一个 `Icons.check`，且落在「一章」那一行）。
  变异实测：把判据改回 `widget.readerProgress?.$1` 后该 widget 用例红（`+6 -1`），
  改回来 7 条全绿。
- **备注**：同一判据的另一面——**目录项之前的位置**（如封面之前的 spine 0 不在目录里）
  依旧不标任何行，这是有意的：没有任何目录项能代表那个位置。
