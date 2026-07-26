## BUG-1106 · `desktop_settings_smoke_test.dart`（Windows 离屏 itest 默认门）在全新 profile 上必红

- **报告**：2026-07-26（批次 11 真机验证时暴露；非本批引入，已失效约 6 周）
- **真实性**：✅ 真 bug（是**门失效**，不是产品缺陷）。实测输出：
  ```
  [desktop-settings] focus traversal reached 1 targets
  Expected: a value greater than or equal to <3>   Actual: <1>
  ```
  根因：`ae3229a6f`（2026-06-11，TODO-112 / BUG-196）在
  `hibiki/lib/src/shortcuts/global_navigation.dart:357-360` 把 Tab / Shift+Tab 在
  `experimentalFocusNavigationEnabled == false`（**默认关**）时中和成 `DoNothingIntent`，
  这是用户裁定的正确产品行为。而该 smoke 写于 2026-06-03、比这条改动早，从不打开这个开关；
  `hibiki/tool/run_windows_itest.ps1` 每次都起一个**全新隔离数据根**（隔离 APPDATA /
  LOCALAPPDATA / WebView2 profile），偏好永远是默认值，于是 `FocusDriver.reachAll()`
  一步也走不动，只返回起点那 1 个节点，`greaterThanOrEqualTo(3)` 必红。
  影响面：该文件是 `run_windows_itest.ps1` 的**默认目标**，也就是「跑一下 Windows 离屏
  itest」这个门本身——它红了约 6 周，等于这条门一直是坏的。
  同类问题在 `comprehensive_settings_test.dart` 已于 `dbb1f6c60`（2026-07-24）修过
  （加 `setExperimentalFocusNavigationEnabled(true)`），本文件被漏掉。
- **[x] ① 已修复**（提交 94c41c2fb）— `hibiki/integration_test/desktop_settings_smoke_test.dart:78-92`：
  `waitForHome` 之后、焦点遍历之前，按 `app_smoke_test` / `comprehensive_settings_test`
  的既有范式取 `ProviderScope.containerOf(...).read(appProvider)` 并
  `await appModel.setExperimentalFocusNavigationEnabled(true)` + pump 若干帧。
  改的是**测试前置条件**而非产品行为——Tab 中和是用户裁定的正确默认，不能为了让测试绿
  去动 `global_navigation.dart`。原地写了注释说明「删掉它这条门在全新 profile 上会重新变红」，
  防止以后又被当成冗余删除。
- **[x] ② 已加自动化测试** — 本条的「测试」就是**让这条门自己重新变绿**：
  `powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 -RunId smoke-fix-final`
  （在 `hibiki/` 下跑，默认目标）实跑通过，`exit code: 0`，输出
  `[desktop-settings] focus traversal reached 21 targets`（修复前是 1）+
  `effect changed=true` + `All tests passed!`；证据留在
  `hibiki/.codex-test/windows-itest/smoke-fix-final/command.log`（不入库）。
  不另加二级守卫：再套一层「断言测试里有这行」的源码扫描只是同义反复，真正的信号
  就是这条 itest 本身的绿灯。
- **备注**：全程走 `run_windows_itest.ps1` 的隔离数据根，未触碰生产库
  `D:\APP\HIBIKI_date\support\hibiki.db`。
