# Phase 2 — Windows 离屏后台集成测试 实施计划

> 测试流程重构（[2026-06-03-test-flow-refactor-design.md]）的 Phase 2。Phase 1（焦点驱动原语 + schema 全量「真生效」校验 + T4 生效探针）已落地。Phase 2 让**真实 Windows 桌面 app 能在后台被驱动测试**——不抢前台、不挡用户用电脑——从而把焦点驱动的 schema 覆盖 + reader 真机级验证跑在真 Windows app 上。

**Goal:** 在 Windows 上以离屏、不抢前台的方式运行真实 Hibiki 桌面 app，让集成测试驱动焦点/改设置/探 WebView DOM，验证桌面端「真生效」（含只有桌面能做的 T3 `getComputedStyle`）。

**Tech Stack:** Windows runner（C++ Win32）；`flutter test integration_test -d windows`；`integration_test` + `flutter_driver`；fork 的 `flutter_inappwebview_windows`（reader WebView）。

---

## Step 1 — runner 离屏 + 不抢前台（✅ 已完成）

**状态：✅ `31702fe32`，build + 运行时双验证通过。**

- `windows/runner/win32_window.cpp`：`CreateAndShow` 检测环境变量 `HIBIKI_TEST_HIDDEN`。设置时窗口创建在 `-32000,-32000`（离每块物理显示器都远，Windows 自己停靠最小化窗口的坐标）+ `WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`（无任务栏按钮、永不取前台）。**保留 `WS_VISIBLE`** 让 Flutter 引擎照常产帧（焦点驱动/布局/WebView 都需要引擎在跑），只是永远不在屏上。
- 验证：`flutter build windows --debug` 通过（`√ Built ...hibiki.exe`）；带 `HIBIKI_TEST_HIDDEN=1` 启动 → 进程存活、`GetForegroundWindow` 的进程 ≠ hibiki（`STOLE_FOREGROUND=False`）、无屏上窗口被枚举到。
- 为何不用纯 `SW_HIDE`：完全隐藏的窗口 Flutter 可能暂停渲染；离屏 + visible 保证引擎活着但用户看不到。

---

## Step 2 — Windows 桌面集成测试入口（驱动真实 app）

**Files:**
- Create: `hibiki/integration_test/desktop_settings_smoke_test.dart`（桌面版冒烟：app.main → 焦点驱动进设置 → 改一个 reading 设置 → 断言 `ReaderSettings`/`ReaderContentStyles.css` 真变）
- Create/Modify: `hibiki/tool/run_windows_itest.ps1`（PowerShell：`$env:HIBIKI_TEST_HIDDEN='1'` 后 `flutter test integration_test/<t> -d windows`；收集证据到 `.codex-test/`）

- [ ] **Step 2.1：写桌面冒烟集成测试**
  - 复用 Phase 1 的 `integration_test/helpers/focus_driver.dart`（`sendKeyEvent`，跨平台，OS 窗口焦点无关）+ `effect_probes.dart`（`ReaderCssEffectProbe` T1）。
  - 流程：`app.main()` 起真实 app（hidden runner）→ `FocusDriver.reachAll` 走到设置 → 用焦点驱动改「字号/行距」之一 → `ReaderCssEffectProbe` 断言 `ReaderContentStyles.css` 输出随之变（与 widget 层 `settings_schema_coverage_test` 同一探针，但这次跑在**真 app + 真初始化**上）。
  - 注意：真 app 初始化重（DB/词典/音频）。沿用 Phase 1 教训——若 live app 后台抛未捕获异步错误坏 binding，先按 BUG-005（reader live hook 已修 `a5b046c40`）核对，再看是否有新逃逸点。

- [ ] **Step 2.2：写 `run_windows_itest.ps1`**
  ```powershell
  $env:HIBIKI_TEST_HIDDEN = "1"
  flutter test integration_test/desktop_settings_smoke_test.dart -d windows --no-pub
  ```
  - 跑前确认无 `hibiki.exe` 占用（否则 LNK1168）。
  - 证据落 `.codex-test/itest-logs/`（不入库）。

- [ ] **Step 2.3：跑 + 留证**：`.\tool\run_windows_itest.ps1`，断言全绿；窗口全程不出现、不抢前台（用户可正常用电脑）。

---

## Step 3 — 桌面 T3 `getComputedStyle` 探针（reader WebView 真生效）

**Files:**
- Create: `hibiki/integration_test/helpers/dom_effect_probe.dart`（T3：经 `InAppWebViewController.evaluateJavascript` 读 `getComputedStyle`）
- Create: `hibiki/integration_test/desktop_reader_css_dom_test.dart`

- [ ] **Step 3.1：T3 探针**——给定一个已加载书的 reader WebView，改 reading 设置后注入 JS：
  ```js
  getComputedStyle(document.querySelector('.book-content')).fontSize
  ```
  断言改字号后 DOM 的 computed `font-size` 真变（这是 T1 纯函数探针**够不到**的最后一环：CSS 串确实被 WebView 应用了）。
  - 桌面专属：Windows 用 fork 的 `flutter_inappwebview_windows`，`evaluateJavascript` 可用；Android 模拟器也能做但桌面是 Phase 2 的主场。
- [ ] **Step 3.2：开一本分页书**（`book_entry_hoshi://book/<id>`，避免 lyrics-mode shelf 残留，见 [[reference_windows_reader_caret_lyrics_mode]]）→ 改设置 → T3 断言。
- [ ] **Step 3.3：跑 + 留证**。

---

## Step 4 —（Phase 3 预告）Mac 跨机分派

不在本计划，独立出 Phase 3 计划：Windows 当总指挥经 `ssh shfaifsj@192.168.1.34` + `sync_to_mac.ps1` 把同款集成测试分派到 Mac（macOS 同样需要 runner 离屏支持——`macos/Runner` 的 `MainFlutterWindow`，机制类似但 Cocoa：`HIBIKI_TEST_HIDDEN` 时 `orderOut:` / 设 `NSWindow.level` + 离屏 frame）。

---

## 验证与纪律
- C++ runner 改动：`flutter build windows --debug` 必须过 + 运行时确认不抢前台（Step 1 已做）。
- 集成测试：跑前确认无 `hibiki.exe` 占用；证据落 `.codex-test/`（不入库）。
- 只 stage 自己文件（[[project_concurrent_worker_develop]]）；`windows/runner/win32_window.cpp` 是非并发区，但 `windows/flutter/generated_*` 是生成文件勿手改。
- macOS 走 Cupertino 外壳，但 runner 离屏机制 Phase 3 再做，别在本阶段动 macOS。

## 自检
- Step 1 spec 覆盖：✅ 已实现 + 验证。
- Step 2-4：均给出文件路径 + 具体流程 + 复用 Phase 1 现成探针/原语，无「TODO/类似上面」占位；真 app 初始化重 + live 异步逃逸风险已点名（沿用 BUG-005 修法基线）。
- 风险：真 app 在 hidden runner 下若仍有未捕获异步错误坏 binding，是 Step 2 的主要拦路点——先复用 Phase 1 的 `settings_schema_coverage` widget 路径兜底，再逐步把覆盖搬到真 app。
