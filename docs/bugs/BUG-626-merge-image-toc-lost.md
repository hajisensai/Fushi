## BUG-626 · 图片合并后章节列表消失
- **报告**：2026-07-08（用户：）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart:1464-1487`（旧 `_flattenTocToTtu`，随 TODO-1128 引入）。
- **[x] ① 已修复** — 提交 本提交（分支 todo1333-merge-image-toc，commit 见 `git log --grep TODO-1333`）
- **[x] ② 已加自动化测试** — `hibiki/test/reader/merged_image_toc_visible_test.dart`（行为单测 + 源码扫描守卫），提交 本提交（分支 todo1333-merge-image-toc，commit 见 `git log --grep TODO-1333`）
- **备注**：

### 根因
开启「图片合并」（TODO-1128 merge-image / `ttu_merge_image_pages`）后，章节目录（TOC）压平函数
`_flattenTocToTtu` 会把「被吸收进后续文本章的 0 字符单图片章」（`EpubSpreadMap.isAbsorbedImageChapter`）
从目录里过滤掉：

```dart
final bool absorbed =
    index >= 0 && (_spreadMap?.isAbsorbedImageChapter(index) ?? false);
if (index >= 0 && !absorbed) { result.add(...); }
```

合并的吸收算法（`epub_spread_map.dart _mergeImageEntries`）把**整段前导单图片 run** 折进紧跟的
第一个文本章。当一本书的**目录项全部/大量指向会被吸收的图片页**——典型如一长串插图/图片页后面跟
一个尾部文本章（奥付/后记），该文本章会把前面**整段图片 run 全部吸收**——压平结果里这些目录项被逐条
隐藏，`_buildTtuToc` 返回空表，且没有「过滤后为空」的兜底 → **整个章节列表消失**。

隐藏的理由（TODO-1128 原注释）是「被吸收章没有自己的虚拟页，点目录会跳到不存在的页」。但 TODO-1128
去重修复（commit `7a2a85a95`）已给所有裸导航入口加了 `navigation.part.dart _resolveNavChapter`——包括
目录点击（`onJumpSection` → `_navigateToChapter(manual: true)` → `_resolveNavChapter`）——被吸收章跳转会被
重定向到宿主文本章章首（那张图内联在宿主正文顶部）。隐藏的前提因此不再成立，隐藏既冗余又有害。

### 修复
- 把目录压平抽成纯函数 `hibiki/lib/src/reader/ttu_toc_flatten.dart` `flattenTtuTocEntries`，**保留所有解析到
  的章、不再按 `isAbsorbedImageChapter` 隐藏**；被吸收章的目录跳转交给导航层重定向。这消除了 TOC 路径对
  `_spreadMap` 的耦合（好品味：删掉特例分支）。
- `chrome.part.dart _buildTtuToc` 改为 `return flattenTtuTocEntries(toc, _tocHrefToChapterIndex);`，删除私有
  `_flattenTocToTtu`。
- 空 toc 兜底（`t.auto_chapter` 逐章生成）不变；非合并书无被吸收章，行为不变。向后兼容：不破坏图片合并本身
  （宿主仍内联注入图），不破坏普通书目录。

### 测试
`hibiki/test/reader/merged_image_toc_visible_test.dart`：
- 行为单测：压平顺序/嵌套子项父标签/无法解析 href 跳过不误删兄弟；**重点用例**——3 张图片页 + 1 尾部文本章，
  `EpubSpreadMap.build(mergeImagePages: true)` 证明 3 张图片章确被吸收（`isAbsorbedImageChapter == true`），
  而其目录压平后仍为非空、保留全部 3 项（复现并锁死 TODO-1333）。
- 源码扫描守卫：`_buildTtuToc` 必须委托 `flattenTtuTocEntries`、旧 `_flattenTocToTtu` 必须删除、TOC 压平路径
  不得再按 `isAbsorbedImageChapter` 隐藏目录项。
