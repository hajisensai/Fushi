## BUG-4909 · 手柄/键盘光标换行移动每按一次键对整章逐字量几何，长章一次约 0.6 秒
- **报告**：2026-11-20（路线图 2026-11-17 测量组 m1 / gap-readerjs2-2 实测发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/reader/reader_caret_scripts.dart:506`（修前）`_collectVisibleStops` 对整章每个文本节点的每个字各调一次 `_charRect`（`Range.getClientRects`）再判是否在视口内，而 `_inViewport` 每次还重读一遍 `_viewport()`（`getComputedStyle` + `body.getBoundingClientRect`）。换行移动（竖排左右 / 横排上下）、`_lastVisibleStop`、`_firstVisibleElementStop` 都走它，`_firstVisibleStop` 同样从章首逐字量。桌面 headless Chrome、10 万字单章（4749 个文本节点）：每按一次键 113892 次 getClientRects + 113892 次 getBoundingClientRect，分页竖排中位数 619ms（P95 658ms）、连续竖排 594ms；首次进入光标 598～659ms。小章（98 个文本节点）也要 11ms。
- **[x] ① 已修复** — 一个字的字形盒落在它所在文本节点的某个行盒里，所以先按文本节点行盒判是否与视口相交（`_nodeTouchesViewport`），不相交的整节点跳过；视口每次收集只读一次（`_rectInViewport(rect, vp)`）。结果与修前逐次一致。同一装置：10 万字章换行移动中位数 619ms → 13.7ms（分页）、594ms → 13.5ms（连续），小章 11ms → 3.3ms。提交见 PR（`pr/measure-reader-engine`）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/paged_text_index_caret_test.dart`（真 Chrome 跑生产分页 shell + 光标脚本：每次换行移动的落点与关掉节点预筛时逐次一致；一次移动的 getClientRects 次数 < 章内字数的一半，修前 68052 次 / 52800 字必红）。
- **备注**：剩余开销是每个文本节点量一次行盒（与章内文本节点数线性相关，10 万字章约 3900 次）。要降到只与本页相关，得假设「文档序 = 视觉序」提前截断，浮动 / 定位排版里会漏掉可见字，本次不做。移动端未实测（本轮不做真机）。
