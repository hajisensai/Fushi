// 本进程各线程的累计 CPU 时间与线程名：状态监测（[StatusMonitor]）用两次读数之差回答
// 「CPU 是谁吃的」——Flutter UI 线程（Dart 代码 / 构建 / 布局）、光栅线程（绘制）、
// mpv、Rust 核心、Dart 后台 isolate……
//
// - Windows：Toolhelp32 线程快照筛出本进程线程 → `OpenThread` + `GetThreadTimes`；
//   线程名 `GetThreadDescription`（Win10 1607+，取不到就当未命名）。
// - Android / Linux：`/proc/self/task/*/stat`（[readProcThreads]，与内存归因探针同源）。
// - macOS / iOS：mach `task_threads` + `thread_info(THREAD_EXTENDED_INFO)`（带 pthread 名）。
//
// 一次读取要遍历全部线程（Windows 的快照还包含全机线程），几毫秒级，调用方须放后台
// isolate（[readThreadCpuTimes] 是纯同步的顶层函数，可直接交给 `Isolate.run`）。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/diagnostics/native_attribution_probe.dart';

/// 一条线程的读数。[id] 只在本进程内、该线程存活期间稳定（用来对齐前后两次读数）。
@immutable
class ThreadCpuTime {
  const ThreadCpuTime({
    required this.id,
    required this.name,
    required this.cpuMicros,
  });

  final int id;

  /// 线程名；未命名为空串。
  final String name;

  /// 累计 CPU（用户态 + 内核态，微秒）。
  final int cpuMicros;
}

/// Dart 主 isolate 所在线程在读数里的名字（各平台统一，归类为 [ThreadKind.flutterUi]）。
/// Windows 上引擎线程不设线程名，Apple 上主线程也没名字，靠 [uiThreadId] 认出来。
const String kMainIsolateThreadName = 'main.ui';

/// 读本进程全部线程；平台不支持返回空表。单条线程读失败（刚退出 / 无权限）跳过。
/// [uiThreadId]（主 isolate 上取的 [currentThreadId]）对应的线程改名为
/// [kMainIsolateThreadName]。
List<ThreadCpuTime> readThreadCpuTimes({int? uiThreadId}) {
  final List<ThreadCpuTime> raw;
  if (Platform.isWindows) {
    raw = _readWindowsThreads();
  } else if (Platform.isAndroid || Platform.isLinux) {
    raw = <ThreadCpuTime>[
      for (final MapEntry<int, ProcThreadStat> e in readProcThreads().entries)
        ThreadCpuTime(
          id: e.key,
          name: e.value.name,
          cpuMicros: e.value.ticks * (1000000 ~/ kProcClockTicksPerSecond),
        ),
    ];
  } else if (Platform.isMacOS || Platform.isIOS) {
    raw = _readMachThreads();
  } else {
    return const <ThreadCpuTime>[];
  }
  if (uiThreadId == null) return raw;
  return <ThreadCpuTime>[
    for (final ThreadCpuTime t in raw)
      t.id == uiThreadId
          ? ThreadCpuTime(
              id: t.id,
              name: kMainIsolateThreadName,
              cpuMicros: t.cpuMicros,
            )
          : t,
  ];
}

/// 调用方所在 OS 线程的 id，与 [readThreadCpuTimes] 的 [ThreadCpuTime.id] 同一编号：
/// Windows `GetCurrentThreadId`，Android / Linux `gettid`，Apple
/// `pthread_mach_thread_np(pthread_self())`。取不到返回 null。
int? currentThreadId() {
  try {
    if (Platform.isWindows) {
      return DynamicLibrary.open(
        'kernel32.dll',
      ).lookupFunction<Uint32 Function(), int Function()>(
        'GetCurrentThreadId',
      )();
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.process()
          .lookupFunction<Int32 Function(), int Function()>('gettid')();
    }
    if (Platform.isMacOS || Platform.isIOS) {
      final DynamicLibrary lib = DynamicLibrary.process();
      final int self = lib.lookupFunction<IntPtr Function(), int Function()>(
        'pthread_self',
      )();
      return lib.lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
        'pthread_mach_thread_np',
      )(self);
    }
  } on Object {
    return null;
  }
  return null;
}

