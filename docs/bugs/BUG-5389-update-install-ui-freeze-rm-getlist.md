## BUG-5389 · 更新下载完成后交给安装器前窗口「未响应」：Restart Manager 查询在主 isolate 同步跑
- **报告**：2026-11-24（用户截图：更新弹窗「正在安装… 100%」，标题栏「Fushi (未响应)」）
- **真实性**：✅ 真 bug。根因 `packages/fushi_engine/lib/platform/desktop/windows_process_query.dart` 的 `windowsProcessesHoldingFiles` 在调用方 isolate 上同步走 FFI 调 `RmGetList`；调用方是 `fushi/lib/src/utils/misc/platform_updater.dart` 的 `queryWindowsLibmpvModuleHolders` / `queryWindowsGalHookModuleHolders`（经 `collectWindowsInstallerDiagnostics`，交接安装器前跑）。
- **[x] ① 已修复** — `windowsProcessesHoldingFile(s)` 改成只有异步入口，内部 `Isolate.run`，不留同步版本；两个调用方改 `await`。
- **[x] ② 已加自动化测试** — `fushi/test/platform/windows_process_query_test.dart`「BUG-5389：查询不在调用方 isolate 上同步执行」（真实 Windows 上：查询进行中，先排进事件队列的 Timer 能跑到）；原有 RM 真实系统用例全部改 await。
- **备注**：

### 证据

- 3.4.0-debug.32189（pid 193712）：安装包 meta 20:42:27 写完（下载完成），`WindowsInstaller.handoff` 20:44:03 才记。
- `hang_watchdog.log`：`20:44:03 pid=193712 main thread recovered after 95828 ms`。
- hang dump `hang-193712-537541671.dmp` 主线程栈（cdb）：`ntdll!NtQuerySystemInformation` ← `RstrtMgr!RmGetList` ← Dart JIT/AOT 帧 ← `flutter_windows` ← `user32!DispatchMessageWorker` ← `fushi`。即 Dart 在平台线程（Flutter Windows 的 UI 线程与平台线程合一）上同步调 `RmGetList`。
- `RmGetList` 平时约 1 s（BUG-2823 的实测），这次 96 s；它内部扫全机进程，耗时取决于系统状态，不受我们控制，所以不能留在 UI 线程上。

### 未覆盖

- 修复后在 UI 不再卡死，但交接安装器仍要等 RM 查询返回（它是 BUG-1459 / BUG-1675 硬中止的依据，不能跳过或超时放行）。期间弹窗停在「正在安装… 100%」，没有阶段提示；若 RM 慢成常态再考虑加「正在检查文件占用」阶段文案。
- 未在真机上复现 96 s 的慢查询（不可控的系统状态）；修复由类型签名（只剩 `Future` 入口）和事件循环测试保证。
