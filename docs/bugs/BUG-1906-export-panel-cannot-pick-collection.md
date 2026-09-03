## BUG-1906 · 收藏夹导出面板挤在 bottom sheet、文案写死书籍、且没法按合集导出
- **报告**：2026-08-28（用户：「这里做的不好，换一下大弹窗，并且不是书籍。现在也没办法根据合集来导出」，附收藏夹导出面板截图）
- **真实性**：✅ 真 bug（三条，其中第三条是结构问题）。

### 根因

**① bottom sheet 被屏高上限卡死** —— `_openExportSheet` 是裸的
`showModalBottomSheet`，**没传 `isScrollControlled`**，被默认 9/16 屏高上限卡死；
sheet 内壳虽写了 `maxHeightFactor: 0.82`，那个值根本够不着。同一个文件里
`CollectionItemDialogFrame` / `CollectionDeleteDialog` 早就是 `FushiDialogFrame` 的
写法，只有导出/清空两个面板停在 sheet 上。

**② 文案写死「选择书籍」，列的却是视频剧集** —— 统一合集迁移后每一集是独立的
`VideoBooks` 行，收藏句的 `bookKey` 就是视频 `bookUid`，标题即 `... - S04E14`。

**③ 没法按合集导出（真正的结构问题）** —— 范围过滤按
`ExportSentence.bookTitle` 这个**显示名字符串**相等做：

```dart
return mapped.where((ExportSentence s) => s.bookTitle == bookTitle).toList();
```

而合集归属只能由**身份**反查（`media_collection_items.entry_key` → `collection_id`）
——显示名里根本没有这个信息。`ExportSentence` 在映射那一步就把 `bookKey` 丢了，
radio 的候选也只是 `List<String>`。仓库里**早就有** `getPrimaryCollectionIdByEntry()`
（单查询 GROUP BY MIN，专为避免 N+1 而写），导出链路一次都没调过。

顺带两个既有缺陷：同名/改名后重名的两个条目会塌成同一项；而且**制卡句段恒是 DB
全量**——用户选了一部作品，导出来的却是全库制卡句，这个不对称没有任何理由。

### 修复与测试

- **[x] ① 已修复**：
  - 范围的单位从「一个书名」改成「一组 `bookKey`」（新 `_ExportSourceOption`）：
    合集 = 它成员的 key 集合，单条目 = 一元集合，全部 = 空集合。合集归属走既有的
    `getPrimaryCollectionIdByEntry()`；它的键是 `'<mediaType>|<entryKey>'`，而收藏句
    只记 `source`（`book`/`video`/…）+ `bookKey`，两套词汇对不上——与其猜一个映射，
    不如拿 bookKey 去**试遍**四种 `MediaKind`（map 已在内存里，命中即得）。
  - `ExportSentence` / `ExportMinedSentence` 带上 `bookKey`；过滤改按身份。
  - **制卡句段也受同一范围约束**（原先恒全量）。
  - 面板换成 `FushiDialogFrame(maxWidth: 520, maxHeightFactor: 0.86)` 包
    `FushiModalSheetFrame`，走 `showAppDialog`。
  - 「选择书籍」→ 新 i18n `collection_export_pick_source`「选择来源」/
    `collection_export_all_sources`「全部来源」（旧的两个 key 已移除——它们的 17 语翻译
    说的就是「书籍」，留着反而是错的）。
  - radio 行从裸 `RadioListTile` 换成共享 `FushiListItem` + `Radio`（MD3 守卫扫的是
    几个字面 token，`RadioListTile<String?>` 中间夹了泛型参数所以字面上凑不出，
    是漏网不是豁免）。
  - 删掉因此变成死代码的 `_favoriteSentencesForExport()`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/collections_export_by_collection_test.dart`：
  真页面 + 真内存 DB + 焦点驱动开面板（禁 tap/坐标，与既有 `collections_export_test`
  同纪律）。两集属于同一合集、另有一本散书 → 断言面板里出现**合集名**、两条单集
  **不再单列**、散书仍单列、文案是「选择来源」；另一条断言面板是 `Dialog` 而不是
  `BottomSheet`。
  **变异实测**（2026-08-28）：把合集反查钉成恒 null（= 回到只能一集一集导）→ 第一条
  转红。还原后本文件 2 项 + 收藏夹/导出器/MD3/i18n 共 169 项全绿。

### 备注

- 「清空」面板（`_ClearSheet`）仍是 bottom sheet：用户只点名了导出面板，未一并改。
- 收藏词（`_exportAllWords`）仍不受来源约束：`FavoriteWords` 表虽有 `bookKey`，
  但导出载体 `ExportWord` 从来不带它，且收藏词按设计是「全局去重」的
  （`uniqueKeys: {expression, reading, sourceType}`），按来源切分语义不清。未改。
- 未做真机复测（面板尺寸手感需要真设备；widget 层已断言是 Dialog 且断言了来源列表）。
