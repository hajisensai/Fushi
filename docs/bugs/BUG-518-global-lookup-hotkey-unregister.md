## BUG-518 · Windows 应用外全局查词唤不出来（热键被全局 unregisterAll 误伤）
- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug（TODO-1086）。TODO-617 全局查词链路（Ctrl+Alt+D 热键 → 抓选区 FFI → 裸 WebView2 覆盖窗）已完整落地，native 层无「仅前台才建窗」gating；断点在 native 之前的 Dart 触发链——OS 级系统热键没能可靠注册/被误注销。查到两处独立于「哪个是触发点、都需修」的结构缺陷：

  1. **跨服务全局 unregisterAll 误伤（真正的注销源）** — `hibiki/lib/src/sync/desktop_lookup_service.dart:166` 的 `stop()` 调**全局** `hotKeyManager.unregisterAll()`。该服务是老的 Ctrl+Shift+D 剪贴板/热键查词，由 `home_dictionary_page` 挂载 `start()`。若它在覆盖窗热键（`GlobalLookupController` 的 Ctrl+Alt+D）注册后被 stop/restart（离开查词 tab / profile 切换等），全局 `unregisterAll()` 会连带把 Ctrl+Alt+D 一并注销，之后应用外按热键无反应。

  2. **注册失败静默吞** — `hibiki/lib/src/lookup/global_lookup_controller.dart:196-198` 覆盖窗热键 `register()` 失败时只 `glog()` 写临时诊断文件（`<temp>/hibiki_glookup.log`），不进用户可见的错误日志页、也不随复制/上传链路带走。热键被别的 app 占用、或初始化时序问题导致注册失败时，用户与开发者都看不到「唤不出来」的真正原因。

  另核实：`hibiki/lib/main.dart:151` 的 hotkey_manager 初始化 `unregisterAll()` **已在无条件桌面启动路径**（`if (isWindows||isLinux||isMacOS)` 内、`restartMarkerArg` 分支之外，自 `4e4c20e2e` 2026-06-07 引入即如此），满足 plugin 初始化契约，无需改动——只加守卫测试防回归。

- **[x] ① 已修复** — commit 见分支 `fix-1086-global-lookup-hotkey`：
  - `desktop_lookup_service.dart` `stop()`：全局 `unregisterAll()` → **per-hotkey** `hotKeyManager.unregister(_hotKey)`（只注销自己持有的 Ctrl+Shift+D），不再误伤其它服务的系统热键。
  - `global_lookup_controller.dart` 注册失败：除 `glog` 外，额外 `ErrorLogService.instance.log('GlobalLookupController.registerHotKey', ...)`，把失败记为用户可见 + 可上传的诊断项。
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_hotkey_guard_test.dart`（源码扫描守卫）：
  - 断言 `desktop_lookup_service.dart` 的 `stop()` **不再**调用全局 `hotKeyManager.unregisterAll()`，且调用了 per-hotkey `hotKeyManager.unregister(`。
  - 断言 `global_lookup_controller.dart` 注册失败路径把失败记进 `ErrorLogService`（可见诊断），不再只有 glog。
  - 断言 `main.dart` 的 hotkey_manager 初始化 `unregisterAll()` 在无条件桌面启动路径、**不在** `restartMarkerArg` 分支内（防回归到「仅重启进程才初始化 → 冷启动热键注册不可靠」）。
- **备注**：③ 热键 Ctrl+Alt+D 高冲突时换键/可配置属 UX 决策，未在本修复动（TODO-1066 已让该键从 shortcut registry 读、可在设置改；这里不改默认键）。真机 glog 取证（确认冷启动后 Ctrl+Alt+D 真能唤出、以及被 stop 后不再被注销）是 Category-A 后续，需 Windows 真机验证。
