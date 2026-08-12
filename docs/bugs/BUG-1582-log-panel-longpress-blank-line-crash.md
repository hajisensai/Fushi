## BUG-1582 · 错误日志面板长按空行崩溃（选区端点空断言）
- **报告**：2026-08-12（用户贴出运行时报错，时间戳 `2026-08-12 19:33:43.327962`）
- **真实性**：✅ 真 bug，触发链完整且确定性；崩溃点在框架
  `packages/flutter/lib/src/widgets/scrollable.dart:1361`
  （`final SelectionPoint end = geometry.endSelectionPoint!;`）
- **[ ] ① 未修复** — 已补 widget 复现测试，但 4 个候选触发点**全部未复现**，
  根因假设被证伪（见下）。**不据未证实假设改代码。**
- **[x] ② 已加自动化测试** — `fushi/test/widgets/log_panel_longpress_no_selection_crash_test.dart`
  （4 条，钉「长按面板任何位置都不得抛异常」；当前全绿，作回归网）
- **备注**：与已修的 **BUG-694 同根不同调用点**。BUG-694 绕开的是「右键菜单锚点」
  那条路（app 自持 pointer-down 坐标）；本条走的是框架自己的
  `_ScrollableSelectionContainerDelegate`，app 够不着，必须消除触发条件。

### 用户栈（节选）

```
FlutterError: Null check operator used on a null value
#0 _ScrollableSelectionContainerDelegate._updateDragLocationsFromGeometries (scrollable.dart:1361)
#1 _ScrollableSelectionContainerDelegate.handleSelectWord (scrollable.dart:1389)
...
#11 SelectableRegionState._selectWordAt (selectable_region.dart:1525)
#12 SelectableRegionState._handleTouchLongPressStart (selectable_region.dart:1003)
```

### 2026-08-12 复核：下面那条「空行」根因链**已被证伪**，勿再据此改代码

写了 widget 复现测试
（`fushi/test/widgets/log_panel_longpress_no_selection_crash_test.dart`）逐个试了 4 个
候选长按点，**4 条全绿、一条都没复现**：

| 候选 | 结果 |
|---|---|
| 夹在两条可见行之间的空行 | 未复现 |
| 最后一行下方的空白区（无子节点包含该点） | 未复现 |
| 被视口裁掉一半的行（滚动后顶边只露一条缝） | 未复现 |
| 超视口长行的右端（ClipRect 外，BUG-925 同族坐标） | 未复现 |

**这个否定结论是硬的**：widget 测试跑在 **debug 模式**，框架那句
`assert(geometry.hasSelection)` 会真执行——只要条件成立就必然炸测试。没炸 =
这四条路上端点都不为 null。

**所以「多余空行 → `Text('')` 不注册 Selectable」这条推断只对了前半段**：多余空行
确实存在（`buf.writeln(stackTrace)` 给本已以 `
` 结尾的堆栈再补一个换行，仍是个
可独立清理的小瑕疵），但它**不是**崩溃触发条件。

**尚未排除的差异**（用户环境 vs 测试环境），下轮从这里查：
- 用户是 **Windows 桌面 + 触屏**；widget 测试默认 `TargetPlatform.android`。
- app 有**界面缩放**（浏览器式 zoom）——缩放层会改选区几何的变换矩阵，是端点求解
  失败的高嫌疑来源。
- 真实面板嵌在完整页面里（`error_log_page.dart`），祖先链比测试里的
  `MaterialApp/Scaffold` 复杂得多。

那 4 条测试**保留**：它们钉的是「长按日志面板任何位置都不得抛异常」这个不变式，
是真回归网，只是目前抓不到本 bug。

### 原始（已证伪）推断链

1. `error_log_service.dart` 的 `ErrorLogEntry.format()`：
   ```dart
   buf.writeln(stackTrace);   // ← stackTrace 本身已以 '\n' 结尾
   buf.writeln('─' * 60);
   ```
   Dart 的 `StackTrace.toString()` 末尾自带换行，`writeln` 再补一个 →
   **每条日志的堆栈与分隔线之间恒定多出一个空行**。
2. 日志面板（`fushi_material_components.dart`）`_splitLines(log) => log.split('\n')`
   把那个空行变成 `''`，`ListView.builder` 为它建 `Text('')`。
3. 空 `Text` 的 `RenderParagraph` 切不出任何 selectable fragment → 该行**不注册
   任何 Selectable**。
4. 长按落在这一行：框架 `MultiSelectableSelectionContainerDelegate._handleSelectBoundary`
   没有「正好包含该点」的子节点，退而选最近的一个并派发 `SelectWordSelectionEvent`，
   该子节点实际没选中任何内容 → `SelectionGeometry.hasSelection == false`。
5. `handleSelectWord` **无条件**调 `_updateDragLocationsFromGeometries()`
   （对照同文件 `handleSelectAll` 是有 `if (currentSelectionStartIndex != -1)` 守卫的），
   release 下 `assert(geometry.hasSelection)` 不执行 → `endSelectionPoint!` 抛空断言。

### 为什么不能只删那个多余的 `writeln`

删掉能消掉**当前**这个空行来源，但空行随时可能从别处再来（error 文本自身含
`\n\n`、被截断的 entry、未来新增的格式化分支）。真正的不变式是
**「面板不得渲染不产生 Selectable 的行」**，修复必须钉在这一层，并由测试守住。

### 候选修法（待验证后择一）

- A：空行改渲染成 `Text(' ')`（单空格有 fragment，能产出合法端点），保持行高不变。
- B：空行渲染成非 `Text` 的等高占位（不注册 Selectable），并实测框架在「整段
  没有可选子节点」时确实走 `currentSelectionEndIndex == -1` 早退。

两者都必须先有复现测试，再用变异实测证明守卫真的挡得住。

### 影响面

只影响错误日志面板的长按选词（触屏）。该 `FlutterError` 被全局错误处理捕获，
app 不退出，但选词失败且每次长按空行都会再刷一条错误日志（自噪声）。
