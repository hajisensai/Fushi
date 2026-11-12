## BUG-4388 · 查词弹窗打开时点窗口最顶部关不掉弹窗
- **报告**：2026-11-12（用户：Windows 有声书歌词模式截图，弹窗开着点窗口最顶部没反应）
- **真实性**：✅ 真 bug。自绘标题行 `fushi/lib/src/utils/components/fushi_desktop_title_bar.dart`（`_buildCaptionControls` 的 `DragToMoveArea`）叠在整个 Navigator 之上；有声书歌词模式 / 音乐歌词页 / 游戏串流经 `FushiTitleBarDragBandScope` 把它变成常驻可命中的隐形拖动条（`_ImmersiveCaptionReveal.build` 的 `IgnorePointer(ignoring: !shown && !widget.dragBand)`）。页面里查词弹窗的 dismiss barrier（`fushi/lib/src/pages/base_source_page.dart` 的 `LookupDismissBarrier`）在顶部 32px 里命中不到，单击被拖动区吃掉。其它沉浸页标题行浮出时同理。
- **[x] ① 已修复** — 标题行拖动区外包 `_CaptionTapForwarder`：单击（非拖动、非双击）经 `FushiDesktopTitleBar.addCaptionTapListener` 转发全局坐标；`BaseSourcePageState._onCaptionTap` 在弹窗可见且本页是当前路由时走 `onDismissBarrierTap`（与点 barrier 同语义：阅读器命中词换词、空白关栈）。拖动拖窗口、双击最大化不变。
- **[x] ② 已加自动化测试** — `fushi/test/desktop/caption_tap_dismisses_lookup_test.dart`（真 `FushiDesktopTitleBar` + 隐形拖动条：单击转发、页面层收不到；拖动 / 双击不算单击；查词页接线源码守卫）。
- **备注**：单击要等双击判定超时（约 300ms）才关弹窗，与系统标题栏手感一致。未在真机肉眼复测。
