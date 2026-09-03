## BUG-2064 · iOS 截图分享缺 sharePositionOrigin 锚点导致 PlatformException
- **报告**：2026-09-03（用户：iPhone 横屏，视频页点截图，OSD 红条报
  `截图失败：PlatformException(error, sharePositionOrigin: argument must be set, {{0, 0}, {0, 0}} must be non-zero and within coordinate space of source view: {{0, 0}, {874, 402}}, null, null)`）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/misc/fushi_share.dart:71`（修复前）——
  `FushiShare.shareFiles` 调 `Share.shareFiles` 时**从不传 `sharePositionOrigin`**；
  改前全仓 `lib/` 里该参数出现 **0 次**（`grep -rn sharePositionOrigin fushi/lib packages/*/lib` 无输出）。
  share_plus 7.2.2 的 iOS 端把 text / uri / files 三条路径统一汇进
  `+ (void)share:` （pub-cache `share_plus-7.2.2/ios/Classes/FPPSharePlusPlugin.m:367`）：
  参数缺省时 `originRect = CGRectZero`（同文件 `:257`），随后 `:385` 的
  `CGRectContainsRect(controller.view.frame, origin)` 与 `CGRectIsEmpty(origin)`
  两道校验必然不过，直接 `result([FlutterError ...])`（`:394` 即用户看到的原文）。
  只要 `popoverPresentationController != NULL` 就会走这条分支——iPad 必然成立，
  用户的 iPhone 横屏（报错里的 `{874, 402}` = iPhone 16 Pro 横屏逻辑尺寸）同样成立。
  截图的移动端分支在 `fushi/lib/src/pages/implementations/video_fushi/clip_export.part.dart:336`
  调 `FushiShare.shareFiles`，因此必崩；同源缺陷也覆盖另外 11 处 `FushiShare.shareFiles`
  调用点（日志/崩溃转储/插图/备份/剪辑导出/有声书……）和 4 处裸 `Share.share(text)`。
- **[x] ① 已修复** — 把「iOS 必须有合法 popover 锚点」做成分享入口的**不变式**而非调用方可选参数：
  `FushiShare` 内部用 `ui.PlatformDispatcher` 解析当前 view 逻辑尺寸，
  经 `sharePositionOriginForViewSize()` 给出居中、边长 1 逻辑点、恒被 view 完全包含的
  锚点，`shareFiles` 与新增的 `shareText` 都自带它；不经 `WidgetsBinding`，
  所以没有 `BuildContext` 的平台 seam 也能用。同时把 4 处裸 `Share.share(text)`
  （`main.dart`、`creator/actions/share_action.dart`、`open_stash_dialog_page.dart`、
  `platform/selection_external_actions.dart`）收编进 `FushiShare.shareText` ——
  它们走的是同一个 iOS `+share:`，同样会崩，且分散入口正是「漏传一处就崩一处」的根源。
  非 iOS 平台的 share_plus 实现忽略该参数，无平台分支。
- **[x] ② 已加自动化测试** — `fushi/test/utils/fushi_share_reentrancy_test.dart`：
  在方法通道层断言 `shareFiles` / `share` 两条路径都带 `originX/originY/originWidth/originHeight`
  四个 key、rect 非空且完全落在 view 逻辑尺寸内（复刻 iOS 侧
  `CGRectIsEmpty` + `CGRectContainsRect` 两道校验）；纯函数
  `sharePositionOriginForViewSize` 的边界（零/负/非有限尺寸）单独覆盖。
  外加源码守卫 `fushi/test/utils/share_entry_point_guard_test.dart`：
  `lib/` 下除 `fushi_share.dart` 自身外禁止直接调 `Share.share*`，防新代码再绕过入口。
- **备注**：修复前 iPad 上**所有**分享（不只截图）都会命中同一异常；iPhone 竖屏
  多数场景 `popoverPresentationController` 为 nil 才侥幸没崩，所以此前没被发现。
