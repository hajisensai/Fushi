## BUG-1121 · bmp-manga-ocr-skipped
- **报告**：2026-07-26（用户：）
- **真实性**：✅ 真 bug（白名单漂移）。根因 `hibiki/lib/src/ocr/manga_ocr_folder_job.dart:31`（修复前）——整卷 OCR 页图白名单 `kMangaOcrImageExtensions` 手写 `{.jpg,.jpeg,.png,.webp}`，比漫画导入白名单 `hibiki/lib/src/media/manga/manga_importer.dart:16` `kMangaImageExtensions`（另含 `.gif`/`.bmp`）少两项；`enumerateMangaPages`（同文件 :102）按白名单过滤 → 导入能收的 bmp 漫画整卷 OCR 时 bmp 页被**静默跳过**，产物 `manga.json` 缺页且无任何提示。解码端非瓶颈：`decodeMangaPageFile` 走 `img.decodeImage` 内容嗅探，本就支持 bmp/gif。
- **[x] ① 已修复** — 新建共享基集 `hibiki/lib/src/media/media_extensions.dart`（`kImageExtensionsBase`，图片扩展名唯一起点，各用点显式增删并注释理由），导入 `kMangaImageExtensions` 与 OCR `kMangaOcrImageExtensions` 两道关卡都直接取基集（同一 const，口径不可能再漂移）；同批收敛另 3 份手写副本（galgame 封面 ＝基集−gif＋ico、插图查看器 ＝基集＋svg、视频 sidecar 海报 ＝基集−gif−bmp，差异各自显式注释）。提交 `ffb05cb76`。
- **[x] ② 已加自动化测试** — `hibiki/test/ocr/manga_ocr_image_extensions_guard_test.dart`（两关卡口径一致 + 基集含 `.bmp`/`.gif` 守卫）；`hibiki/test/ocr/manga_ocr_folder_job_test.dart` 枚举用例补 `.bmp` 页 + 新增「含 .bmp 页整卷 OCR」用例（真实 `encodeBmp` → `img.decodeImage` 解码路径，断言检测到该页且产物含 `p2.bmp`）。提交 `ffb05cb76`。
- **备注**：`.gif` 页同因同批补齐（导入同样认 gif）。同名视频侧漂移（G10：刮削端扩展名小表剥不掉 `.rmvb`）在同一 PR 以共享 `kVideoExtensions` 收敛，不另开 bug。
