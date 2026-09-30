## BUG-2793 · 应用外悬浮球吸边不正常、点击闪烁、旋转后消失、菜单与应用内不一致
- **报告**：2026-09-29（用户：应用外的悬浮球没正常吸附，点悬浮球会闪；手机旋转后就不见了；菜单有点丑，要做得和应用内一样）。2026-09-30 追加：加载视频时应用内悬浮球从屏幕中间动画回原位；应用内球要有关闭键（只收起这一次页面，离开自动恢复）。
- **真实性**：✅ 真 bug。真机 SM-X716B（Android，2560×1600）上用户装的 2.8.0-debug.16248 复现：
  - **旋转消失**：横屏时球窗 `x=2328`，锁竖屏（宽 1600）后 `dumpsys window` 仍是 `(2328,585)`，球整个在屏外。根因：位置存 px（`FloatingBallService.savePosition` → `PreferenceKeys.POS_X/POS_Y`），没有任何配置变化 / 显示变化时的重摆。
  - **吸边不准**：窗口是 `TYPE_APPLICATION_OVERLAY` 默认 `fitInsetsTypes = systemBars()`，x/y 原点在系统栏以内；`snapToEdge()` 却按 `WindowMetrics.getBounds()` 整屏算——两套坐标对不上（横屏导航栏在侧时尤其偏）。且吸附是瞬移，不像应用内那样外缩、动画。
  - **点击闪**：球与面板在同一个 `WRAP_CONTENT` 窗口里，展开时窗口先按旧 x 变宽，`rootView.post(this::snapToEdge)` 下一帧才挪回屏内（实测展开后窗口 x 2440→2328）；透明度也是一帧从 0.5 硬切到 1。录屏帧序列见验证记录。
  - **菜单不一致**：原生面板是黑底文字列表挂在球下方，应用内是球上方竖排的圆形图标按钮。
  - **加载视频球从中间飞回**：`lib/src/reader/reader_floating_ball.dart` 的 `AnimatedPositioned` 对**任何**位置变化都补间 220ms，进视频页沉浸式隐藏系统栏 / 横竖屏切换让视口一变，球就被动画拖一路。
