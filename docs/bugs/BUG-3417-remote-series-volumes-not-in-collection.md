## BUG-3417 · 远端占位分卷不进本地同系列合集
- **报告**：2026-10-15（用户：手机漫画库截图，「志乃と恋」系列卡只有 2 册，「志乃と恋 3」「志乃と恋 4」散在旁边）
- **真实性**：✅ 真 bug。用电脑正式库快照核实：合集 101「志乃と恋」只有第 1、2 卷（`book_…_5` / `book_…_6`），第 3 卷 `志乃と恋 3 [998c5526]` 和第 4 卷 `志乃と恋 ４` 都是 `format=manga`、没有成员墓碑，系列键解析也正确。手机上的 3、4 卷是电脑（host）下发的远端占位卡，有两个原因：
  1. 归组器 `BookSeriesGrouper` 只在书架页 `_loadShelfMaps` 里跑（`fushi/lib/src/pages/implementations/reader_fushi_history_page.dart:1131`）。host 在新版本里还没打开过书架、或 host 是旧版 / 无头服务端时，持久归组还没把 3、4 卷收进合集，清单里 `collection` 就是 null。拿当前代码的归组器跑电脑库快照，3、4 卷会被正确收进合集 101，顺序为 1、2、3、4。
  2. client 端对不带 `collection` 的远端占位卡只按「整本同名」回查本地归属，查不到就降级成散卡（同文件 `:1854`）；本机没有这两卷的行，归组器也碰不到它们。
- **[x] ① 已修复** — `61d092124c`：新增纯函数 `placeLooseVolumesInSeriesCollections`（`packages/fushi_engine/lib/media/collections/series_collection_placement.dart`），判据与归组器同源，目标是同系列成员 ≥2 的合集。没有归属的远端占位卡按系列键归入这个合集，组内按卷号插入，**只影响显示、不落库**；下载入库后由归组器持久收编。章节式在线条目（`hasMangaChapters`）是一整部作品，不参与。
- **[x] ② 已加自动化测试** — `fushi/test/media/collections/series_collection_placement_test.dart`（用户真实书名：3、4 卷按卷号接在 1–2 之后；中间卷插入；单卷主题合集不算；异系列不动）。
- **备注**：
  - 页面接线点（`reader_fushi_history_page.dart` 的 `placeLooseVolumesInSeriesCollections(` 调用）目前只有纯函数单测，没有书架 widget 级测试；真机复测（手机连电脑 host）待补。
  - 截图里两张不带卷号的「志乃と恋」大概率是在线漫画行，例如电脑上的 Mihon 条目 `mihon-b97e…`，或手机经互联收下的对应行。在线行「一行 = 一整部作品、不按卷归组」是设计如此，不在本 bug 范围内。
