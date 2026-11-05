## BUG-4123 · ios-island-clipped-and-large-widget-overflow
- **报告**：2026-11-06（用户：iPhone 灵动岛展开态显示不全、紧凑态封面是一块灰方块；主屏「继续」大号小组件封面铺满整块、文字叠在一起）
- **真实性**：✅ 真 bug，三处根因：
  - 灵动岛紧凑态灰块：`fushi/apple/HomeWidgets/Extension/FushiLiveActivities.swift:191`（旧）`FushiPlatformImage.load(path)` 整张原图解码，Live Activity 的图片大于呈现区域时系统只画占位（展开态区域大才侥幸显示）。
  - 灵动岛展开态截断：同文件 `:36-44`（旧）底部区域放两行 16pt 原文 + 进度 + 44pt 控件行，超出展开态约 160pt 总高，系统截掉控件行。
  - 大号小组件溢出：`fushi/apple/HomeWidgets/Extension/FushiWidgetTimeline.swift:108-112`（旧）`FushiCoverImage` 用 `.aspectRatio(contentMode: .fill)` 后直接 clipShape，裁的是按原图比例撑大的自身；`FushiHomeWidgetViews.swift:319-339`（旧）`.frame(maxWidth: .infinity)` 只钉宽，封面溢出盖满整块组件。
- **[x] ① 已修复** — 封面统一用 ImageIO 按显示尺寸降采样（`FushiPlatformImage.load(_, maxPoint:)`），`.fill` 图先 `Color.clear` 吃父框再 overlay；灵动岛底部用紧凑版原文（一行）与矮一号控件；「继续」中 / 大号按主条目种类分版式（书 / 漫画 / 游戏竖版封面 + 右侧信息，视频横版整幅），次要条目缩略图按种类取比例，小屏放不下就少放一行（`ViewThatFits`），只有一条时主卡放大。
- **[x] ② 已加自动化测试** — `fushi/test/build/apple_widget_cover_layout_guard_test.dart`（源码守卫，钉住降采样入口、Color.clear 边界、灵动岛紧凑变体、按方向分版式）。本仓无 Swift 测试层；Mac 上用 swiftc 编小组件源码 + ImageRenderer 离屏渲染 6 种组合（大号书 / 视频 / 单条 / 小屏机型、中号书 / 视频）人工核对，iOS 模拟器 SDK typecheck 通过。
- **备注**：灵动岛的真实呈现只能在真机 / TestFlight 上看（ImageRenderer 渲染不了 Live Activity 外壳），待用户真机复核。
