## BUG-5024 · 在线漫画描述符各写方拿快照整份写回、互相回滚；按下标选章开错章
- **报告**：2026-11-20（路线图 #3722 c50 · gap-mangamisc-1，审读发现）
- **真实性**：✅ 真 bug。基准 `origin/develop` @ `7745effa2e`：
  - `fushi/lib/src/media/manga/library/online_manga_library_service.dart:182`（`refresh`）、`:287`（`selectChapter`）、`:310`（`setSubscription`）三个写方都是「拿调用方手上的 `entry` 快照 → `copyWith` → `updateEpubBookMihonState`（`:215` / `:298` / `:320`）整份覆盖 `sourceMetadata`」，不重读库里当前值。作品页进页即发起静默刷新（`manga_series_page.dart` `_refreshFromSource(silent: true)`），刷新在飞的几秒里点订阅：订阅先落库，随后刷新带着进页时的快照落库，把 `subscribed` / `autoDownload` 写回旧值。后台更新探针（`fushi/lib/src/updates/update_probes.dart:73`）同理，且按探针开跑时的快照判 `autoDownload` 与「新出现的章」。
  - `manga_series_page.dart:1559/1563`：`selectChapter(chapterIndex: index)` 与 `_openReader(chapterIndex: index)` 的 `index` 是页面手上那份章表的下标；库里章表已被一次刷新改过（源插了新章）时，同一个下标在阅读器读到的库内章表上是另一章，开错章。
- **[x] ① 已修复** — `fushi_core` 加 `rewriteEpubBookMihonState`（`packages/fushi_core/lib/src/database/database_content_misc.part.dart`）：一个事务里重读 `sourceMetadata`，交给回调只改负责的字段再写回。三个写方改走它：刷新只换作品资料与章表（订阅位、当前章取库里的），订阅只改两个布尔，选章改为按 `chapterKey`、在库里章表上定位并返回写回后的描述符；作品页与阅读器换章改用返回值的 `currentChapterIndex` 开章。探针改用 `refreshFromSourceWithOutcome`，自动下载位与新章都按落库时的库内描述符判。小说侧三个 `updateEpubBookMihonState` 调用点不动（计划范围外）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/online_manga_library_entry_v3_test.dart`：旧快照刷新不回滚期间点的订阅；旧快照写订阅不回滚选章与新章表；`selectChapter` 按 key 在库里章表已变时选中同一章、下标按库内章表重算、已下架抛 `StateError`。`fushi/test/updates/online_manga_update_probe_test.dart`：刷新途中关了自动下载 / 作品页已刷进新章时，探针不入队、不把自动下载写回 true。改前这些用例全红（快照整份覆盖）。
- **备注**：真机复现（进页几秒内点订阅）本轮不做（所有者定），由上面的服务层用例覆盖同一条写路径。
