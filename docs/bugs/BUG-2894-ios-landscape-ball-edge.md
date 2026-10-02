## BUG-2894 · iOS 横屏应用内悬浮球不吸附屏幕侧边
- **报告**：2026-10-03（用户：fushi 的 iOS 端横屏状态下视频不会吸附侧边）
- **真实性**：✅ 真 bug。iPhone 17 Pro 模拟器打开视频（视频页锁横屏），应用内悬浮球收起后停在离屏幕右缘约 45pt 的黑边中间，没有贴边。实测 `MediaQuery.viewPadding = (61.6, 0, 61.6, 19.9)`：iOS 横屏左右安全区**对称**上报灵动岛深度，`displayFeatures` 为空。宿主 `fushi/lib/src/floating_ball/app_floating_ball_host.dart`（`build` 里的 viewport）把左右 inset 全部扣掉，球的停靠边 = 安全区内缘，没有灵动岛的那一侧也贴不到屏幕边。Android（`shortEdges`）只在刘海侧上报 inset，所以不受影响；竖屏左右 inset 为 0，所以只在横屏出现。
- **[x] ① 已修复** — iOS 原生 `FushiFloatingBall.swift` 在 `app.fushi.reader/floating_ball` 上新增 `sensorHousingEdge`，按 `UIWindowScene.interfaceOrientation` 换算外壳所在边（`landscapeRight` → 左，`landscapeLeft` → 右）。视口抽成纯函数 `appFloatingBallViewport`：外壳在左 / 右时，对侧的水平 inset 归零；未知时保持两侧都避让。宿主在 `initState` 与 `didChangeMetrics`（旋转）时重新取。模拟器复验：灵动岛在左时，右停靠球的包围盒右缘为 889.9（大于屏宽 869，外缩贴边）；灵动岛在右时仍避让右侧（827.9）。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/app_floating_ball_viewport_test.dart`：用实测横屏数值钉住外壳在左 / 在右 / 未知 / 竖屏 / Android 单侧 inset 五种视口，以及原生方向映射的源码守卫。
- **备注**：没有灵动岛的那一侧，球拖到最上 / 最下端时可能被屏幕圆角轻微裁到。Android 本来就不避让圆角，两端行为一致。
