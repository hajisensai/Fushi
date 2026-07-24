## BUG-1034 · 视频字幕列表当前行末行文字被裁掉一半
- **报告**：2026-07-23（用户：截图 — 字幕列表当前播放行「ホントは風紀委員なんてガラじゃないんだから」第二行的「ら」只露出上半截）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_jump_panel.dart:405`（修复前的 `_estimatedRowExtentForCue`）+ 同文件 `:950` 的 `itemExtentBuilder`
- **[x] ① 已修复** — 行高改真实测量、几何与渲染同源
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_row_extent_guard_test.dart`
- **备注**：见下

### 根因

字幕列表用 `ListView.builder` 的 `itemExtentBuilder` 给出行高。这个回调不是「提示」而是**硬约束**：
`SliverVariedExtentList` 按返回值给行一个 tight 高度约束，行内 `Row` / `RenderParagraph` 被压到该高度，
多出来的文本直接被裁掉。

而它返回的高度是**按字符数估算**的：

```dart
final int charsPerLine = (safeTextWidth / (_effectiveFontSize * 0.95)).floor();
lineCount += (length / charsPerLine).ceil();
final double textHeight = lineCount * _effectiveFontSize * 1.25;
```

这套估算复现不了 Flutter 的真实断行，至少三处系统性偏差：

1. **忽略 `textScaler`**：系统字体缩放 / 应用内「界面大小」放大后，真实字宽与行高都放大，估算仍按
   未缩放字号算 → 行数与行高双双低估。实测 1.3× 缩放下需要 68.5px 的行只给了 54.5px，裁掉 14px，
   正是截图里末行只露一半的量。
2. **字宽假设错**：全角日文字宽是 1em，估算按 0.95em 算，每行字数被高估；日文禁则还会把行首的小假名 /
   标点挤到下一行，实际行数只会更多。
3. **几何与渲染漂移**：估算里勾选框列按 44 算（实际 35.7 + 间隙 4）；收藏行左侧 3px 竖色条又把内容区
   挤窄 3px（估算按无色条算）。测量用的文本列宽与真实渲染宽度对不上，断行结果自然对不上。

一句话：一个近似公式冒充精确值，还被当成硬约束用。

### 修复

让行高**测量**与**渲染**同源，而不是继续调估算系数：

- 新增纯函数 `subtitleRowTextWidth(...)` 与一组几何常量，行内各列宽度只留这一个真值来源；
- `_rowExtentForCue` 改用 `TextPainter`，按与渲染完全相同的样式（含加粗）、文本列宽、`textScaler`
  真跑一次布局取 `painter.height`，再与行内其它子项（时间戳 / 动作图标 / 勾选框）取最大值；
- 结果按「文本 + 是否加粗」缓存，宽度 / 字号 / `textScaler` 变化时整体作废——`SliverVariedExtentList`
  每次布局都要遍历全部条目累加 `maxScrollExtent`，无缓存会把 `TextPainter` 跑进每一帧；
- 消除两处几何漂移：勾选框列用 `SizedBox.square(36)` 锁死；收藏行的 3px 竖色条改从左内缩里扣
  （5 + 3 = 8），内容起点与文本列宽不再随收藏状态变化（顺带消掉收藏时整行文字右移 3px 的抖动）；
- 保留 `56 × 字号档` 的最小行高（历史视觉密度），只抬高矮行，绝不压低内容。

### 测试

`hibiki/test/media/video/video_subtitle_row_extent_guard_test.dart`：

1. 换行长句在 `textScaler` 1.0 / 1.3 下，文本渲染高度不得小于按同宽同样式重排所需的高度（= 没被裁）。
   回退修复后该用例如实失败（`Expected: >= 68.5, Actual: 54.5`）。
2. 文本列渲染宽度必须等于纯函数 `subtitleRowTextWidth` 的返回值（有 / 无勾选框两种）。
3. 收藏行的左侧竖色条不得挤占文本列宽度。

附带调整：`video_subtitle_jump_panel_test.dart` 中 TODO-1200 那条窄面板断言的魔数下界 80 → 78
（勾选框列锁宽 36 后文本列少 0.3px，不影响该用例意图）。
