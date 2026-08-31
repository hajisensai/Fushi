## BUG-1990 · Mokuro CBZ 导入丢弃内嵌 OCR 文字层
- **报告**：2026-08-31（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/manga/import/manga_archive_importer.dart:140`（修复前）——CBZ/ZIP 导入只提取图片后调用 `importFromImageFolder`，包内 `.mokuro` 被当作非图片成员直接丢弃，最终生成 blocks 为空的 `manga.json`；同名旁挂 `.mokuro` 也没有配对入口。
- **[x] ① 已修复** — `3c1aea0b24`。archive 导入在任何落盘/DB 副作用前发现内嵌或同名旁挂 `.mokuro`，按整卷固定图片根用 `img_path` 绑定页图，再复用既有 `importFromMokuroPath` 两遍式导入；覆盖 CBZ/ZIP/纯图 EPUB 共用链、根目录/同名卷目录/任意套层、Windows 分隔符、大小写唯一匹配和 legacy HTML 旁件。损坏、缺页或歧义 manifest 明确失败，不再静默退化为空 OCR；仍保留 zip-slip、2 GiB 解包上限，并给 manifest 加 64 MiB 上限。
- **[x] ② 已加自动化测试** — `3c1aea0b24`，`fushi/test/media/manga/manga_archive_importer_test.dart` 覆盖内嵌 CBZ/ZIP OCR 全字段保留、同名 sidecar、嵌套卷目录防串绑、Windows 路径、多个 manifest 的确定性选择、损坏 manifest fail-fast，以及原有普通 CBZ/EPUB/路径穿越回归。定向命令在执行用例前被 `pdfium_dart` GitHub 原生资产下载超时阻塞，未宣称通过。
- **备注**：当前漫画图片白名单仍是 jpg/jpeg/png/webp/gif/bmp；未在本改动中仅凭扩展名放开尚未验证完整解码/封面/WebView 链的 AVIF。
