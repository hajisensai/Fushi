## BUG-3411 · iOS 横屏视频字幕列表侧栏右侧整条安全区空着
- **报告**：2026-10-14（用户：iPhone 横屏截图「侧边栏一大块空着很浪费」「那个安全区」）
- **真实性**：✅ 真 bug。iOS 横屏把灵动岛深度**左右对称**报进安全区（实测各 61.6pt），不论灵动岛实际在哪一侧。字幕列表侧栏（`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` `_subtitleJumpSidePanel`）直接拿 `MediaQuery.paddingOf(context).right` 当内容右缩进，灵动岛在左侧（被画面那边吃掉）时右边照样空出一整条。原生其实已经按界面方向上报外壳边（`FloatingBallChannel.sensorHousingEdge` + `sensorHousingEdgeChanged` 推送，BUG-2911），但只存在悬浮球宿主（`fushi/lib/src/floating_ball/app_floating_ball_host.dart` `_sensorHousingEdge`）的私有 state 里，别的布局读不到。
- **[x] ① 已修复** — 外壳边抬成全应用共享的 `sensorHousingEdge`（`fushi/lib/src/platform/sensor_housing_edge.dart`），常驻的悬浮球宿主取值时同步写入；「只保留被挡那侧水平安全区」收成 `obstructedSafeInsets`，悬浮球视口与字幕列表侧栏共用。侧栏用 `ValueListenableBuilder` 监听（横屏左 ↔ 右翻转 180° 时安全区不变、只有外壳边变）。
- **[x] ② 已加自动化测试** — `fushi/test/platform/sensor_housing_edge_test.dart`：`obstructedSafeInsets` 三种外壳边的取值 + 宿主写共享值 / 侧栏监听并按它让位的接线守卫；既有 `fushi/test/floating_ball/app_floating_ball_viewport_test.dart` 覆盖悬浮球视口未变。
- **备注**：未在真 iPhone 上复测（本机无 iOS 真机）。剧集轨等其它贴右边的视频侧栏若也有同样留白，可改用同一个 `obstructedSafeInsets`。
