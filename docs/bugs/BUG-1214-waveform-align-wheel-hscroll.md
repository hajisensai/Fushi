## BUG-1214 · 波形对轴放大视图鼠标滚轮不能左右平移时间轴

- **报告**：2026-07-28（用户：截图指「波形对轴」放大视图，「这里应该支持滚轮滚动左右」）
- **真实性**：✅ 真 bug。根因不在本仓，而在 Flutter 的轴取分量规则：
  `flutter/packages/flutter/lib/src/widgets/scrollable.dart:944-948`
  （`_pointerSignalEventDelta`）按 **Scrollable 自身轴**取 pointer signal 分量——横向取
  `scrollDelta.dx`、纵向取 `dy`，只有按住 `pointerAxisModifiers`（默认 Shift）**且**是
  物理鼠标时才翻轴。物理滚轮发的是 `(0, dy)`，所以任何横向滚动区**裸滚轮恒 delta=0、
  完全不响应**。

  本区雪上加霜：`hibiki/lib/src/media/video/subtitle_waveform_align_panel.dart` 的
  `_buildScrollableWaveform` 刻意**不**包 `HorizontalDragScrollable`（区内 cue strip 自带
  `onHorizontalDrag` 拖字幕块调延迟，放开滚动拖动会两个 `HorizontalDragGestureRecognizer`
  抢手势竞技场；豁免登记在 `hibiki/test/widgets/horizontal_drag_scroll_guard_test.dart`）。
  于是鼠标用户在这条几千像素宽的时间轴上**只剩拖底部滚动条**一条路——正是用户报的症状。

  连带更正：上述守卫测试的头注释断言横向滚动区「只能靠滚轮」，与 Flutter 实际行为相反，
  已在本次一并订正。

- **[x] ① 已修复** — 新增共享件 `WheelToHorizontalScroll`
  （`hibiki/lib/src/utils/misc/platform_utils.dart`，紧邻 `HorizontalDragScrollable`）：
  向 `GestureBinding.pointerSignalResolver` 登记，命中后调
  `ScrollPosition.pointerScroll(delta)`——与 Flutter 自身 `_handlePointerScroll` 同一条路径
  （正确更新 `ScrollDirection`、走物理钳制），不是自造 `jumpTo`。三条边界：
  - 只认 `PointerDeviceKind.mouse`（触控板两轴都能给，横向分量本就被 `Scrollable` 直接吃掉，
    翻轴会让纵向双指手势莫名横滚——与 Flutter 只对鼠标翻轴同源）；
  - 目标偏移被 clamp 后若没变化（已到头 / 内容没超出视口）就**不登记**，事件照常冒泡给
    外层，弹窗纵向滚动不被吞；
  - 事件派发内层优先，内层 `Scrollable` 已表态（触控板 dx、或 Shift 已翻轴）时本件的
    `register` 自动 no-op，不会双份滚动。
  接线点：`subtitle_waveform_align_panel.dart` 的 `_buildScrollableWaveform`，包在
  `Scrollbar` 外层。

- **[x] ② 已加自动化测试** — `hibiki/test/media/video/subtitle_waveform_align_panel_test.dart`
  两条 widget 行为测试（真发 `PointerScrollEvent` 过 binding，断言真实 `ScrollPosition`）：
  - `BUG-1214: mouse wheel pans the timeline horizontally (no delay change)`：
    先断言内容确实超出视口（否则用例空转），滚轮 +120 → `pixels == 120`，反向 -400 →
    clamp 回 0，且**延迟未被改动**（滚轮 ≠ 拖字幕块调轴）。回归判据：删掉
    `WheelToHorizontalScroll` 后 `pixels` 恒为 0。
  - `BUG-1214: non-mouse (trackpad) vertical scroll is left to the outer scrollable`：
    钉死「只对物理鼠标翻轴」这条边界。

- **[ ] ③ 真机未验** — 滚轮**手感**（惯性/步长/方向是否跟手）单测证明不了，需要在真实
  Windows 桌面用物理鼠标滚轮在放大视图里实滚。本轮**未做**：`hibiki/tool/run_windows_itest.ps1`
  跑的是 `integration_test`，其指针事件同样由 `WidgetTester` 合成，与已有的 widget 测试是
  **同一层**、不构成额外证据；真实滚轮要经 OS → engine → framework，离屏无焦点窗口收不到。
  已验的只到「framework 收到 PointerScrollEvent 后 ScrollPosition 真的动了且方向/钳制正确」。
  待用户或有物理设备的一轮补验，验完再勾。

- **备注**：修的是**这一处**接线。全仓其它横向滚动区（合集行、标签筛选栏等）同样吃不到
  裸滚轮，但它们都包了 `HorizontalDragScrollable`（鼠标可直接横拖），不属本 bug 范围；
  要推广只需在对应滚动件外再包一层 `WheelToHorizontalScroll`。
  面板提示文案 `video_subtitle_waveform_scroll_hint`（「横向拖动查看时间轴…」）未改——
  它仍然成立，改文案要动 17 个语言文件，与本修复解耦。