/// 一组线程（同名去掉数字后归为一组）在一个窗口里的 CPU 占用。
@immutable
class ThreadGroupUsage {
  const ThreadGroupUsage({
    required this.group,
    required this.threads,
    required this.percentOfOneCore,
  });

  /// 归组名（数字折成 `#`），未命名线程为空串。
  final String group;

  /// 组里线程数。
  final int threads;

  /// 单核口径：100% = 一个核跑满（一组多线程可以超过 100%）。
  final double percentOfOneCore;
}

/// 两次读数之差按线程组汇总，按占用降序，去掉零占用。新出现的线程只算它在窗口内可能的
/// 部分：取它的累计，但不超过墙钟（刚建的线程累计就是窗口内的；窗口前就有、上次没读到的
/// 不会多算成几十秒）。
List<ThreadGroupUsage> summarizeThreadCpu(
  List<ThreadCpuTime> previous,
  List<ThreadCpuTime> current, {
  required int wallMicros,
}) {
  if (wallMicros <= 0) return const <ThreadGroupUsage>[];
  final Map<int, ThreadCpuTime> before = <int, ThreadCpuTime>{
    for (final ThreadCpuTime t in previous) t.id: t,
  };
  final Map<String, (int micros, int threads)> groups = <String, (int, int)>{};
  for (final ThreadCpuTime now in current) {
    final ThreadCpuTime? old = before[now.id];
    final int delta = old != null && old.name == now.name
        ? now.cpuMicros - old.cpuMicros
        : (now.cpuMicros < wallMicros ? now.cpuMicros : wallMicros);
    final String g = threadGroupOf(now.name);
    final (int, int) acc = groups[g] ?? (0, 0);
    groups[g] = (acc.$1 + (delta > 0 ? delta : 0), acc.$2 + 1);
  }
  final List<ThreadGroupUsage> out = <ThreadGroupUsage>[
    for (final MapEntry<String, (int, int)> e in groups.entries)
      if (e.value.$1 > 0)
        ThreadGroupUsage(
          group: e.key,
          threads: e.value.$2,
          percentOfOneCore: e.value.$1 / wallMicros * 100,
        ),
  ]..sort((a, b) => b.percentOfOneCore.compareTo(a.percentOfOneCore));
  return out;
}

/// 线程组的来源类别（页面上翻成人话）。
enum ThreadKind {
  /// Flutter UI 线程：Dart 主 isolate（业务代码、build、布局）。
  flutterUi,

  /// Flutter 光栅线程：把图层画上屏（Impeller）。
  flutterRaster,

  /// Flutter IO 线程：图片解码、资源加载。
  flutterIo,

  /// Dart 后台 isolate / `compute` / 异步 FFI。
  dartWorker,

  /// 视频播放（mpv / ffmpeg）。
  video,

  /// Rust 原生核心（rayon / tokio / fushi-*）。
  rust,

  /// Flutter 引擎里没有线程名的线程（Windows 按入口模块 `flutter_windows.dll` 认出：
  /// 光栅、IO、Dart 后台线程都在这里）。
  flutterEngine,

  /// 系统线程池（Windows 入口在 ntdll / kernel32 等系统模块）。
  system,

  /// 未命名线程（多为系统线程池、第三方原生库）。
  unnamed,

  /// 其它有名字但认不出的线程。
  other,
}

/// 按线程（组）名判类别。名字形态：Android `1.ui`；Apple `io.flutter.1.ui`；主 isolate
/// [kMainIsolateThreadName]；Rust 线程由 crate 自己命名；Windows 上没有线程名的按入口
/// 模块记成 `[模块名]`（见 [_readWindowsThreads]）。
ThreadKind classifyThread(String group) {
  final String n = group.toLowerCase();
  if (n.isEmpty) return ThreadKind.unnamed;
  if (n.startsWith('[') && n.endsWith(']')) return _classifyModule(n);
  if (RegExp(r'(^|\.)ui$').hasMatch(n)) return ThreadKind.flutterUi;
  if (RegExp(r'(^|\.)raster$').hasMatch(n)) return ThreadKind.flutterRaster;
  if (RegExp(r'(^|\.)io$').hasMatch(n)) return ThreadKind.flutterIo;
  if (n.startsWith('dartworker') || n.contains('dart:')) {
    return ThreadKind.dartWorker;
  }
  if (n.contains('mpv') || n.contains('ffmpeg') || n.contains('av:')) {
    return ThreadKind.video;
  }
  if (n.startsWith('rayon') ||
      n.startsWith('tokio') ||
      n.startsWith('fushi') ||
      n.contains('rwkv')) {
    return ThreadKind.rust;
  }
  return ThreadKind.other;
}

