## BUG-4658 · 非 UTF-8 文件名（Shift_JIS）的 .zip 漫画打不开，导入框报不支持的格式
- **报告**：2026-11-15（用户反馈：Android 平板 HONOR YLP-W00，3.3.0 正式版，「.zip 漫画集有概率无法导入」）
- **真实性**：✅ 真 bug（构造样本复现）。Windows 日文环境的压缩工具把文件名按 Shift_JIS 写、不置通用位 11。
  `MangaArchiveImporter._open` 用 `InputFileStream` + `ZipDecoder.decodeBuffer` 开包；archive 3.6.1 读**本地头**
  文件名走 `InputFileStream.readString`（pub-cache `archive-3.6.1/lib/src/io/input_file_stream.dart:228-232`），
  严格 UTF-8 解码、没有 `InputStream.readString` 那样的回退，直接抛
  `FormatException: Unexpected extension byte`，整个包打不开。
  `looksLikeImageArchive`（`packages/fushi_engine/lib/media/manga/manga_archive_importer.dart:412` 旧行号）
  `catch (_) { return false; }` 把它吞成「不是漫画包」→ `classifyImportCarrier` 落到文本载体 →
  导入框弹「不支持的文件格式 .zip」，诊断日志里没有任何导入条目（与用户日志一致）。「有概率」= 只有
  非 UTF-8 文件名的包会中。
- **[x] ① 已修复** — `ci/patches/hosted/archive-3.6.1/lib/src/io/input_file_stream.dart`：`readString(size:)` 解码失败
  回退成逐字节字符（与 archive 自己的 `InputStream.readString`、中央目录那份同名的解码一致，名字逐字节可逆）；
  探测失败不再静默，写 `MangaArchiveImporter` 诊断日志。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_archive_importer_test.dart`
  「names without the UTF-8 flag (Shift_JIS) still probe and import, in natural order」（手拼 Shift_JIS 名 zip，
  探测为真、导入两页且自然序正确）。
- **备注**：名字按 Latin-1 逐字节保存，盘上的内部页文件名是乱码形态但不对用户展示（漫画无章节，页序靠自然序，
  字节序不变）。Shift_JIS 第二字节为 0x5C（`ソ`、`表` 等）时会被当成 `\` 分隔符多切一级目录，不影响导入成功。
  真正按 CP932 解码需要字符集探测（Dart 无内建解码器，按架构规则应进 Rust），已登拍板台
  `design-zip-cp932-names`（2026-11-16，按 `pr3444` 第 2 问的拍板补登）。同一缺口在 Windows 上更重：
  第二字节 0x7C 的字（`ポ` 等）逐字节后变成 `|`，Windows 不许它出现在文件名里，写盘失败、整本导入不了，
  一并写进了该条。
  **后续**：`design-zip-cp932-names` 已实现——导入时从中央目录读回原始名字字节，整包交给
  `ffc_text_legacy_decode`（`native/fushi_compute/src/legacy_text.rs`，与曲库 ID3 乱码修复同一份判据）
  判编码重解，0x5C / 0x7C 尾字节不再切目录 / 变 `|`；判不出编码时维持上面的逐字节行为。
  补丁删除条件同 `FUSHI_PATCH.md`：升 archive 4.x 后删补丁。
