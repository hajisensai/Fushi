## BUG-1851 · auto 引擎偏好下区域重识别可能与整卷用不同引擎，页内混引擎且 ocr 元数据仍写旧引擎
- **报告**：2026-08-25（用户：代码审查，PR #1000 随批发现）
- **状态**：作废（2026-11-17）。这条依赖的区域重识别功能已按产品决策整体移除
  （BUG-2461，提交 `350b9f2b2ae`）：下文的根因行 `manga_ocr_auto_start.dart:191` 与
  `replaceMangaBlocksInRegion` 都不存在了，「区域替换造成同页混引擎」的入口没有了，不再修。
  它担心的那类后果换了入口后仍在的部分——「只补缺页」把别的引擎的页冒名收下——由
  BUG-4815 处理。另：下文提的修法「把 `hasExistingMetadata` 透进去」本身不成立，该参数为
  true 时 `resolveMangaOcrEngine` 直接返回 null（表示不需要 OCR）。以下为当时的原始记录。
- **真实性**：✅ 当时属实（功能移除前）。根因 `fushi/lib/src/media/manga/ocr/manga_ocr_auto_start.dart:191`
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

- **备注**：审查意见原文见 PR #1000 的「建议同批」第 2 条。原记录里的修复方案与测试方案随功能
  移除一并作废，不再列待办。
