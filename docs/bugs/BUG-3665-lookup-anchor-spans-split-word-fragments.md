## BUG-3665 · lookup-anchor-spans-split-word-fragments
- **报告**：2026-10-21（用户反馈 cI-MiReEKo，Android：「在边缘查词，查词卡片位置不合适」。截图：翻页模式，页顶首行 `perfluous`（`su-` 断在上一页末行），查词卡被挤成贴屏底的一条，只露出顶栏和词头）
- **真实性**：✅ 真 bug。阅读器查词先按选区首字显示弹窗，再用 `highlightSelection` 返回的「被查词 bbox」重锚（`fushi/lib/src/pages/implementations/reader_fushi/lookup.part.dart` `_highlightAndShowPopup` → `reanchorTopPopup`）。该 bbox 是被查词**全部**字形片段的并集（`reader_selection_scripts.dart` `highlightSelection`）。词被断在两页 / 两栏时，屏外上一页那段（贴页底）也被并进来，并集从页顶拉到页底；`calcPopupPosition` 的「绝不压词」（BUG-098）只能把弹窗塞进页底剩下的几十像素。
- **[x] ① 已修复** — `anchoredWordBounds`：只取与视口相交的片段；锚段 = 含点击点的片段（点词时 `selection.point` 记下点击点，键盘 / 手柄无点击点取第一段）；只并入交叉轴上距已并区间两行以内的片段（同栏折行的半个词仍并入，隔栏 / 隔页的不并；竖排交叉轴为 x）。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/hyphen_word_start_and_anchor_bug3664_test.{dart,js}` 的 anchor 组：翻页断词、双栏断词、无点击点、同栏折行、竖排相邻 / 远列、全在屏外六种。
- **备注**：真机未复测；翻页 / 滚动 / VN 三模式未逐一真机验证（滚动与 VN 下词只会折到相邻行，规则③保持旧的并集行为）。
