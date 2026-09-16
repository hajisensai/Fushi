## BUG-2547 · 书架排序忽略远端占位卡：host 下发的时刻不用、恒沉底
- **报告**：2026-09-15（用户：合集外排序不对，附书架截图）
- **真实性**：✅ 真 bug。远端占位卡在**任何**排序档下都绕过真实量纲，被钉在本地条目之后：
  - `fushi/lib/src/pages/implementations/reader_fushi_history_page.dart:1004`（`recentOf`）
    对 `remote` / `remoteSrt` 槽**无条件**返回 `it.importedAt`——而 `it.importedAt` 正是下面
    注入时编码的负数目录序，于是「最近阅读」档的 recency 恒为负。
  - 同文件 `:1492` / `:1503` 注入远端占位时写死 `importedAt: -1 - i`，从不使用 host 时刻。
  - 根因在 wire：`RemoteBookInfo` / `RemoteAudiobookInfo` **没有** `importedAt` 字段
    （`packages/fushi_engine/lib/sync/fushi_library_host_service.dart:296` / `:119`），
    host `listBooks` / `listAudiobooks` 也就无从下发；而 `progressUpdatedAtMs` /
    `positionUpdatedAtMs` 明明已经在清单里，客户端却没消费。
  - 对照组证明这是书侧漏跟而非设计：视频页早已两样都用——
    `home_video_page.dart:5281`（`video.importedAt ?? (-1 - i)`）与 `:5313`
    （`remote.positionUpdatedAtMs`）。`RemoteVideoInfo.importedAt` 的文档注释把理由写得很清楚。
  - 附带：`_shelfGroupSortKey` 的合集组聚合从 `0` 起做 max（`:1039`），成员键全为负的
    「全员远端」合集组会被抬到 0——排在所有远端散卡之前、本地条目之后的一个不存在的位置。
- **[x] ① 已修复** — wire 加 additive `importedAt`（书 / 纯 SRT 有声书各一个，旧 host 不带 →
  null → 逐字节同旧行为），host `listBooks` 下发 `EpubBooks.importedAt`、`listAudiobooks`
  下发 `SrtBooks.importedAt`；书架 `recentOf` 改用 `progressUpdatedAtMs` /
  `positionUpdatedAtMs`（>0 时），注入改 `host 戳 ?? -1-index`；组聚合基准改取首成员。
- **[x] ② 已加自动化测试** —
  `fushi/test/pages/reader_remote_collection_membership_test.dart`（「最近阅读」/「导入时间」
  两档各一条真 widget 行为测试：目录序与真实时刻相反时，卡片位置必须按真实时刻）+
  `fushi/test/sync/fushi_library_host_service_books_test.dart`（additive wire round-trip：
  带戳透传、旧 host 不写键且解出 null；host `listBooks` 真下发 `EpubBooks.importedAt`）。
  反向验证：把两个源文件还原成上游原版后，4 条新测试全红、7 条原有测试仍绿。
- **备注**：与 [BUG-2548](BUG-2548-collection-detail-drops-remote-members.md) 同一批提出
  （同一次用户报告的两张截图），同一 PR 修。渲染层「合集区在上、散卡区在下」的分区是
  去碎片 spec 2026-07-12 拍板的方案 A，本次**不动**。
