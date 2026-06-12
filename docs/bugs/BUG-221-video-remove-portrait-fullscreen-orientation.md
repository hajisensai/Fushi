## BUG-221 · 删除视频竖屏模式+双击暂停+返回手势直接退出
- **报告**：2026-06-12（用户：竖屏砍掉了吧？双击不是暂停而是竖屏；有两种竖屏模式快进暂停图标数量不同·一种能隐系统状态栏；切换方式诡异竖屏再回来就变；**视频竖屏模式删掉**；横屏返回手势返回成竖屏·再返回才退出视频）
- **真实性**：✅ 真 bug（三子问题同一病根：media_kit 全屏退出回调泄漏，移动端弹回竖屏）

### 子1：竖屏模式 = media_kit 默认全屏退出回调放开方向
- 窗口侧 `Video`（`hibiki/lib/src/pages/implementations/video_hibiki_page.dart` `_buildVideoBody`）改动前**未传** `onEnterFullscreen`/`onExitFullscreen` → 落 media_kit 默认。
- app 自建全屏路由 `_pushNeutralizedVideoFullscreen`（:2242）经 `stateValue.widget.onEnterFullscreen`（:2257）取的就是窗口侧 Video 这俩默认回调。
- media_kit `defaultExitNativeFullscreen`（`media_kit_video-2.0.1/lib/src/video/video_texture.dart:509-533`）移动端调 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual)` + `SystemChrome.setPreferredOrientations([])`（:518-519，**空列表放开全部方向含竖屏/倒置**）→ 设备转回竖屏 = 用户感知的「竖屏模式」。
- 两套显示态（页面横屏窗口态 vs media_kit fullscreen 态，底栏 ±10s 按钮数由 `_hasRoomyVideoBottomBar() = width>=600` 随横竖宽度不同）= 用户感知的「两种竖屏模式」。
- 进页 `_lockLandscapeForVideo`（:2951）锁横屏与上述退出回调写相反方向值 = **同一状态两个拥有者**，是病根。
- **桌面分支注意**（收尾时补漏）：`video_texture.dart:496-501/523-527` 桌面（Win/macOS/Linux）默认回调经 MethodChannel `Utils.Enter/ExitNativeFullscreen` 把 OS 窗口切真原生全屏（覆盖任务栏）；桌面分支不碰设备方向、无竖屏问题，**不能顺手 no-op 掉**否则砍掉桌面「全屏=OS窗口真全屏」（改动前桌面靠 media_kit 默认获得真全屏）。

### 子2：双击=竖屏 = app 自建双击全屏逻辑（移动端）
- `_handleVideoPointerUp`（:3896）在外层 `Listener.onPointerUp` 手动检测 `_videoDoubleClickInterval`(400ms) 内两次点击 → 改动前一律 `_toggleVideoFullscreen`。
- 移动端双击 → 进 media_kit 全屏路由 → 退出时 `setPreferredOrientations([])` 弹回竖屏。桌面虽已 `toggleFullscreenOnDoublePress:false`（:2480），但这条自建路径与 media_kit 内置无关、移动端照跑。
- media_kit 移动端控制条**单击只 toggle 控制条可见性**（`material.dart:682 onTap`，非 playOrPause），`MaterialVideoControlsThemeData` **无** `toggleFullscreenOnDoublePress` 字段、`seekOnDoubleTap` 默认 false → app 双击 listener 与 media_kit 移动端内置手势不冲突。

### 子3：两段式返回 = 横屏时全屏路由在栈顶
- 全屏路由（`_pushNeutralizedVideoFullscreen`）含 media_kit `_FullscreenInheritedWidgetPopScope`（`fullscreen_inherited_widget.dart`），第一次系统返回被它吞 → `onExitFullscreen` 退全屏回竖屏；第二次返回才命中页面 `PopScope`（`_handleBackOrExit` :2110）真退出。

### 根因修复（统一数据结构：视频期间方向恒横屏，唯一拥有者；移动端永不进全屏路由）
- 子1：窗口侧（:4132-4133）+ 全屏路由（:2324-2325）Video 显式传自定义 `_enterVideoNativeFullscreen`（:2986）/`_exitVideoNativeFullscreen`（:3009）——**移动端**进出全屏都只 `landscapeLeft/Right` + `immersiveSticky`，**永不 `setPreferredOrientations([])`**；**桌面**转调 media_kit 默认 `defaultEnterNativeFullscreen()`（:2987）/`defaultExitNativeFullscreen()`（:3010）保留 OS 窗口真全屏（桌面不碰设备方向）。
- 子2：`_handleVideoPointerUp` 双击分支按平台分流（:3949）——移动端双击 = `_controller.playOrPause()`，桌面保留 `_toggleVideoFullscreen`。
- 子3：移动端隐藏全屏按钮（`_buildFullscreenButton` :2399 `SizedBox.shrink`）+ 永不进全屏路由（`_toggleVideoFullscreen` 移动端 no-op :2236），横屏即唯一形态 → 返回只命中页面 `PopScope`（`_handleBackOrExit`）一次退出。桌面保留全屏路由不变。

- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`（前任完成子1移动端方向+子2双击+子3隐入口；收尾补子1桌面分支回归：enter/exit 桌面由 no-op 改为转调 media_kit 默认，保留桌面 OS 窗口真全屏）。提交：见本轮 commit。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_orientation_fullscreen_guard_test.dart`（源码静态守卫，10 test 全绿）：子1 两回调存在+移动端只横屏永不空列表+桌面转调默认+全文件无空列表；子2 移动端双击 playOrPause/桌面 toggle/桌面禁内置双击全屏；子3 移动端 no-op+隐按钮+返回经 _handleBackOrExit 不进全屏路由。撤修复任一处则对应 test 红。
- **备注**：needsDevice=True（横竖屏旋转/双击/系统返回手势须真机，桌面 no-op 与桌面真全屏须桌面验证）。只改 video_hibiki_page.dart（+守卫测试）。media_kit 跑不了 headless，方向/全屏/手势用源码守卫钉接线点。