/// Windows 线程入口模块（小写、带方括号、数字已折成 #）的类别。
ThreadKind _classifyModule(String module) {
  final String m = module.substring(1, module.length - 1);
  if (m.startsWith('flutter')) return ThreadKind.flutterEngine;
  if (m.contains('mpv') ||
      m.startsWith('av') ||
      m.startsWith('sw') ||
      m.contains('ffmpeg')) {
    return ThreadKind.video;
  }
  if (m.startsWith('fushi_') || m.contains('rwkv')) return ThreadKind.rust;
  const List<String> system = <String>[
    'ntdll.dll',
    'kernel32.dll',
    'kernelbase.dll',
    'combase.dll',
    'rpcrt4.dll',
    'ucrtbase.dll',
    'msvcrt.dll',
    'user32.dll',
    'win32u.dll',
    'dxgi.dll',
    'd3d11.dll',
  ];
  if (system.contains(m)) return ThreadKind.system;
  return ThreadKind.other;
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

/// `THREADENTRY32`（tlhelp32.h）。
final class _ThreadEntry32 extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  external int cntUsage;
  @Uint32()
  external int th32ThreadID;
  @Uint32()
  external int th32OwnerProcessID;
  @Int32()
  external int tpBasePri;
  @Int32()
  external int tpDeltaPri;
  @Uint32()
  external int dwFlags;
}

const int _th32csSnapThread = 0x00000004;
const int _threadQueryLimitedInformation = 0x0800;
const int _threadQueryInformation = 0x0040;

/// `THREADINFOCLASS.ThreadQuerySetWin32StartAddress`。
const int _threadQuerySetWin32StartAddress = 9;

/// `GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT`。
const int _moduleFromAddressNoRef = 0x4 | 0x2;

final class _Win32Threads {
  _Win32Threads(DynamicLibrary k32)
    : snapshot = k32
          .lookupFunction<
            IntPtr Function(Uint32, Uint32),
            int Function(int, int)
          >('CreateToolhelp32Snapshot'),
      first = k32
          .lookupFunction<
            Int32 Function(IntPtr, Pointer<_ThreadEntry32>),
            int Function(int, Pointer<_ThreadEntry32>)
          >('Thread32First'),
      next = k32
          .lookupFunction<
            Int32 Function(IntPtr, Pointer<_ThreadEntry32>),
            int Function(int, Pointer<_ThreadEntry32>)
          >('Thread32Next'),
      openThread = k32
          .lookupFunction<
            IntPtr Function(Uint32, Int32, Uint32),
            int Function(int, int, int)
          >('OpenThread'),
      threadTimes = k32
          .lookupFunction<
            Int32 Function(
              IntPtr,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Uint64>,
            ),
            int Function(
              int,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Uint64>,
            )
          >('GetThreadTimes'),
      closeHandle = k32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          ),
      currentPid = k32.lookupFunction<Uint32 Function(), int Function()>(
        'GetCurrentProcessId',
      ),
      localFree = k32
          .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
            'LocalFree',
          ),
      description = _lookupDescription(k32),
      queryThread = DynamicLibrary.open('ntdll.dll')
          .lookupFunction<
            Int32 Function(
              IntPtr,
              Int32,
              Pointer<IntPtr>,
              Uint32,
              Pointer<Uint32>,
            ),
            int Function(int, int, Pointer<IntPtr>, int, Pointer<Uint32>)
          >('NtQueryInformationThread'),
      moduleFromAddress = k32
          .lookupFunction<
            Int32 Function(Uint32, IntPtr, Pointer<IntPtr>),
            int Function(int, int, Pointer<IntPtr>)
          >('GetModuleHandleExW'),
      moduleFileName = k32
          .lookupFunction<
            Uint32 Function(IntPtr, Pointer<Utf16>, Uint32),
            int Function(int, Pointer<Utf16>, int)
          >('GetModuleFileNameW');

  static int Function(int, Pointer<Pointer<Utf16>>)? _lookupDescription(
    DynamicLibrary k32,
  ) {
    try {
      return k32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Pointer<Utf16>>),
        int Function(int, Pointer<Pointer<Utf16>>)
      >('GetThreadDescription');
    } on ArgumentError {
      return null; // Win10 1607 之前没有。
    }
  }

  final int Function(int, int) snapshot;
  final int Function(int, Pointer<_ThreadEntry32>) first;
  final int Function(int, Pointer<_ThreadEntry32>) next;
  final int Function(int, int, int) openThread;
  final int Function(
    int,
    Pointer<Uint64>,
    Pointer<Uint64>,
    Pointer<Uint64>,
    Pointer<Uint64>,
  )
  threadTimes;
  final int Function(int) closeHandle;
  final int Function() currentPid;
  final int Function(int) localFree;
  final int Function(int, Pointer<Pointer<Utf16>>)? description;
  final int Function(int, int, Pointer<IntPtr>, int, Pointer<Uint32>)
  queryThread;
  final int Function(int, int, Pointer<IntPtr>) moduleFromAddress;
  final int Function(int, Pointer<Utf16>, int) moduleFileName;
}

