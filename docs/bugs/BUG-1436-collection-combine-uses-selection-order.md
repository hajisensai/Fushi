## BUG-1436 · 批量组合成合集：成员按点选顺序落 sortIndex，选集列表乱序

- **报告**：2026-08-02（用户：手动做成合集之后里面的顺序也是乱的）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/home_video_page.dart:1124`（`_selectedUids` 是 `Set<String>`，迭代序 = 点选/框选顺序，逐条 `addToCollection` 即定死 sortIndex）；书架页 `hibiki/lib/src/pages/implementations/reader_history/books.part.dart:685` 同构。

### 复现

视频库页多选一整季 → 「组合」→ 命名 → 建成合集 → 合集详情页「选集」列表顺序为
E09、E10、E07、E12、E04、E03、E05、E11（= 用户点选顺序 / 库页当前显示顺序），不是集号序。

### 根因

`addToCollection` 在 DAO 层拿不到标题，无从自然排序；调用方三档（新建 / 并入 / 合并）
都直接按选择集迭代序逐条落盘。合集详情页已有「一键整理」（`collection_one_key_sort.dart`），
但那是**事后**的手动补救，默认路径从不排序。

### 影响面

视频库页与书架页的批量「组合成合集」；合集内成员序（库页合集行、播放器换集读同一
`getCollectionItems`，落盘即同序）。

- **[x] ① 已修复** — 新增共享真相源 `sortNewCollectionMembersNaturally`
  （`hibiki/lib/src/media/collections/collection_one_key_sort.dart`）：落盘前按显示标题
  `naturalCompare` 排序（规则与「一键整理·按名称」同源），同名按输入下标兜底（`List.sort`
  非稳定）。视频页与书架页在 `_batchCombineIntoSeries` 里对 `looseRefs` 一次排好，三档共用。
  只排**本次批次**——并入既有合集时不动已有成员相对序（可能是用户手动拖拽排好的）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/collections/collection_combine_member_order_test.dart`
  5 例（自然序取代点选序 / 卷号数值序 / 同名保持输入序 / 空表单元素 / 不改入参）。
  变异实测：把 `naturalCompare` 结果压成 0 → 2 个 error event，守卫有效。

- **备注**：与 [[BUG-1435]] 是同一用户报告的两条独立缺陷——1435 让「按文件夹导入」建不出
  合集（导入路径自带 季→集 排序，修好后无此问题），1436 让**手动**建的合集内部乱序。
