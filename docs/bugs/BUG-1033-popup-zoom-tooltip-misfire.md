## BUG-1033 · 嵌套查词弹出时 A- 的「缩小查词字号」tooltip 自动弹出遮挡正文

- **报告**：2026-07-23（用户：截图 — 查词弹窗里做嵌套查词，第二层「フォロー」一弹出，左上角 `A-` 的「缩小查词字号」气泡自动冒出来，飘在第一层正文上）
- **真实性**：✅ 真 bug。根因两处叠加：
  - `hibiki/lib/src/utils/components/hibiki_icon_button.dart:299`（`_withTooltip`）—— 给全 app 每个纯图标按钮包 `Tooltip` 时没给 `waitDuration`，落到 Material 默认的 `Duration.zero`。而 Flutter 的 MouseTracker 每帧结束后会用**最后已知的光标位置**重新 hit-test，所以「光标一动不动、按钮新出现在它下面」也会触发 `onEnter` 并**立刻**弹气泡 —— 用户没做过任何悬停动作。
  - `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart:76`（`calcPopupPosition` → `placeAboveBelow`）—— 子弹窗锚成 `left = selectionRect.left` / `top = selectionRect.bottom + gap`，左上角紧贴被查词；而 `A-`/`A+` 固定钉在顶栏最左端。两者相乘的必然结果：嵌套查词的子层一弹出，`A-` 就落在用户刚点的那个词正下方，也就是光标停留处，于是零延迟气泡必现。

  锚定本身是 BUG-098（不盖住被查词）/ BUG-129（贴住父层里选中的词）的既有契约，不动；根因是「零延迟」，修在按钮组件这唯一出口。

  顺带查出第二个缺陷：`_buildZoomFontButton` 原先在 `HibikiIconButton` **外面又套了一层** `Tooltip`（`HibikiIconButton` 自己已包一层）。两层嵌套下更靠近 child 的内层先命中 hover，外层那句「Ctrl+滚轮也可缩放」**从来没机会显示** —— 桌面用户看到的一直是只有标签的单行气泡（正是截图那个），TODO-1353 想给的提示等于没给。

- **[x] ① 已修复** — commit `（见下方回填）`
  - `hibiki_icon_button.dart`：新增 `kIconButtonTooltipHoverDelay = 500ms`，`_withTooltip` 显式传 `waitDuration`。气泡只对**真实的悬停意图**作出反应；移动端长按触发路径（`TooltipTriggerMode.longPress`）不看此值，行为不变。
  - `dictionary_popup_layer.dart`：`_buildZoomFontButton` 去掉重复嵌套的外层 `Tooltip`，把带 hint 的完整 message 直接交给 `HibikiIconButton.tooltip`，收成一层 —— 同时真正兑现 TODO-1353 的 Ctrl+滚轮提示。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_zoom_ctrl_wheel_test.dart`（group `BUG-1033：子弹窗落到光标下时 A−/A+ 不得立刻冒气泡`）
  - **行为级复现**：先把鼠标停在 `A-` 将要出现的坐标上，再让弹窗在该坐标下出现，断言 100ms 内不得冒气泡；同时断言停够 `waitDuration` 后仍必须显示提示（不把功能弄丢）。已验证撤掉 `waitDuration` 该用例立刻变红。
  - **一层 Tooltip 守卫**：`A-`/`A+` 各只应有一层 `Tooltip`，且那唯一一层必须带 `dictionary_font_size_zoom_hint`（防止重复嵌套重新把 hint 挡掉）。
  - **源码守卫**：popup layer 不得再自建 `Tooltip`；`hibiki_icon_button.dart` 必须显式给 `waitDuration: kIconButtonTooltipHoverDelay`。
- **备注**：`HibikiIconButton` 是全 app 共用组件，改动影响所有纯图标按钮的 hover 气泡延迟（0 → 500ms），这正是修复意图。已跑全量 `flutter analyze`（0 issue）+ `flutter test`（12710 passed / 5 skipped）确认无连带破坏。截图那个**单行**气泡（无 hint）与平台无关，是 `HibikiIconButton` 内层气泡，故桌面/移动端同样受影响。桌面真机复测待办。
