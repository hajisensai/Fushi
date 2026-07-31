## BUG-1241 · 阅读器末页停在99%不自动标记读完
- **报告**：2026-07-29（用户）
- **真实性**：✅ 真 bug。分页/连续 `calculateProgress()` 都按“视口首字符 / 章节总字符”计算，抵达末页时首字符仍在章尾之前，分数天然可能只有 99%；Dart 却要求 `progress >= 0.999` 才自动完成。
- **[x] ① 已修复** — 分页按 `maxScroll`、连续按物理滚动终点、VN 按末屏索引提供 `isAtEnd()`；`hoshiProgressDetails()` 仅在真实终点把分子钳到 total，触发既有幂等完成链路。纯图片章在真实末页生成合成 1/1 快照，中间图片页仍走原 UI fallback。
- **[x] ② 已加自动化测试** — `reader_terminal_completion_bug1241_test.dart` 覆盖三种引擎末端谓词及 host 钳位；`reader_inchapter_progress_scroll_test.dart` 覆盖 100% 快照仍保留末页精确字符锚。
- **备注**：中间页继续使用字符级进度，不放宽 99% 阈值，因此不会提前标记。
