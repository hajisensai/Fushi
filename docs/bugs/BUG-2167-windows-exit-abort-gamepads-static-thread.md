## BUG-2167 · Windows 每次退出 fail-fast 崩溃 0xc0000409：gamepads 全局对象析构 joinable std::thread
- **报告**：2026-09-06（排查 BUG-2166 时从 Windows 事件日志与崩溃转储中发现）
- **真实性**：✅ 真 bug。根因 `packages/gamepads_windows/windows/gamepad.cpp:14`
  （`Gamepads gamepads;` 静态存储期全局对象）+ `packages/gamepads_windows/windows/gamepad.h`
  的 `std::thread reaper_thread;` 成员，且修复前 `Gamepads` **没有析构函数**。

### 证据

Windows 应用程序事件日志（用户机，2026-09-06 09:32:53.762）：

```text
错误应用程序名称: fushi.exe，版本 2.2.4.13530
错误模块名称: ucrtbase.dll，版本 10.0.26100.7623
异常代码: 0xc0000409          ← Subcode 0x7 FAST_FAIL_FATAL_APP_EXIT
错误偏移: 0x00000000000a4ace  ← ucrtbase!abort+0x4e
```

崩溃转储 `%LOCALAPPDATA%\CrashDumps\fushi.exe.17436.dmp`（cdb `!analyze -v`）：

```text
FAILURE_BUCKET_ID: FAIL_FAST_FATAL_APP_EXIT_c0000409_ucrtbase.dll!abort

ucrtbase!abort+0x4e
gamepads_windows_plugin+0xa2ca
ucrtbase!execute_onexit_table+0x3d      ← 进程退出时跑 DLL 的静态析构/atexit 表
gamepads_windows_plugin+0x1006d
```

`CrashDumps` 目录里 2026-09-05 一天就有 4 份 `fushi.exe.*.dmp`（15:35 那份正对应上一次
应用内更新的交接时刻），说明这不是偶发。

### 根因

`Gamepads gamepads;` 是静态存储期全局对象，成员含 `std::thread reaper_thread`（在
`init()` 里启动，前提是机器上有 `GameInput.dll`）。`std::thread` 的析构函数对**仍
joinable** 的线程直接 `std::terminate()` → `abort()`。

停止线程的 `Gamepads::stop()` 只在 `~GamepadsWindowsPlugin()` 里调用，而 Fushi 的两条退出
路径最终都是 `exit(0)`：

- 更新交接 `fushi/lib/src/utils/misc/platform_updater.dart`
- 关窗 `fushi/lib/src/platform/desktop/desktop_lifecycle_service.dart`

`exit(0)` **故意**跳过 Flutter 插件析构（这是它存在的理由：尽快让出文件锁）。于是插件析构
函数永远不跑，`reaper_thread` 带着 joinable 状态活到 CRT 的 onexit 表 —— 每次退出必崩。

### 下游代价

崩溃进程被 WER 冻住数分钟不死（进程对象还在、句柄还开着），`FushiSingleInstanceMutex`
随之一直被持有。应用内更新链上 `fushi_update_launcher.exe` 的「等父进程退出」（120s）与
「等互斥量释放」（10s）因此双双超时（marker 实录 `parentExitObserved:false`，时间戳恰好是
startedAt + 120.001s），再叠加 BUG-2166 的安装器自杀，整次更新落空。

- **[x] ① 已修复** — 给 `Gamepads` 加析构函数（`gamepad.h` 声明 / `gamepad.cpp` 实现）：
  置 `reaper_stop` + `notify_all`，用 `WaitForSingleObject(native_handle(), 1000)` 做**有界**
  等待，等到了 `join()`、等不到 `detach()`。既不 `terminate` 也不卡死。
  刻意**不**调 `stop()`（它要 `UnregisterCallback(5s)` 并 join 可能停在 GameInput 锁里的轮询
  线程 —— 那是把崩溃换成卡死），也刻意不动轮询线程（它们的 `GamepadData` 是裸指针、本就不
  随本对象析构；置停止位反而会让它们在 CRT 已开始拆解时去跑 `neutralize_inputs`/`std::cout`）。
- **[x] ② 已加自动化测试** —
  `fushi/test/platform/gamepads_windows_exit_teardown_guard_test.dart`：钉住「全局对象 +
  `std::thread` 成员」这个成因前提，钉住析构函数存在、真的处置 `reaper_thread`、含
  `detach()` 兜底、且不调 `stop()`。变异实测（删掉 `~Gamepads();`）当场变红。
### 真机 A/B 验证（2026-09-06，本机 Windows 11 26200）

同一份 debug 构建、同一套流程（`FUSHI_TEST_HIDDEN=1` + 独立 `FUSHI_TEST_ROOT` +
独立 `FUSHI_WEBVIEW2_USER_DATA_FOLDER` 起进程 → 等 `FLUTTER_RUNNER_WIN32_WINDOW`
出现 → 静置 30s → `PostMessage(WM_CLOSE)` → 读**进程退出码**），只改析构函数一处：

| 版本 | 进程退出码 |
|---|---|
| 去掉 `~Gamepads()`（= 修复前的现状） | `-1073740791` = `0xC0000409` FAST_FAIL_FATAL_APP_EXIT |
| 带 `~Gamepads()`（本修复） | `0` |

退出码是比事件日志更直接的判据：fail-fast 会把 `0xC0000409` 原样变成进程退出码。
两次都跑了两遍，结果稳定。

- **备注**：验证用的是 debug 构建；release 构建的静态析构表布局相同，但未单独复测。
  另：本 bug 只在装有 `GameInput.dll` 的机器上触发（`init()` 里没有它就直接 return，
  reaper 从未启动）——没装的机器上退出一直是干净的，这也是它能长期潜伏的原因。
