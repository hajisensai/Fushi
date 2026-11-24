## BUG-5444 · Cupertino 首页编辑态主线程被占满（「一进编辑首页就卡死」）
- **报告**：2026-11-24（用户：「这个首页一旦启动编辑首页就容易卡死」；Windows debug `flutter run`，Cupertino / 玻璃设计）
- **真实性**：✅ 真 bug。实例在编辑态时主线程 5 s 内 CPU 4.94 s（100%）、约 60 fps 连续出帧、`semanticsEnabled=true`；80 个 VM 栈样本 60% 在 `PipelineOwner.flushSemantics`。三处根因叠加：
  1. `fushi/lib/src/pages/implementations/home_widget_grid.dart:861`（旧）：Apple 编辑态抖动 `AnimatedBuilder` + `Transform.rotate`，常驻 `repeat`。`RenderTransform` 变换一变就 `markNeedsSemanticsUpdate`，每帧每块组件整棵语义子树重算下发；块内容（虚线描边逐段 `extractPath`、封面烘焙面）逐帧整块重画；每帧还经网格 LayoutBuilder 重建。
  2. `fushi/lib/src/utils/components/glass/fushi_apple_bar_cluster.dart:77/188`、`fushi_glass_bars.dart:128`（旧）：顶栏玻璃钮经 liquid_glass 1.20 的 `GlassPinnedBarChrome` 渲染，它无条件挂 `OverlayPortal.overlayChildLayoutBuilder`；框架让这种构建器每帧重新布局并 `markNeedsSemanticsUpdate`，到应用根之间没有已建语义边界，于是任何连续动画期间每帧从应用根重走语义树。保活各 tab 合计 15 枚（实例里实测）。
  3. `fushi/lib/src/diagnostics/ui_activity_probe.dart:117`（旧）：要帧归因只对 `rescheduling: true` 沿用已知调用点；上面 15 个构建器每帧以 `rescheduling: false` 重注册同一回调，每帧抓 15 次整栈跑正则（修 1 后约占主线程 25%）。
  M3E 编辑态不抖、没有玻璃顶栏，不受影响（无常驻 ticker）。另：该实例每次热重载 38～66 s（1900 库），期间窗口无响应，是 debug 工具链本身，与编辑态无关。
- **[x] ① 已修复** — 抖动改成只在绘制层转动的 `HomeWidgetJiggle`（自身 repaint boundary、直接监听动画只 `markNeedsPaint`，不覆写 `applyPaintTransform`，布局 / 命中 / 语义按静止姿态；内容包 `RepaintBoundary`），关动效不抖不歪；顶栏玻璃钮改为直接用库最终渲染的 `GlassButtonGroup.icons`（`FushiAppleGlassBarButton`），不再挂 overlay portal；探针对已知具体调用点不再重抓栈，只知 `~` 的按 `kUiActivityStackSampleInterval` 节流重抓。热重载后实例 overlay 布局构建器 15→0、探针正则从栈样本里消失。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_widget_grid_jiggle_test.dart`（Apple 编辑态语义开着时 60 帧抖动：内容零重画 / 零重建 / 零语义更新、转角在变；M3E 与关动效 Apple 编辑态 pumpAndSettle 能停、无常驻帧）；`fushi/test/diagnostics/ui_activity_probe_test.dart` 两条重注册归账用例。
- **备注**：修完后未能在用户实例的编辑态复测（用户已切到音乐库页、窗口最小化，不代为操作）；顶栏玻璃钮换渲染路径后的外观需人眼复核。liquid_glass 上游可考虑只在有竖条时 `show()` 该 portal。
