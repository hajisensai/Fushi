import 'dart:ffi';
import 'dart:io' as io;

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _TerminateProcessNative =
    Int32 Function(IntPtr process, Uint32 exitCode);
typedef _TerminateProcessDart = int Function(int process, int exitCode);

/// 通过 Win32 `TerminateProcess(GetCurrentProcess(), exitCode)` 立即结束当前进程。
///
/// Windows 下直接调 `dart:io` 的 `exit(code)` 会进入 CRT `exit` ->
/// `KERNEL32!ExitProcess` -> `ntdll!RtlExitUserProcess` ->
/// `ntdll!LdrShutdownProcess`：内核先强杀除当前线程外的全部工作线程，再在持有
/// Loader Lock 的状态下逐个执行已加载 DLL 的 `DllMain(DLL_PROCESS_DETACH)` 与
/// `ucrtbase!execute_onexit_table`。第三方原生 DLL 若在静态析构里清理依赖线程池
/// 或 RPC 回调的对象（实测：`onnxruntime_providers_cuda.dll` 的
/// `onnxruntime::OneDsTelemetry` 析构调用 `WINHTTP!WinHttpCloseHandle` ->
/// `IPHLPAPI!CancelMibChangeNotify2` -> `WINNSI!NsiRpcDeregisterChangeNotificationEx`
/// -> `NtWaitForSingleObject`），会因回调线程已被提前杀死而永久死锁；同时进程退出码
/// 已被内核写成 `0`，连 `taskkill /F` 也会误判「没有运行此任务的实例」，而
/// `FushiSingleInstanceMutex` 仍被卡死主线程占用，导致后续无法再启动 Fushi。
///
/// 调用前必须已完成所有需要持久化的数据刷盘与关库（WAL checkpoint、`session_marker.json`
/// `clean: true` 带 `flush: true`）。非 Windows 平台或 Win32 调用失败时返回 `false`；
/// Windows 上调用成功时进程在内核态直接终止，不会返回。
bool terminateCurrentWindowsProcess(int exitCode) {
  if (!io.Platform.isWindows) return false;
  try {
    final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
    final _GetCurrentProcessDart getCurrentProcess = kernel32
        .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
          'GetCurrentProcess',
        );
    final _TerminateProcessDart terminateProcess = kernel32
        .lookupFunction<_TerminateProcessNative, _TerminateProcessDart>(
          'TerminateProcess',
        );
    final int currentProcess = getCurrentProcess();
    return terminateProcess(currentProcess, exitCode & 0xFFFFFFFF) != 0;
  } catch (_) {
    return false;
  }
}

/// 供 `AppExitCoordinator` 使用的跨平台进程退出分派器。
///
/// 在持久化刷盘完成后，Windows 优先使用 `TerminateProcess` 跳过
/// `DllMain(DLL_PROCESS_DETACH)` 卸载期死锁；仅在 Win32 调用失败或抛异常时回退到
/// [fallbackExit]。非 Windows 平台直接调用 [fallbackExit]。
void exitProcessForPlatform(
  int exitCode, {
  required void Function(int code) fallbackExit,
  bool? isWindows,
  bool Function(int code)? terminateWindowsProcess,
}) {
  final bool useWindowsFastTerminate = isWindows ?? io.Platform.isWindows;
  if (useWindowsFastTerminate) {
    final bool Function(int code) terminate =
        terminateWindowsProcess ?? terminateCurrentWindowsProcess;
    try {
      if (terminate(exitCode)) return;
    } catch (_) {
      // Win32 终止异常时回退到 fallbackExit，防止退出意图静默落空。
    }
  }
  fallbackExit(exitCode);
}
