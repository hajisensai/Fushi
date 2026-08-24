## BUG-1852 · 框选区域重识别移除了旧「框选查词」直通词典的入口
- **报告**：2026-08-25（用户：代码审查，PR #1000 随批发现）
- **真实性**：✅ 属实（行为回退，**产品意图待确认**）。

  旧「框选识别」的结果卡片 `fushi/lib/src/media/manga/reader/manga_rescan_result_sheet.dart`
  （PR #1000 已删）有两个动作：`MangaRescanAction.lookup`（识别文本直接进词典管线，
  句子上下文 = 气泡本身）和 `MangaRescanAction.writeback`（回写本页）。

  新流程只保留了「识别 → 替换文字层」。要查词得**再点一次**文字层里的框，多一步；
  且 OCR 认出文字但块几何落在文字层不可点的位置、或结果为空时，**彻底查不了**——
  旧路径至少还能把识别到的文本交给词典。

- **对面收益**：新流程换来的是「结果直接进文字层、下次打开还在、外部 mokuro 也能读」，
  以及删掉了一个独占的本地 OCR isolate 服务（`ocr/manga_box_rescan.dart`，449 行）。
  取舍本身可能是有意的。

- **[ ] ① 未修复** — 需要用户/产品确认这是有意取舍还是回退。若要补，最小改动是在
  `manga_fushi_page.dart` 的 `_offerRegionRescanUndo` 那条 SnackBar 上再挂一个「查词」
  动作，文本取 `outcome.payload!.images[pageIndex]` 里本次新增块的 `lines`；不必复活
  结果卡片。
- **[ ] ② 未加自动化测试** — 补的话钉「区域重识别成功后能把新块文本交给词典管线」。
- **备注**：审查意见原文见 PR #1000 的「建议同批」最后一条。
