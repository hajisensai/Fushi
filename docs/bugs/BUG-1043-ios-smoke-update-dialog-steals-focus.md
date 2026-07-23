## BUG-1043 · iOS冒烟测试焦点断言被启动期更新弹窗与恒真判定掩盖
- **报告**：2026-07-24（iOS 模拟器 iPhone 16 Plus / iOS 18.6 跑 `integration_test/app_smoke_test.dart` 失败：「First nav tab must be reachable by focus」；同测试 macOS / Android CI 通过）
- **真实性**：✅ 真 bug（测试基建双缺陷，app 行为均为设计内）。根因①：`hibiki/integration_test/helpers/focus_driver.dart:125`（`_focusOwns` 只排除 `FocusScopeNode`，不排除 skipTraversal key-sink）；根因②：`hibiki/integration_test/app_smoke_test.dart`（对真实网络的启动期更新检查不设防 + 未开焦点导航开关，Tab 实为 DoNothingIntent，见 `hibiki/lib/src/shortcuts/global_navigation.dart:357`）
- **[x] ① 已修复** — `_focusOwns` 增加 `f.skipTraversal` 排除；`UpdateChecker` 新增 `disableAutoCheckForTesting` 确定性 seam（`hibiki/lib/src/utils/misc/update_checker_release.dart`，`scheduleCheck` 入口短路），smoke 测试在 `app.main()` 前置位并按既有范式开启焦点导航开关、断言 tab 真实切换（提交随本 worktree `codex/mac-ios-test-20260723` 一并入库）
- **[x] ② 已加自动化测试** — `hibiki/test/integration/focus_driver_skip_traversal_guard_test.dart`（skipTraversal sink 持焦不得误报命中 + Tab 真实到达仍判定命中）；`app_smoke_test.dart` 本身新增「激活第二个 tab 必须真的切走 / 切回」断言，防断言再次退化为恒真
- **备注**：iOS-only 表象纯属环境竞速：只有该次 iOS 运行的更新检查真的拿到了 manifest 并弹窗；macOS/Android 的「通过」同样是恒真误报，并未真正检验焦点可达性。

### 症状

`flutter test integration_test/app_smoke_test.dart -d <iOS sim>`：
`FocusDriver.focusWidget(navTargets[1])` 报成功、`activate()` 后
`focusWidget(navTargets[0])` 80 步 Tab 内永远不可达，
app_smoke_test.dart:56 断言失败。macOS（`-d macos`）与 Android CI 通过。

### 根因（探针实测链条）

三个相互独立的事实叠加：

1. **Tab 从未真正工作**：smoke 测试未开「键盘/手柄焦点导航」实验开关
   （默认关），`wrapWithGlobalNavigation` 把 Tab/Shift+Tab 中和为
   `DoNothingIntent`（TODO-112，`global_navigation.dart:357`）。按 80 次 Tab
   焦点纹丝不动。
2. **恒真判定掩盖了 1**：HomePage 用 autofocus + skipTraversal 的整页
   `Focus`（`_keyboardFocusNode`，`home_page.dart:659-674`）做快捷键 sink，
   开机即持 primary focus，且是含底栏在内一切控件的祖先。
   `FocusDriver._focusOwns` 只排除 `FocusScopeNode`，于是「焦点还停在
   sink 上」对页内所有 target 立即误报命中——phase1 一步 Tab 没走就返回
   true，Enter 实际什么也没激活（探针证实 tab 从未切换、
   `homeShellTabNotifier` 恒为 home）。macOS/Android 的「通过」全靠这个
   误报。
3. **iOS 运行时更新弹窗抢走焦点，让 2 的误报失效**：HomePage 首帧
   postFrame 调 `UpdateChecker.scheduleCheck`（真实网络）。该次 iOS 运行
   检查成功（本机 build `1.2.0+890` 的 release sequence 低于线上 1.2.0），
   弹出「发现新版本」`DialogRoute<void>`（探针 dump：`跳过 | 下载`），其
   ModalScope 把 primary focus 收进对话框。此后 primary focus 不再是那个
   sink 祖先，`_focusOwns` 第一次开始真实判定——而 Tab 被中和/模态封锁，
   navTargets[0] 自然永不可达。失败落点在哪一步纯看网络竞速何时成功，
   故呈现「iOS 独有」。

事后 `cancelActiveCheck()` 无法根治弹窗竞态：`scheduleCheck` 又经一层
post-frame 才进 `_check` 登记中断令牌，home 首帧当口取消是 no-op；
`neverRemind` 是 `scheduleCheck` 调用时刻已捕获的参数，事后写偏好无效
（探针实测取消后弹窗照出）。

### 修复

1. `focus_driver.dart` `_focusOwns`：`f.skipTraversal` 的节点（键事件
   sink/chrome）不算拥有任何 target——Tab 遍历永远到不了它，它持焦不代表
   任何具体控件被聚焦。
2. `update_checker_release.dart`：新增 `@visibleForTesting static bool
   disableAutoCheckForTesting`，`scheduleCheck` 入口短路。集成测试与 app
   同 isolate，在 `app.main()` 之前置位即可确定性排除整轮检查（生产路径
   永不置位；既有 `fetchReleasesForTesting` seam 同范式）。
   加固：`scheduleCheck` 另检测 `WidgetsBinding.instance is!
   WidgetsFlutterBinding` 时自动短路——生产 `runApp` 的 binding 一定是
   `WidgetsFlutterBinding`，任何 flutter_test / integration_test binding 都
   不是其子类；逐测试置位旗标无法覆盖全部 71 个 itest（macOS 批实测
   `macos_shell_screenshot_test` 因未置位仍被真实网络更新检查炸掉），对新增
   测试也不设防，故在生产入口做类型判定一次性根除。
3. `app_smoke_test.dart`：`app.main()` 前置位上述旗标；home 就绪后按
   `game_management_ui_itest` 既有范式开启
   `setExperimentalFocusNavigationEnabled(true)` 再做焦点断言；激活后新增
   `homeShellTabNotifier` 真实切换/切回断言，杜绝断言再次恒真。

为什么这不是掩盖：Tab 中和（TODO-112）与更新弹窗都是设计内行为，缺陷在
测试对平台设计的错误假设与对真实网络的不设防；修复让断言第一次真正检验
「per-tab 焦点可达 + 激活生效」，检验强度只增不减。

### 验证

- iOS：`flutter test integration_test/app_smoke_test.dart -d <iPhone 16 Plus sim> --no-pub` → `+1: All tests passed!`（含新切换断言）。
- macOS 回归：`HIBIKI_TEST_HIDDEN=1 flutter test integration_test/app_smoke_test.dart -d macos --no-pub` → 通过。
- 守卫：`flutter test test/integration/focus_driver_skip_traversal_guard_test.dart` → 通过。
