// 本进程累计 CPU 时间（用户态 + 内核态，所有线程合计）：状态监测（[StatusMonitor]）
// 用两次读数之差除以墙钟时间得到 CPU 占用。
//
// - Windows：`GetProcessTimes`（kernel32，FILETIME 100 ns 单位）。
// - Android / Linux / macOS / iOS：`clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`（libc，纳秒）。
//   常量值各家不同：Linux / bionic = 2，Darwin = 12。
//
// 两种都是常数时间的内核计数读取，每秒调一次没有可测开销。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// `struct timespec`：tv_sec 是 time_t、tv_nsec 是 long，在本仓支持的 ABI 上都和 C long 同宽。
final class _Timespec extends Struct {
  @Long()
  external int tvSec;
  @Long()
  external int tvNsec;
}

typedef _ClockGettimeNative =
    Int32 Function(Int32 clock, Pointer<_Timespec> tp);
typedef _ClockGettimeDart = int Function(int clock, Pointer<_Timespec> tp);

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _GetProcessTimesNative =
    Int32 Function(
      IntPtr process,
      Pointer<Uint64> creation,
      Pointer<Uint64> exit,
      Pointer<Uint64> kernel,
      Pointer<Uint64> user,
    );
typedef _GetProcessTimesDart =
    int Function(
      int process,
      Pointer<Uint64> creation,
      Pointer<Uint64> exit,
      Pointer<Uint64> kernel,
      Pointer<Uint64> user,
    );

/// 读一次累计 CPU 时间（微秒）的实现；平台不支持时为 null。
typedef ProcessCpuTimeReader = int Function();

ProcessCpuTimeReader? _reader;
bool _resolved = false;

ProcessCpuTimeReader? _resolve() {
  if (_resolved) return _reader;
  _resolved = true;
  try {
    if (Platform.isWindows) {
      final DynamicLibrary k32 = DynamicLibrary.open('kernel32.dll');
      final _GetCurrentProcessDart currentProcess = k32
          .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
            'GetCurrentProcess',
          );
      final _GetProcessTimesDart getProcessTimes = k32
          .lookupFunction<_GetProcessTimesNative, _GetProcessTimesDart>(
            'GetProcessTimes',
          );
      _reader = () => using((Arena arena) {
        final Pointer<Uint64> creation = arena<Uint64>();
        final Pointer<Uint64> exit = arena<Uint64>();
        final Pointer<Uint64> kernel = arena<Uint64>();
        final Pointer<Uint64> user = arena<Uint64>();
        if (getProcessTimes(currentProcess(), creation, exit, kernel, user) ==
            0) {
          throw StateError('GetProcessTimes failed');
        }
        // FILETIME 单位 100 ns。
        return (kernel.value + user.value) ~/ 10;
      });
    } else if (Platform.isAndroid ||
        Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isIOS) {
      final int clockId = Platform.isMacOS || Platform.isIOS ? 12 : 2;
      final _ClockGettimeDart clockGettime = DynamicLibrary.process()
          .lookupFunction<_ClockGettimeNative, _ClockGettimeDart>(
            'clock_gettime',
          );
      _reader = () => using((Arena arena) {
        final Pointer<_Timespec> ts = arena<_Timespec>();
        if (clockGettime(clockId, ts) != 0) {
          throw StateError('clock_gettime(CLOCK_PROCESS_CPUTIME_ID) failed');
        }
        return ts.ref.tvSec * 1000000 + ts.ref.tvNsec ~/ 1000;
      });
    }
  } on Object {
    _reader = null;
  }
  return _reader;
}

/// 本进程累计 CPU 时间（微秒）；平台不支持或符号解析失败返回 null。系统调用失败抛
/// [StateError]（调用方把这一项记成取不到，不吞成 0%）。
int? processCpuTimeMicros() => _resolve()?.call();
