## BUG-2139 · attached 从 `waitingForBodyThread` 的恢复只挂在「正文从无到有」这一次性边沿上
- **报告**：2026-09-03（BUG-2137 的第二条分支落地后，真机上停在 `waitingForBodyThread/state_event_no_glyph_clusters_before_text` 不动，由此定位）
- **真实性**：✅ 真 bug，真机复现 + 变异实测。
- **根因**：`fushi/lib/src/lookup/gal_attached_text_controller.dart` 的 `syncSession` 里，重新评估的判据是
  ```dart
  final bool bodyArrived = _latestSourceText.isEmpty && nextText.isNotEmpty;
  if (bodyArrived && _status == GalAttachedTextStatus.waitingForBodyThread) { ...重新评估... }
  ```
  `bodyArrived` 是**一次性边沿**（上一句为空、这一句非空）。但 `waitingForBodyThread` 有**第二个来源**：子面在正文真正落地前回 `noGlyphClusters`（BUG-2137 那条分支）。那时 `_latestSourceText` 早已非空，这个边沿**再也不会出现**——于是状态永久停在「等正文」，尽管正文每一行都在到，`_pushLatestTextIfActive` 又只在激活态推送，两边都不动。
- **[x] ① 已修复** — 判据改成「还在等正文 **且** 手上确实有正文」：
  ```dart
  if (nextText.isNotEmpty && _status == GalAttachedTextStatus.waitingForBodyThread) {
  ```
  `bodyArrived` 是它的真子集，只放宽**恢复时机**，不放宽任何准入判据（profile / 风险 / variant / registry 四道门一字未动）。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_attached_text_controller_test.dart` 的「BUG-2138 已在等正文且正文一直都在时，同一句也要能把状态救回来」：先激活 → 子面回 `emptyText` 把状态推回等正文（此时正文早已非空）→ 同一句再同步一轮 → 断言恢复到 `activeAttached`。**变异实测**：把判据换回 `bodyArrived` 当场红。同文件 46 条全绿。
- **关联**：[[BUG-2137]]（本条是它第二条分支暴露出来的）、[[BUG-2138]]（本条修好后才走到真正的建簇失败）。
