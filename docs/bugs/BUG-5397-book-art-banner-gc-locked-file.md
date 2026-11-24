## BUG-5397 · 孤儿横幅删不掉时整个清除中断
- **报告**：2026-11-23（BUG-5396 修复时发现：合集详情页 hero 测试在 Windows 上清除时抛 `PathAccessException ... errno = 32`）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/metadata/book_art_store.dart:484` `collectOrphanBanners` 对每个孤儿横幅直接 `await e.delete()`，文件被占用时抛出，向上冒到 `remove` / `rejectCover` / 刮削收尾 / ops 撤销）
- **[x] ① 已修复** — 孤儿回收改为尽力而为：删不掉的那张记诊断日志、留到下一次回收（每次刮削收尾 / 清除 / 否决都会跑）
- **[x] ② 已加自动化测试** — `fushi/test/media/metadata/book_art_store_test.dart`（打开横幅文件期间清除不抛、记录已删，关闭后下一次回收删掉）；`fushi/test/pages/collection_detail_poster_hero_test.dart`（Windows 上背景带正在读横幅时清除）
- **备注**：Windows 上 Dart 打开文件不带 `FILE_SHARE_DELETE`，背景带的 `FileImage` 读横幅的那几毫秒里删不掉。

### 根因

`collectOrphanBanners` 是回收「没有任何书引用的横幅文件」的垃圾回收，调用时记录已经一致（引用已删）。
它却把单个文件删除失败当成致命错误抛出：

- 合集「清除已获取的封面」逐本 `store.remove`，第一个撞上的就中断，后面的书一本都不清，也没有提示；
- 单本否决、刮削收尾、ops 撤销同样被一个暂时删不掉的孤儿文件打断。

### 修复

删除失败（`FileSystemException`）时记 `BookArtStore.gc` 诊断、跳过这一张；文件仍是孤儿，下一次回收照常删。
记录、横幅引用、持有（`holdBanner`）逻辑不变。
