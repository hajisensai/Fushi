## BUG-237 · 书架卡片类型徽章应放在右上角（TODO-284）

- **报告**：2026-06-13（用户 TODO-284：把「有声书/书籍」类型标识放到卡片右上角，书名文字放封面下方）
- **真实性**：真需求/真错位。书架卡片当前把「有声书/书籍/视频/SRT」类型徽章放在封面**右下角**，与需求「右上角」不符。书名已在封面下方的 footer（TODO-243 已废弃旧的 `_titleOverlay` 叠封面方案），目标 B「文字在下方」现状已满足，无需改动。
- **根因**：`hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart:1245-1247`。`_bookCardLayout` 用 `Stack` 叠封面与徽章，徽章经 `PositionedDirectional(end: tokens.spacing.gap * 0.75, bottom: tokens.spacing.gap * 0.75, ...)` 钉在右下角。所有卡片类型（EPUB 书 ~1693、SRT ~929、视频 ~959、远程书 ~782）都把各自 `coverBadge` 传入这同一个 `_bookCardLayout`，徽章定位仅此一处统一控制。
- **[x] ① 已修复**：`reader_hibiki_history_page.dart` 把该 `PositionedDirectional` 的 `bottom: tokens.spacing.gap * 0.75` 改为 `top: tokens.spacing.gap * 0.75`，徽章移到封面右上角；`end` 不变（仍贴右侧）。一处改动对四种卡片类型统一生效。标题位置（footer Column）不动。
- **[x] ② 已加自动化测试**：`hibiki/test/pages/reader_bookshelf_card_layout_static_test.dart` 新增守卫「book type badge is pinned to the top-right corner of the cover」：断言 `_bookCardLayout` 内徽章用 `top: tokens.spacing.gap * 0.75` 定位、不再含 `bottom: tokens.spacing.gap * 0.75`、且全函数只有一个 `PositionedDirectional`（保证徽章定位集中、四种卡片共用一处）。原有 footer 布局守卫保持绿色。
- **备注**：用户口头说「换回原来的样子」，但旧中期布局徽章在标题行右侧（与封面同列下方），并非右上角。本次按 TODO-284 字面新需求（右上角 + 文字在下方）实现，不逐字复刻旧布局；旧的 `_titleOverlay`（叠封面标题）仍按 TODO-243 守卫禁止恢复。视觉效果待真机/桌面复测。
