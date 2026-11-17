## BUG-4793 · 漫画来源索引只在扫描结束时落盘，中途被杀后同名卷再导一份 Vol 1 (3)
- **报告**：2026-11-17（nmv 优化清单 gap-scanner-7，代码路径复核时发现，非用户实报）
- **真实性**：✅ 真 bug（判据逐行走通，未在真机复现）。来源扫描索引（源相对路径 → 书 uid + 负向表）只在 `_importManga` 的 `finally` 里保存一次（修前 `fushi/lib/src/media/source_library/source_library_scanner.dart:1854-1863`），`record` / `reject` 只改内存（修前 `:412`、`:456-459`）。`finally` 管得了异常，管不了进程被杀——手机上扫描中切后台被系统回收、远端首扫下载几个小时被打断都是。索引丢了之后：
  - `系列A/Vol 1.cbz`、`系列B/Vol 1.cbz`（上一轮已导成 `Vol 1` 与 `Vol 1 (2)`）：A 认领 `Vol 1`（`sameSource`）；轮到 B，标题同为 `Vol 1`、那一行已被在场的 A 认领 → `otherSourceFile` → `DuplicatePolicy.suffix()`（修前 `:435-436`）→ 再导一份 `Vol 1 (3)`，旧的 `Vol 1 (2)` 永远没人认领；
  - 负向表同样丢：判过「不是漫画」的包全部重新开包，远端是重新下载。
- **[x] ① 根因修复** — `1f9ad3f6a23`：`_MangaVolumeTally.attempt` 每卷结束后调 `_MangaSourceIdentity.flush`——这一卷改了索引（入库登记 / 认领旧行 / 记负向表）就落盘一次（一条 preferences 写入），没改动是空操作。末尾 `finally` 的整份保存保留。游戏扫描器不用改（丢索引后按目录认领已有游戏，不会重复登记）。
- **[x] ② 自动化测试** — `fushi/test/media/source_library/source_library_scanner_test.dart`「索引逐卷落盘：扫到第三卷时进程被杀，重扫仍是两本、不出 Vol 1 (3)」：两个目录各一本同名卷 + 第三卷走 7z 替身，在替身里（前两卷已导完）读出此刻**已落盘**的索引；把库还原成那一刻的索引后重扫，断言仍是 `Vol 1` 与 `Vol 1 (2)`。修前那一刻索引为空、测试即红。
- **备注**：导入器写书行与索引落盘之间仍有一个很小的窗口（一卷的量级）。待真机：手机上远端漫画来源首扫中途切后台杀进程后重扫。
