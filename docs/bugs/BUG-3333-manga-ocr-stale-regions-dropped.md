## BUG-3333 · 漫画 OCR 覆盖层字级区域对不上文字时逐个丢弃，部分字无可点区域
- **报告**：2026-10-13（用户：PR #2123 审查遗留——视频图形字幕侧已在 e428a55048 修过同类问题，漫画覆盖层还在逐字丢）
- **真实性**：✅ 真 bug。根因两处：
  - `fushi/lib/src/media/manga/manga_overlay_html.dart:346-350`（修前）`mangaEffectiveTextRegions` 只要 `block.regions` 非空就原样返回，不核对它与 `block.lines.join()` 是否对得上；
  - `fushi/lib/src/media/manga/manga_overlay_html.dart:465-470`（修前）`_mangaCharacterRegionsHtml` 遇到越界区域 `continue` 逐个丢掉。
  - 后果：manga.json 里文字被改写（外部 mokuro 产物、手改、旧版缓存）而 `regions` 仍是旧偏移时，越界的字没有 `<span class="ocr-char">`、点不到；文字变长时旧区域都在句内但只盖住前半句，后半句点不到；区域**全部**越界时 `regions.isNotEmpty` 仍为真，`<p>` 被设成 `pointer-events:none` 且内部没有 span——整块完全点不到。偏移切在代理对中间时还会 substring 出半个字。
  - 视频侧 e428a55048 在 `graphic_subtitle_ocr.dart` 自己包了一层「有一个对不上就去掉 regions 重算」，判据只修在消费方，漫画覆盖层没受益。
- **[x] ① 已修复** — 判据下沉到 `mangaEffectiveTextRegions` 本身（漫画覆盖层与视频图形字幕共用的唯一入口）：新增 `mangaTextRegionsMatchSentence`（每个区域是句内、落在字素边界上的非空 UTF-16 区间，且合起来盖住每个非空白字素），对不上就整块改走 `lines_coords` / 块框的行几何；`_mangaCharacterRegionsHtml` 不再逐个过滤；视频侧删掉 `_charsFromRegions` / `_withoutSuppliedRegions` 双试逻辑，直接复用同一判据。提交见 PR 分支 `fix/manga-ocr-region-fallback`。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_overlay_html_test.dart` 组「mangaEffectiveTextRegions 字级区域对不上文字时整块回退 (BUG-3333)」7 条：全部对得上照用、空白不要求覆盖、部分越界、全部越界（含覆盖层 HTML 每个字都有 span）、AI 重读变长 / 变短、偏移切在代理对中间；视频侧既有 `fushi/test/media/video/graphic_subtitle_pause_ocr_test.dart` 两条照绿。变异实测：把 `mangaEffectiveTextRegions` 回滚成「非空就原样返回」，新组 5 条红（两条「对得上」用例按预期仍绿），视频侧「有一个对不上整块改按行框」1 条也红（证明视频侧现在确实走共享判据）；恢复后两个文件 60 条全绿。
- **备注**：当前生产者（Lens 新结果、本地 ONNX、`applyMangaAiOcrText`）都不会产出过期 regions（AI 重读路径已在 `manga_ai_ocr_refiner.dart` 丢掉 regions），触发面是磁盘上 manga.json 的外部 / 旧版 / 手改数据；判据放在消费入口就不再依赖每个生产者自觉。
