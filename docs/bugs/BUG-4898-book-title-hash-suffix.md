## BUG-4898 · 书架 / 漫画库卡片标题带文件名哈希后缀「[679fb7c9]」
- **报告**：2026-11-15（用户：拼贴审查设计稿 #manga C1，截图）
- **真实性**：✅ 真 bug。没刮到元数据的书 / 漫画以文件名当 `epub_books.title` 入库，下载工具留在文件名末尾的
  `[8 位十六进制]` 哈希原样上屏：书族显示出口 `MediaSource.getDisplayTitleFromMediaItem`
  （`fushi/lib/src/media/media_source.dart:391` `return item.title;`）与 `displayTitleForBook` 的原名回退
  （`fushi/lib/src/media/display_title.dart:78/81/83`）都直接返回原名。
- **[x] ① 已修复** — 纯函数 `stripTitleHashSuffix`（`fushi/lib/src/media/display_title_hash_suffix.dart`，只认末尾
  `[0-9a-f]{8}`，去掉后为空则原样）；书族源基类 `ReaderMediaSource.getDisplayTitleFromMediaItem` 覆写为
  `override ?? stripTitleHashSuffix(item.title)`，`displayTitleForBook` 三条通道的原名回退同样清洗。只改显示：
  `item.title` / `bookKey` / 统计聚合键不变，用户改过的显示名不清洗。提交哈希：收尾阶段统一提交后补。
- **[x] ② 已加自动化测试** — `fushi/test/media/display_title_hash_suffix_test.dart`（纯函数边界 + EPUB / 漫画源出口 +
  override 不清洗 + displayTitleForBook 三通道）。
- **备注**：设计稿同条提到的「拼贴默认改规整」与「`(9)` 重复卷号」不在本条范围。
