## BUG-1851 · auto 引擎偏好下区域重识别可能与整卷用不同引擎，页内混引擎且 ocr 元数据仍写旧引擎
- **报告**：2026-08-25（用户：代码审查，PR #1000 随批发现）
- **真实性**：✅ 真 bug（未修）。根因 `fushi/lib/src/media/manga/ocr/manga_ocr_auto_start.dart:191`
  —— `startMangaOcrWithPreferredEngine` 里 `resolveMangaOcrEngine(..., hasExistingMetadata: false)`
  是**硬编码**的，调用方无法告诉它「这本书已经有 OCR 元数据、是哪个引擎跑的」。

  后果：整卷当初用本地 ONNX 跑完的书，若此刻 ONNX 不可用（模型被删 / 平台不支持），
  `auto` 会挑 `systemOcr` 去重识别一块，于是**同一页混两种引擎的结果**（竖排气泡的
  切分与断行口径完全不同）。而 `manga.json` 顶层的 `ocr` 元数据（引擎 + 签名）被
  `replaceMangaBlocksInRegion` 有意原样保留、仍写着旧引擎，
  `fushi/lib/src/media/manga/ocr/manga_ocr_cache_recovery.dart` 的同源判定因此把这页
  判成「同源」，不会提示用户重跑。

  `auto` **不会**回落到 Google Lens（`manga_ocr_auto_start.dart:195` 的注释与实现一致），
  隐私边界没破，这条只是结果质量与元数据可信度问题。

- **不是 PR #1000 引入**：点击识别（tap-OCR）走同一条 `startMangaOcrWithPreferredEngine`，
  一直是这个行为。PR #1000 让它第一次发生在**页内**（区域替换会删掉旧块再插新块），
  所以同页混引擎从此肉眼可见。

- **[ ] ① 未修复** — 正解是把「本书已有元数据的引擎」透进 `startMangaOcrWithPreferredEngine`
  （加一个 `existingEngine`/`hasExistingMetadata` 入参，由调用方从 `payload.ocr` 取），
  让 `resolveMangaOcrEngine` 在 `auto` 下优先复用同源引擎；同源引擎不可用时要么明确告知
  用户「会与整卷不同源」，要么在替换后更新 `ocr` 元数据为 `mixed`。这动的是整卷 / 点击 /
  区域三个入口的共同契约，超出 PR #1000 的爆炸半径，单独一批做。
- **[ ] ② 未加自动化测试** — 修的时候在 `manga_ocr_auto_start` 层加：「有 local_onnx 元数据
  + ONNX 不可用 + 偏好 auto ⇒ 不静默换 systemOcr」。
- **备注**：审查意见原文见 PR #1000 的「建议同批」第 2 条。