_Win32Threads? _win32;

List<ThreadCpuTime> _readWindowsThreads() {
  final _Win32Threads w = _win32 ??= _Win32Threads(
    DynamicLibrary.open('kernel32.dll'),
  );
  final int snap = w.snapshot(_th32csSnapThread, 0);
  if (snap == -1 || snap == 0) {
    throw StateError('CreateToolhelp32Snapshot failed');
  }
  final List<ThreadCpuTime> out = <ThreadCpuTime>[];
  try {
    using((Arena arena) {
      final Pointer<_ThreadEntry32> entry = arena<_ThreadEntry32>();
      final Pointer<Uint64> creation = arena<Uint64>();
      final Pointer<Uint64> exit = arena<Uint64>();
      final Pointer<Uint64> kernel = arena<Uint64>();
      final Pointer<Uint64> user = arena<Uint64>();
      final Pointer<Pointer<Utf16>> desc = arena<Pointer<Utf16>>();
      final Pointer<IntPtr> startAddress = arena<IntPtr>();
      final Pointer<IntPtr> module = arena<IntPtr>();
      final Pointer<Utf16> path = arena<Uint16>(520).cast<Utf16>();
      final Map<int, String> moduleNames = <int, String>{};
      // 没有线程名时按入口地址所在模块命名：`[flutter_windows.dll]`、`[libmpv-2.dll]`……
      String moduleOf(int thread) {
        startAddress.value = 0;
        if (w.queryThread(
                  thread,
                  _threadQuerySetWin32StartAddress,
                  startAddress,
                  sizeOf<IntPtr>(),
                  nullptr,
                ) !=
                0 ||
            startAddress.value == 0) {
          return '';
        }
        module.value = 0;
        if (w.moduleFromAddress(
                  _moduleFromAddressNoRef,
                  startAddress.value,
                  module,
                ) ==
                0 ||
            module.value == 0) {
          return '';
        }
        return moduleNames.putIfAbsent(module.value, () {
          final int n = w.moduleFileName(module.value, path, 260);
          if (n == 0) return '';
          final String full = path.toDartString(length: n);
          return '[${full.split(RegExp(r'[\\/]')).last.toLowerCase()}]';
        });
      }

      final int pid = w.currentPid();
      entry.ref.dwSize = sizeOf<_ThreadEntry32>();
      for (int ok = w.first(snap, entry); ok != 0; ok = w.next(snap, entry)) {
        if (entry.ref.th32OwnerProcessID != pid) continue;
        final int tid = entry.ref.th32ThreadID;
        final int h = w.openThread(
          _threadQueryLimitedInformation | _threadQueryInformation,
          0,
          tid,
        );
        if (h == 0) continue;
        try {
          if (w.threadTimes(h, creation, exit, kernel, user) == 0) continue;
          String name = '';
          final int Function(int, Pointer<Pointer<Utf16>>)? d = w.description;
          if (d != null) {
            desc.value = nullptr;
            if (d(h, desc) >= 0 && desc.value != nullptr) {
              name = desc.value.toDartString();
              w.localFree(desc.value.address);
            }
          }
          if (name.isEmpty) name = moduleOf(h);
          out.add(
            ThreadCpuTime(
              id: tid,
              name: name,
              cpuMicros: (kernel.value + user.value) ~/ 10,
            ),
          );
        } finally {
          w.closeHandle(h);
        }
      }
    });
  } finally {
    w.closeHandle(snap);
  }
  return out;
}