- **[x] ① 已修复** —（PR 分支 `pr/system-floating-ball-fix`）
  - 几何抽成 `FloatingBallGeometry.java`，与 Dart `ReaderFloatingBallLayout` 同一套公式与常量；位置改存「停靠边 + 纵向比例」，`onConfigurationChanged` + `DisplayListener`（只在视口真的变了时）按新视口重摆。
  - 窗口统一用整块显示区坐标（`setFitInsetsTypes(0)` + `FLAG_LAYOUT_IN_SCREEN` + 刘海模式），视口 = 显示区扣系统栏与刘海（= 应用内 viewPadding）。
  - 球窗固定尺寸永不改大小；按钮在独立的按钮窗里按最终几何一次建好，展开 / 收起 / 吸附都做动画（280 / 190 / 220ms，错峰飞出，曲线同应用内）。
  - 按钮圆形图标：图标码位与主题色由 Dart 下发（与应用内同一颗 IconData、同一套 ColorScheme），字形取 app 自带的 Material Icons 字体，球面取同一张 `assets/meta/icon.png`。
  - 应用内球：位置补间只在拖动松手吸附时开；新增常驻「关闭悬浮球」键（最上），只收起当前这一页，离开该页自动恢复，不改设置。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/system_floating_ball_native_guard_test.dart`（原生几何常量 = Dart 常量、坐标系、固定尺寸球窗、停靠边 + 比例持久化与显示变化重摆）；`fushi/test/floating_ball/app_floating_ball_host_test.dart`（关闭键只收起这一页、对话框不算离开、原生图标 / 配色表）；`fushi/test/reader/reader_floating_ball_test.dart`（视口变化一帧落位、松手吸附仍有动画）。
- **备注**：真机验证用 `applicationIdSuffix ".balltest"` 并行安装（用户装机是 CI 签名，本机 debug key 不同，覆盖安装会要求卸载清数据——不做）。桌面端（Windows / macOS）应用外悬浮球另起分支实现。

### 2026-09-30 合并后审查修复（桌面应用外球，PR #1807 之后）

提交：`c4e8e1c465`（A–I）+ `de08aa059a`（H 返工：首版是空操作，见下）。分支 `fix/desktop-ball-review`。

- **A 触摸抢前台**：`fushi/windows/runner/floating_ball_window.cpp` 球窗 / 菜单窗过程只回 `WM_MOUSEACTIVATE → MA_NOACTIVATE`（修前 l.1073 / l.1174），触摸 / 触控笔按下的 `WM_POINTERACTIVATE` 落进 DefWindowProc（回 PA_ACTIVATE）。修：两处都 `case WM_POINTERACTIVATE: case WM_MOUSEACTIVATE: return OverlayNoActivateReply(message);`，与查词覆盖窗同一条策略（BUG-2788）。
- **B 启动结果被吞**：`fushi/windows/runner/flutter_window.cpp` 修前 l.2117 恒回 `EncodableValue(true)`；macOS `FushiDesktopFloatingBall.swift` 恒回 `true`。建窗 / D2D 失败时 Dart 仍记签名、以后不再重试。修：回 `Start()` / `ballPanel != nil` 的真实结果。
- **C 剪贴板查词锚点单位错**：`app_floating_ball_host.dart` 修前 l.361 把原生给的物理像素球矩形当逻辑 `anchorScreenRect` 传，高 DPI 下卡片偏位。修：包成 `GlobalLookupPhysicalPlacement(anchorScreenRect: anchor)` 走 `physicalPlacement`。
- **D 启停竞态**：修前 l.248 起的 `_syncSystemBall` 在 await（渲染图标 / 读球图 / 原生 start）期间被关掉，旧闭包回来仍把球起出来，且「关」只按签名判断。修：`_systemGeneration` 代数 + `_systemRequested`，每个 await 后 `stale()` 复核，`_stopSystemBall` 按「是否请求过」而非签名判断。
- **E 查词模块关闭仍给查词按钮**：`floating_ball_config.dart` 的 `availableIn` 与 host 修前 l.351 只按平台判 `popup_lookup`。修：新增必填 `lookupModuleEnabled`，桌面外球 `lookup` / `popup_lookup` 都随查词模块（`lookup` 也要门：模块关时 `_revealDictionary` 什么都不做）；设置页与 host 同读 `moduleVisibility.isEnabled(ModuleId.lookup)`，模块开关变动经 prefs 通知 → host 重同步。已知限制：会话中途开模块，`GlobalLookupController` 要下次启动才起，此时点应用外查词记错误日志 `floating_ball.popup_lookup`（不再静默）。
- **F 桌面分支零测试**：修前 host 测试 l.407 整组 `skip`。修：`floating_ball_config.dart` 加 `@visibleForTesting debugDesktopSystemBallPlatformOverride` + `desktopSystemBallActionTarget` 注入缝，补启停 / 位置 / 模块门 / 两条竞态 / start=false 重试 / 五种动作分发测试。
- **G 资源失败**：`desktop_system_ball_assets.dart` 修前 l.48 `endRecording()` 的 Picture 不 dispose、l.66 单个图标渲染失败炸整批、l.79 `catch (_)` 吞一切。修：Picture finally dispose、逐图标 try/catch 记日志、球图只 `on FlutterError` 记日志其余上抛。
- **H 拖动阈值不随 DPI**：修前 l.1091 用 `GetSystemMetrics(SM_CXDRAG)`（裸像素 4）。**首版（c4e8e1c465）改成 `GetSystemMetricsForDpi(SM_CXDRAG, dpi)` 是空操作**——实测它对 SM_CXDRAG 不缩放（96/120/144/192/288 DPI 恒回 4，同调用 CXICON 32→96 正常缩放），守卫还把空操作钉住了。返工（de08aa059a）：`MulDiv(GetSystemMetrics(SM_CXDRAG), dpi, USER_DEFAULT_SCREEN_DPI)`，守卫改钉该形式并禁 `GetSystemMetricsForDpi(SM_CXDRAG`。
- **I 位置两次写**：`preferences_repository.dart` 修前 l.775 停靠边与比例分两次 `setPref`。修：`setPrefs({...})` 单事务。

**测试**：`fushi/test/floating_ball/app_floating_ball_host_test.dart`（桌面组）、`desktop_system_ball_native_guard_test.dart`（新增，A/B/H 源码守卫）、`desktop_system_ball_assets_test.dart`、`floating_ball_test.dart`。`flutter analyze` 全量无问题；`flutter test test/floating_ball` exit 0 / +69；`test/settings` + `preference_keys_guard_test.dart` exit 0 / +593。

**变异实测**（先提交再变异，`git checkout` 还原）：C / D（两条竞态）/ E / G（两条）/ A / B / H（`GetSystemMetricsForDpi` 与「算了不用」两种变异）全部由对应测试抓红；F：把平台回落改成 `Platform.isLinux` 但尊重覆盖 → 桌面组 24 条照跑全绿，忽略覆盖 → 10 条红。

**构建 / 原生**：`flutter build windows --debug` exit 0（本机缺 ATL，按既有配方设 `CL` / `_LINK_`）；原生 ctest 全部 exit 0（含 activation_policy、floating_ball_geometry）。

**真机触摸验收**（隔离实例：`FUSHI_TEST_ROOT=%TEMP%\fushi_ball_touch_root`、`FUSHI_TEST_HIDDEN=1`、`FUSHI_TEST_ONSCREEN=1`，未碰用户生产实例；`InjectTouchInput` PT_TOUCH，144 DPI，前台记事本）：de08aa059a 构建上触摸球 → 前台仍记事本、菜单展开；触摸 popup_lookup 按钮 → 前台仍记事本、菜单收起，两步 PASS。
- **A 的负向对照未能区分**：删掉两处 `WM_POINTERACTIVATE` 重编后同一脚本前台也不丢（本机注入触摸下原症状不复现），故 A 的「触摸不抢前台」效果为 **implemented_unverified**，只有源码守卫与策略 ctest 兜底。
- **H 运行时不可用触摸验证**：触摸经系统提升成鼠标时抖动先被系统触摸 slop 吸收（144 DPI 下抖 8 px 仍判点击，修与不修一样），真正走到这条阈值的是鼠标 / 触控笔；本轮未注入鼠标（会动用户真实光标），H 运行时为 **implemented_unverified**，由守卫 + 变异兜底。
