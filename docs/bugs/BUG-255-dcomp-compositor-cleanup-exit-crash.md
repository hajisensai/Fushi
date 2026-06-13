## BUG-255 · 进程退出时 dcomp Compositor::CleanupSession FailFast 崩溃（TODO-313 Family B）
- **报告**：2026-06-14（TODO-313 排查进程退出崩溃，cdb 分析多份 minidump）
- **真实性**：✅ 真 bug。根因 `packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h:59`（`compositor_` 等是 `inline static`，static storage duration）+ `in_app_webview_manager.cpp:44`（`compositor_ = graphics_context_->CreateCompositor()` 进程级全局 DirectComposition Compositor）。这是**退出时序崩溃**，**不是** FrameArrived UAF（那是 Family A / BUG-209，已由 TODO-305 第十修覆盖）。

### dump 真实崩溃签名（决定性证据）
多份 minidump（cdb 分析）崩溃签名一致：

```
ExceptionCode: e0464645  (CoreMessaging Abandonment FailFast)
CoreMessaging!Abandonment::Fail
  <- dcomp!Compositor::CleanupSession+0x54
  <- CompositorCommon::Destroy
  <- OnFinalRelease
  <- flutter_inappwebview_windows_plugin onexit(atexit execute_onexit_table)
  <- ntdll!RtlExitUserProcess
```

即：`compositor_` 的**最终 COM Release**（`OnFinalRelease` -> `CompositorCommon::Destroy` -> `dcomp!Compositor::CleanupSession`）跑在 **CRT atexit 表**（`execute_onexit_table`）里，由 `ntdll!RtlExitUserProcess` 触发。此时 `LdrShutdownProcess` 已经开始拆除进程，dcomp Compositor 依赖的 CoreMessaging / DispatcherQueue 已被半拆，`CleanupSession` 对半拆的 CoreMessaging 操作 -> `CoreMessaging!Abandonment::Fail` FailFast 中止进程。

### 根因
`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h` 把进程级共享单例声明为 `inline static`：
- `compositor_`（DirectComposition `ICompositor`）
- `graphics_context_`（D3D11 device/context + WinRT `IDirect3DDevice`）
- `dispatcher_queue_controller_`（WinRT `IDispatcherQueueController`，背后是 CoreMessaging）
- `rohelper_`（WinRT 运行时入口包装）

它们由首个 `InAppWebViewManager` 构造时一次性创建（构造里 `if (!rohelper_)` 守卫），跨所有 manager 实例共享。`inline static` 具有 **static storage duration**——其析构（含 `compositor_` 的最终 COM Release）由 CRT 在**进程退出**时通过 atexit/onexit 表执行，**而不是**在 `~InAppWebViewManager()` 里。

而 `~InAppWebViewManager()` 原本只 `clear()` 实例级的 `webViews`/`keepAliveWebViews`/`windowWebViews`，**故意不碰这组共享静态单例**（它们要跨实例复用）。结果就是没有任何代码在「受控时机」（UI 线程、DispatcherQueue/CoreMessaging 仍存活）释放 `compositor_`，最终 Release 被推迟到 atexit——这时 CoreMessaging 已开始拆除，`CleanupSession` FailFast。

**与 Family A（BUG-209）的区别**：Family A 是单个 WebView teardown 时在途 WGC `FirePresentEvent` 读已释放帧池的 null-delegate UAF（`0xc0000005` ACCESS_VIOLATION），崩在运行期、与查词弹窗 dispose 关联，由 TODO-305 第十修（texture_bridge.cc 帧池永久保活）覆盖。Family B 是**进程退出时**进程级全局 Compositor 的 finalize 时序问题（`e0464645` FailFast），与任何 WebView 是否还在无关，只在用户关闭 App 时触发。注：`codex/todo-178-win-shutdown` 只修了 Dart 侧更新检查 hang，没修这个 native dcomp 崩溃。

### 修复（受控退出时序，非吞异常）
在 DispatcherQueue 仍存活的**受控时机**显式释放共享单例，而非留给 atexit 表。`~InAppWebViewManager()` 在 Flutter engine/window 受控 teardown 期发生（UI 线程，DispatcherQueueController 仍持活、CoreMessaging 完整，`LdrShutdownProcess` 尚未开始）。

因共享静态由首个实例创建、跨实例复用（多 Flutter window 场景），引入 `instance_count_`（`inline static int`）：构造 `++`，析构 `--`，**只在最后一个 `InAppWebViewManager` 析构（计数归零）时**调用 `releaseSharedCompositionResources()`，在受控时机按 dcomp -> WinRT 依赖顺序释放：

1. `compositor_ = nullptr`（DirectComposition Compositor 先释放，触发 `CleanupSession`，此刻 CoreMessaging 仍完整 -> 不 FailFast）
2. `graphics_context_ = nullptr`（D3D11 device/context）
3. `dispatcher_queue_controller_ = nullptr`（CoreMessaging 最后释放，必须存活到 `compositor_` 的 `CleanupSession` 跑完）
4. `rohelper_ = nullptr`

这样 `compositor_` 的 `CleanupSession` 在 CoreMessaging 仍完整时确定性执行，atexit 时已无活引用、不再做 dcomp finalize，FailFast 窗口被确定性消除。安全性：`webViews`/`keepAliveWebViews`（消费 `compositor()`/`graphics_context()` 的下游 `CustomPlatformView`）在析构开头已全部 `clear()`，再释放共享单例；同 plugin 的 `HeadlessInAppWebViewManager`/`InAppBrowserManager` 经验证不引用这组共享资源（headless `createInAppWebViewEnv(..., willBeSurface=false)` 永不走 `createSurface`/`compositor()`）。

- **[x] ① 根因修复** —— `in_app_webview_manager.h`：新增 `instance_count_` + `releaseSharedCompositionResources()` 声明并注释 atexit 时序根因；`in_app_webview_manager.cpp`：构造 `++instance_count_`，析构在清空 webViews 后 `if (--instance_count_ <= 0) releaseSharedCompositionResources()`，按 dcomp->WinRT 顺序受控释放。提交哈希：见本轮提交。Windows debug 构建 √ Built 通过（native 编译零 error）。
- **[x] ② 自动化测试** —— 源码扫描守卫 `hibiki/test/widgets/dcomp_compositor_shutdown_guard_test.dart`：断言 `~InAppWebViewManager()` 在受控时机释放 `compositor_`/`graphics_context_`/`dispatcher_queue_controller_` 的逻辑存在（`instance_count_` 引用计数 + `releaseSharedCompositionResources()` 释放顺序 compositor 先于 dispatcher queue controller），防回归把释放退回 atexit。native 退出时序 host 单测跑不了，故用源码守卫钉死受控释放不变量。
- **备注**：这是**难验证的退出时序崩溃**。代码正确 + native 编译过 + 源码守卫绿后，仍需用户用新 build 真机**反复开关 App** 确认不再出现 `e0464645` 崩溃（若仍崩请提供新 dump）。host 测试无法复现进程退出 / `RtlExitUserProcess` / CRT atexit 时序。dump 用 cdb 分析。
