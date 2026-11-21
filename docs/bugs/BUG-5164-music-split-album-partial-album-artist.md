## BUG-5164 · 同一张 CD 只有部分曲目写了专辑艺人，被拆成两张专辑
- **报告**：2026-11-21（用户：专辑墙上两张「Here, the world!」——「这俩不是同一个cd吗 这个cd少了」）
- **真实性**：✅ 真 bug。用户库 `…\CDs\CDBOX\` 一个目录 4 首：01 带专辑艺人 `sumimi`，02–04 专辑艺人为空。专辑 uid 由 Rust 按单首算（`native/fushi_music/src/uid.rs` `album_uid`）：有专辑艺人按（艺人, 专辑名），没有按（目录, 专辑名），于是 1 首 + 3 首两个 uid，CD 详情只列 2–4 首、第 1 首在另一张里。单首算 uid 看不到同目录兄弟曲目，增量扫描时没变的文件也不重读标签，所以在 Rust 单首层面无法根治。
- **[x] ① 已修复** — `FushiDatabase.mergeSplitMusicAlbumsOfSource`（`packages/fushi_core/lib/src/database/database_music.part.dart`），扫描收尾（`MusicLibraryScanner._ingest`）对整源在库状态归并：同一目录、同名（`musicAlbumNameKey`，与 `uid.rs` `normalize_name` 同口径）的专辑里，带专辑艺人的恰好只有一位艺人时，把没写专辑艺人那几张的曲目改挂到带艺人那张。被并空的旧专辑行留着（`listMusicAlbums` 只列有在库曲目的专辑）；某首文件改了被重新解析落回旧 uid，下次收尾再并。存量库下次扫描该来源时自动并回。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_library_scanner_test.dart`「BUG-5164」：同目录部分无艺人并回（含全角写法）、别的目录同名不动、同目录两位不同专辑艺人不动、并空的旧专辑不再列出。
- **备注**：只并同一目录。不同版本目录（BUG-5058 的 `[24bit_…]` 与 `(flac+webp)` 两份、一份无艺人）仍按版本各一张——跨目录按同名合并会误并同一父目录下的同名异专辑，盘面图共享已由 BUG-5058 处理。后续（BUG-5147 / HBK-AUDIT-027）：`mergeSplitMusicAlbumsOfSource` 整源收尾并组已换成 schema v167 的原始归属列 `scan_album_uid` + 写入 / 软删事务内只对受影响目录重算（`_regroupMusicAlbumDirs`），并组规则不变。