// ---------------------------------------------------------------------------
// macOS / iOS（mach）
// ---------------------------------------------------------------------------

/// `thread_extended_info`（mach/thread_info.h，THREAD_EXTENDED_INFO = 5）。
final class _ThreadExtendedInfo extends Struct {
  @Uint64()
  external int userTimeNs;
  @Uint64()
  external int systemTimeNs;
  @Int32()
  external int cpuUsage;
  @Int32()
  external int policy;
  @Int32()
  external int runState;
  @Int32()
  external int flags;
  @Int32()
  external int sleepTime;
  @Int32()
  external int curPri;
  @Int32()
  external int priority;
  @Int32()
  external int maxPriority;
  @Array(64)
  external Array<Uint8> name;
}

const int _threadExtendedInfo = 5;

final class _Mach {
  _Mach(DynamicLibrary lib)
    : task = lib.lookup<Uint32>('mach_task_self_').value,
      taskThreads = lib
          .lookupFunction<
            Int32 Function(Uint32, Pointer<Pointer<Uint32>>, Pointer<Uint32>),
            int Function(int, Pointer<Pointer<Uint32>>, Pointer<Uint32>)
          >('task_threads'),
      threadInfo = lib
          .lookupFunction<
            Int32 Function(
              Uint32,
              Int32,
              Pointer<_ThreadExtendedInfo>,
              Pointer<Uint32>,
            ),
            int Function(
              int,
              int,
              Pointer<_ThreadExtendedInfo>,
              Pointer<Uint32>,
            )
          >('thread_info'),
      portDeallocate = lib
          .lookupFunction<
            Int32 Function(Uint32, Uint32),
            int Function(int, int)
          >('mach_port_deallocate'),
      vmDeallocate = lib
          .lookupFunction<
            Int32 Function(Uint32, UintPtr, UintPtr),
            int Function(int, int, int)
          >('vm_deallocate');

  final int task;
  final int Function(int, Pointer<Pointer<Uint32>>, Pointer<Uint32>)
  taskThreads;
  final int Function(int, int, Pointer<_ThreadExtendedInfo>, Pointer<Uint32>)
  threadInfo;
  final int Function(int, int) portDeallocate;
  final int Function(int, int, int) vmDeallocate;
}

_Mach? _mach;

List<ThreadCpuTime> _readMachThreads() {
  final _Mach m = _mach ??= _Mach(DynamicLibrary.process());
  final List<ThreadCpuTime> out = <ThreadCpuTime>[];
  using((Arena arena) {
    final Pointer<Pointer<Uint32>> list = arena<Pointer<Uint32>>();
    final Pointer<Uint32> count = arena<Uint32>();
    if (m.taskThreads(m.task, list, count) != 0) {
      throw StateError('task_threads failed');
    }
    final int n = count.value;
    final Pointer<Uint32> threads = list.value;
    final Pointer<_ThreadExtendedInfo> info = arena<_ThreadExtendedInfo>();
    final Pointer<Uint32> infoCount = arena<Uint32>();
    try {
      for (int i = 0; i < n; i++) {
        final int port = threads[i];
        infoCount.value = sizeOf<_ThreadExtendedInfo>() ~/ 4;
        if (m.threadInfo(port, _threadExtendedInfo, info, infoCount) == 0) {
          final List<int> bytes = <int>[];
          for (int j = 0; j < 64; j++) {
            final int b = info.ref.name[j];
            if (b == 0) break;
            bytes.add(b);
          }
          out.add(
            ThreadCpuTime(
              id: port,
              name: String.fromCharCodes(bytes),
              cpuMicros: (info.ref.userTimeNs + info.ref.systemTimeNs) ~/ 1000,
            ),
          );
        }
        m.portDeallocate(m.task, port);
      }
    } finally {
      m.vmDeallocate(m.task, threads.address, n * sizeOf<Uint32>());
    }
  });
  return out;
}
