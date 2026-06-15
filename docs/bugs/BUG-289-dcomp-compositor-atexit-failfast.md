## BUG-289 · Windows 退出时 dcomp Compositor::CleanupSession FailFast（BUG-255 受控释放修复未生效）
- **报告**：2026-06-15（用户报「hibiki.exe - 系统错误 Exception Processing Message 0xc0000005 - Unexpected parameters」弹窗，未给崩溃时机/版本/dump）
- **真实性**：✅ 真 bug。**用户描述的 `0xc0000005` 是 Windows 在已崩溃后弹的系统泛化对话框文本，不携带模块/异常码信息**；本机 `%LOCALAPPDATA%\CrashDumps\` 有 6+ 份新崩溃 dump，cdb 分析签名**全部一致**，真实异常码是 **`e0464645`**（CoreMessaging Abandonment FailFast），即 BUG-255 的退出时序崩溃，**不是** 0xc0000005 ACCESS_VIOLATION。

### dump 决定性证据（cdb 分析，6 份签名逐字一致）
最新 dump `hibiki.exe.149336.dmp`（2026-06-15 12:25，版本 **0.8.3.4913**，构建时间 6/15 05:02 —— 已含 BUG-255 修复 commit `add68d660`（6/14 03:10））仍崩同一栈：
```
ExceptionCode: e0464645
KERNELBASE!RaiseFailFastException
  <- CoreMessaging!CFlat::Abandonment::Fail
  <- dcomp!Windows::UI::Composition::Compositor::CleanupSession+0x54
  <- dcomp!CompositorCommon::Destroy
  <- dcomp!...ContextRuntimeClass::OnFinalRelease_NoLock
  <- dcomp!...Compositor::Release+0x34
  <- flutter_inappwebview_windows_plugin!...(+0x44f7)   ← atexit lambda
  <- ucrtbase!execute_onexit_table
  <- ntdll!LdrShutdownProcess
  <- ntdll!RtlExitUserProcess
```
另 5 份（104196 / 89584 / 148884 / 153776 等）栈完全相同。

### 根因（BUG-255 的修复为何没拦住）
`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.h:72`（`compositor_` 等 `inline static` 进程级单例）+ `in_app_webview_manager.cpp` 析构里的受控释放。

BUG-255 把共享单例释放放在 `~InAppWebViewManager()`（计数归零时调 `releaseSharedCompositionResources()`），**赌「进程退出时该析构会在受控时机被调用」**。崩溃栈逐字反证这个赌注：`compositor_` 的最终 Release 直接发生在 `ucrtbase!execute_onexit_table`（CRT atexit）里，**栈中完全没有 `~FlutterInappwebviewWindowsPlugin` / `~InAppWebViewManager` / `releaseSharedCompositionResources` 帧**——证明退出时这些析构**根本没运行**。原因：`FlutterInappwebviewWindowsPlugin` 经 `registrar->AddPlugin(std::move(plugin))` 交给 Flutter registrar 持有，而 Flutter Windows 在进程退出路径上**不 tear down plugin registrar**，析构不被调用 → `compositor_` 这个 static com_ptr 一直持引用，直到 CRT 在 atexit 阶段析构静态变量本身时才做最终 Release → 此时 `LdrShutdownProcess` 已半拆 CoreMessaging → `CleanupSession` FailFast `e0464645`。与 BUG-209 前九修「赌在途 deferral 时机」同类——靠「析构会被调用」的时机赌注会输。

### 修复（不再赌析构，挂受控的 WM_DESTROY 钩子）
- **[x] ① 根因修复** —— `in_app_webview_manager.cpp` 构造里（首个实例创建共享单例后）经 `plugin->registrar->RegisterTopLevelWindowProcDelegate(...)` 注册 top-level window proc delegate，在 root Flutter window 的 **`WM_DESTROY`**（确定性受控时机：UI 线程、CoreMessaging 完整、`LdrShutdownProcess` 尚未开始）调用 `releaseSharedCompositionResources()`；delegate 返回 `std::nullopt` 不拦截消息。`releaseSharedCompositionResources()` 加 `composition_released_` 幂等守卫（WM_DESTROY 钩子与析构兜底任一先到都安全、只释放一次）。释放顺序仍为 dcomp Compositor → graphics_context → DispatcherQueueController → RoHelper（BUG-255 的顺序不变）。`in_app_webview_manager.h` 新增 `composition_released_` / `window_proc_delegate_id_` + BUG-289 根因注释。提交哈希：见本轮提交。
- **[x] ② 自动化测试** —— `hibiki/test/widgets/dcomp_compositor_shutdown_guard_test.dart` 追加 BUG-289 守卫：断言必须经 `RegisterTopLevelWindowProcDelegate` 在 `WM_DESTROY` 受控时机调 `releaseSharedCompositionResources`（不仅靠析构）、delegate 在 `CreateCompositor` 之后注册、`composition_released_` 幂等 flag 在真正释放之前早返回。`flutter test test/widgets/dcomp_compositor_shutdown_guard_test.dart` 2 用例绿（保留 BUG-255 既有守卫）。
- **验证**：①守卫测试绿 ②`flutter build windows --debug` 中 `flutter_inappwebview_windows_plugin.vcxproj` native 编译**通过**（无 error C，仅预存无关 C4244 warning；`RegisterTopLevelWindowProcDelegate` + 无捕获 lambda → `std::function` 签名逐字匹配 Flutter SDK `plugin_registrar_windows.h`）。整体 build 在 media_kit `mpv-dev` 7z 完整性/INSTALL 阶段失败，与本修复无关（预存环境问题）。
- **诚实标注的不确定点**：①这是难验证的退出时序崩溃，host 跑不了进程退出 / `RtlExitUserProcess` / CRT atexit，「能根治」是因果论证（WM_DESTROY 在 CoreMessaging 仍完整时确定性释放 compositor_，atexit 时已 no-op）。**需用户用新 build 反复开关 App 确认不再出 `e0464645`**（前修栽在「论证对了真机仍复发」，但本修把释放从「会输的析构赌注」改成了 Flutter 保证会触发的 WM_DESTROY，机理更硬）。②`RegisterTopLevelWindowProcDelegate` 的 delegate 在 root window WM_DESTROY 时被调用是 Flutter Windows 公开契约；若某些退出路径（如直接 TerminateProcess）不发 WM_DESTROY，析构兜底 + 幂等仍是双保险（但 TerminateProcess 不跑 atexit 也就不会 FailFast）。
- **采番**：本地工作区 bug.dart 取了 288，但某并发 worktree 分支已占 BUG-288 → 改号 289（遍历全分支 ls-tree 确认 289 空）。
