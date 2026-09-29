## BUG-2789 · 截屏识字点字后只有一层灰、查词卡画不出来
- **报告**：2026-09-29（用户：Android 悬浮球「截屏识字」点字后弹出的是一层灰色、没有任何作用的遮罩）
- **真实性**：✅ 真 bug，三星 Tab S9（Android 16，`2.8.0-debug.16172`）在 Chrome 日文维基页复现：选取层正常画出行框，点字后 `PopupDictFlutterActivity` 拿到焦点，但 `:popup` 引擎每帧抛 `type 'BoxParentData' is not a subtype of type 'StackParentData'`（`Positioned.applyParentData`），卡片整张画不出来，只剩透明关闭层 + 系统 dim。根因 `fushi/lib/src/pages/implementations/popup_dictionary_page.dart` `_buildPositionedCard` 带锚点分支：`LayoutBuilder` 的 builder 直接返回 `Positioned`——`LayoutBuilder` 本身是 RenderObject，子节点拿 `BoxParentData`，`Positioned` 只能做 `Stack` 的直接子节点。凡带 `anchorRect` 的入口（截屏识字点字、app 外悬浮字幕点字）都中招，自 2026-07-09（TODO-1352）起潜伏；原有测试只做源码扫描（`popup_anchor_placement_guard_test.dart`），从没真渲染过这条分支。
- **[x] ① 已修复** — 锚点分支改为 `Positioned.fill(LayoutBuilder(Stack([Positioned(卡片)])))`：外层 Stack 的直接子节点是 `Positioned.fill`，量尺寸后由自带的 Stack 承载定位后的卡片；卡片外的点击照常落到透明关闭层。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dictionary_page_test.dart`「anchored point-lookup renders the card beside the anchor, not a bare scrim」：真渲染带锚点 + 字幕窗矩形的分支，断言无异常、卡片有尺寸且落在避让矩形之下、点卡片外仍能关闭。修复前该用例以同一条 `StackParentData` 异常失败。
- **备注**：同一 PR 还给悬浮球加了「应用外查词」按钮（弹同一个独立查词窗）、系统球「查词」改为唤起主窗查词页、系统球「关闭」同步关掉设置里的「应用外」开关。
