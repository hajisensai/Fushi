## BUG-4659 · 解出超过 2 GiB 的 .zip 漫画一律报 too large 无法导入
- **报告**：2026-11-15（用户反馈：Android 平板 HONOR YLP-W00，3.3.0 正式版，「不能导入 2G 以上的 .zip 文件」）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/manga/manga_archive_importer.dart:21`（旧行号）
  `_maximumArchiveExpandedBytes = 2 GiB` 是与包大小无关的绝对上限，ZIP 预检（旧 :455）、流式解压
  `_ensureWithinTotal`（旧 :1258）、7-Zip 列表 / 解出校验（旧 :294 / :321）与 EPUB 探测（旧 :879）共用。
  页图（JPEG/PNG/WebP）进 zip 压不动，解出量≈包体积，所以任何 >2 GiB 的正常漫画包都报
  「Manga archive is too large」。这个上限本意是防解压炸弹，不是限制漫画体积。
- **[x] ① 已修复** — 预算改为 `max(2 GiB, 包体积 × 8)`（`mangaArchiveExpandedBudget` /
  `MangaArchiveExtractionLimits.totalBudgetFor`），ZIP / 7-Zip / EPUB 探测同一口径；炸弹防线（实际解出字节
  不得超过声明、声明总量不得超过预算、单条 256 MiB）不变。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_archive_importer_test.dart`
  「the expanded-size budget scales with the archive, not a fixed 2 GiB」「the derived budget is measured from the archive file size」「a tiny archive declaring more than its
  budget is still rejected before anything is extracted」。真实 4.5 GiB ZIP64 的 4K 图集导入在本机手工验证（见 PR）。
- **备注**：包体积取文件长度（`InputFileStream.length` 是剩余字节，读完中央目录后只剩几十字节，首版修复误用它、被 4.5 GiB 真实样本测出，已有回归用例「the derived budget is measured from the archive file size」）。导入期间磁盘峰值约为包体积 × 2（staging 解出 + 拷进书目录），另有原包本身；大包在空间紧的设备上可能
  因磁盘满失败（会以 FileSystemException 报出）。staging→书目录改为 rename 可省一份，列为后续项。
