## BUG-4932 · iOS 主屏小组件深色模式底色比系统原生小组件灰亮
- **报告**：2026-11-16（应用内反馈 g0xmgCS2D5，iPhone19,2 / iOS 27.2，附截图：Fushi「继续」小组件底色约 `#2D2D2D`，原生提醒事项约 `#1C1C1E`）
- **真实性**：✅ 真 bug。根因 `fushi/apple/HomeWidgets/Extension/FushiWidgetTimeline.swift:221`：`fushiWidgetBackground()` 用 `.containerBackground(.fill.tertiary, for: .widget)`，`.fill.tertiary` 是给控件用的半透明填充（Xcode 小组件模板默认值），深色模式下叠出偏灰发白的底。自 29cae88ed8 首次引入小组件起未动过，不是设计取舍；7 个主屏小组件都走这个 helper。
- **[x] ① 已修复** — 底色改为系统背景 `.containerBackground(.background, for: .widget)`，与原生小组件同一块面；tinted / StandBy 的容器背景移除处理仍由系统接管。内部元素（进度轨道、热力图格、查词输入框）用的是 `.quaternary` 前景层级色，在更深的底上仍可见。
- **[x] ② 已加自动化测试** — `fushi/test/build/apple_widget_background_guard_test.dart`（源码扫描守卫：helper 用 `.background`；整个 `apple/HomeWidgets` 没有 `containerBackground(.fill…)`；每个 `StaticConfiguration` 都走 `fushiWidgetBackground()`）。
- **备注**：纯视觉像素差，Windows 上编不了 Swift；真机深色模式截图复测待补。
