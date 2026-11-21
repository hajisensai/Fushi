## BUG-5100 · WebP/AVIF 漫画页探尺寸重复打开并重读前缀（HBK-AUDIT-051）
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-051，来源 PR #3785）
- **真实性**：✅ 真 bug（性能）。`packages/fushi_engine/lib/media/manga/manga_importer.dart` 的 `pageSizeOfFile`（修前 `:219`～`:234`）先开句柄读 128 KiB 前缀、关掉句柄；`probeImageSizeFromPrefix` 只认 PNG 与头部在前缀内的 JPEG，WebP / AVIF / BMP / GIF / TIFF 一律定不了论，于是 `file.readAsBytes()` 重新打开文件、从头再读整页。每页多开一次文件、多读 128 KiB（或整页短于前缀时不重读）。实测（修前代码）：一张 307268 字节的 WebP 页打开 2 次、读出 438340 字节（= 128 KiB 前缀 + 整页）；修后 1 次、307268 字节。
- **[x] ① 已修复**（92df801c07）— 同一个句柄接着读前缀之后的部分（`_readRest`：按 `length` 分配一块缓冲、拷入已读前缀、`readInto` 读剩余），每页只开一次、每字节只读一次；文件在两次读之间被截短时返回实际读到的部分。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_import_parse_once_test.dart`「HBK-AUDIT-051」组：用计数 `File` 包装测 WebP（EXIF 方向块在前缀之后，验证宽高仍对调）与小于前缀的 BMP，断言 `(opens, bytesRead) == (1, 文件长度)`。变异实测：换回修前实现后 WebP 用例红，`Expected (1, 307268) / Actual (2, 438340)`。
- **备注**：WebP 的 EXIF chunk 可以落在像素数据之后，前缀探测不收 WebP 是有意的（见 `probeImageSizeFromPrefix` 注释），本修复不放宽前缀判据。
