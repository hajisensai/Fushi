// 内存采样探针（[PreviousExitLog.startMemorySampling]）：Windows 进程提交量 + 系统内存余量，以及
// （各平台）Flutter 解码图缓存。
//
// #8qHvq2p0oU / #laXmRta9VS / #9OjURIuBIx（Windows 23880，停在前台没了）：采样只有 `rss=`（工作集）
// 和 `max=`（峰值工作集，5.4–6.5 GB），Windows 上没有 `anon= file= malloc=` 那样的分项，分不清：
// - 涨的是进程**私有提交**（真分配：Dart 堆 / 原生堆 / 解码图 / mpv 缓存）还是映射进来的文件页
//   与共享图形内存（工作集算它们，但不占提交）；
// - 死前**系统**还剩多少物理内存 / 提交余量——Windows 不按内存杀进程，提交到顶时是分配失败
//   （c0000005 / abort / Dart OOM），这一项决定该往「进程泄漏」还是「整机吃紧」查。
// 于是：`priv=`（PROCESS_MEMORY_COUNTERS_EX.PrivateUsage）、`sys=可用物理/总物理MB`、
// `commit=已提交/上限MB`（GlobalMemoryStatusEx）；`img=当前/上限MB live=N`（[ImageCache]，
// 解码图常驻的大头，各平台都有）。
//
// 每 30 s 一次同步调用：两个 Win32 查询都是常数时间的内核计数读取。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show ImageCache, PaintingBinding;

/// `PROCESS_MEMORY_COUNTERS_EX`（psapi.h）。
final class _ProcessMemoryCountersEx extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int pageFaultCount;
  @Size()
  external int peakWorkingSetSize;
  @Size()
  external int workingSetSize;
  @Size()
  external int quotaPeakPagedPoolUsage;
  @Size()
  external int quotaPagedPoolUsage;
  @Size()
  external int quotaPeakNonPagedPoolUsage;
  @Size()
  external int quotaNonPagedPoolUsage;
  @Size()
  external int pagefileUsage;
  @Size()
  external int peakPagefileUsage;
  @Size()
  external int privateUsage;
}

/// `MEMORYSTATUSEX`（sysinfoapi.h）。
final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int dwLength;
  @Uint32()
  external int dwMemoryLoad;
  @Uint64()
  external int ullTotalPhys;
  @Uint64()
  external int ullAvailPhys;
  @Uint64()
  external int ullTotalPageFile;
  @Uint64()
  external int ullAvailPageFile;
  @Uint64()
  external int ullTotalVirtual;
  @Uint64()
  external int ullAvailVirtual;
  @Uint64()
  external int ullAvailExtendedVirtual;
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();
typedef _GetProcessMemoryInfoNative =
    Int32 Function(
      IntPtr process,
      Pointer<_ProcessMemoryCountersEx> c,
      Uint32 cb,
    );
typedef _GetProcessMemoryInfoDart =
    int Function(int process, Pointer<_ProcessMemoryCountersEx> c, int cb);
typedef _GlobalMemoryStatusExNative =
    Int32 Function(Pointer<_MemoryStatusEx> s);
typedef _GlobalMemoryStatusExDart = int Function(Pointer<_MemoryStatusEx> s);

final class _Win32Memory {
  _Win32Memory(DynamicLibrary k32)
    : currentProcess = k32
          .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
            'GetCurrentProcess',
          ),
      // Win7+ 的 kernel32 自带 K32 前缀版本，不必另载 psapi.dll。
      processMemoryInfo = k32
          .lookupFunction<
            _GetProcessMemoryInfoNative,
            _GetProcessMemoryInfoDart
          >('K32GetProcessMemoryInfo'),
      globalMemoryStatus = k32
          .lookupFunction<
            _GlobalMemoryStatusExNative,
            _GlobalMemoryStatusExDart
          >('GlobalMemoryStatusEx');

  final _GetCurrentProcessDart currentProcess;
  final _GetProcessMemoryInfoDart processMemoryInfo;
  final _GlobalMemoryStatusExDart globalMemoryStatus;
}

_Win32Memory? _win32;
bool _win32Resolved = false;

_Win32Memory? _resolveWin32() {
  if (_win32Resolved) return _win32;
  _win32Resolved = true;
  if (!Platform.isWindows) return null;
  _win32 = _Win32Memory(DynamicLibrary.open('kernel32.dll'));
  return _win32;
}

/// Windows 进程与系统内存的一次读数（字节）。
@immutable
class WindowsMemoryReading {
  const WindowsMemoryReading({
    required this.privateBytes,
    required this.availPhysBytes,
    required this.totalPhysBytes,
    required this.commitUsedBytes,
    required this.commitLimitBytes,
  });

  final int privateBytes;
  final int availPhysBytes;
  final int totalPhysBytes;
  final int commitUsedBytes;
  final int commitLimitBytes;
}

/// `priv=…MB sys=可用/总MB commit=已用/上限MB`。
@visibleForTesting
String describeWindowsMemory(WindowsMemoryReading r) {
  int mb(int bytes) => bytes >> 20;
  return 'priv=${mb(r.privateBytes)}MB '
      'sys=${mb(r.availPhysBytes)}/${mb(r.totalPhysBytes)}MB '
      'commit=${mb(r.commitUsedBytes)}/${mb(r.commitLimitBytes)}MB';
}

/// 读一次 Windows 进程私有提交与系统内存；非 Windows 返回 null。API 调用失败抛
/// [StateError]（采样层记成 `probe!`，不吞成「没有读数」）。
WindowsMemoryReading? readWindowsMemory() {
  final _Win32Memory? w = _resolveWin32();
  if (w == null) return null;
  return using((Arena arena) {
    final Pointer<_ProcessMemoryCountersEx> pmc =
        arena<_ProcessMemoryCountersEx>();
    final int pmcSize = sizeOf<_ProcessMemoryCountersEx>();
    pmc.ref.cb = pmcSize;
    if (w.processMemoryInfo(w.currentProcess(), pmc, pmcSize) == 0) {
      throw StateError('K32GetProcessMemoryInfo failed');
    }
    final Pointer<_MemoryStatusEx> ms = arena<_MemoryStatusEx>();
    ms.ref.dwLength = sizeOf<_MemoryStatusEx>();
    if (w.globalMemoryStatus(ms) == 0) {
      throw StateError('GlobalMemoryStatusEx failed');
    }
    return WindowsMemoryReading(
      privateBytes: pmc.ref.privateUsage,
      availPhysBytes: ms.ref.ullAvailPhys,
      totalPhysBytes: ms.ref.ullTotalPhys,
      // ullTotalPageFile = 系统提交上限，ullAvailPageFile = 剩余可提交。
      commitUsedBytes: ms.ref.ullTotalPageFile - ms.ref.ullAvailPageFile,
      commitLimitBytes: ms.ref.ullTotalPageFile,
    );
  });
}

/// 采样探针：Windows 上 `priv=… sys=… commit=…`，别的平台 null。
String? windowsMemoryProbe() {
  final WindowsMemoryReading? r = readWindowsMemory();
  return r == null ? null : describeWindowsMemory(r);
}

/// `img=当前/上限MB live=N`：Flutter 解码图缓存（含仍被 widget 持有的 live 图数）。
@visibleForTesting
String describeImageCache(ImageCache cache) =>
    'img=${cache.currentSizeBytes >> 20}/${cache.maximumSizeBytes >> 20}MB '
    'n=${cache.currentSize} live=${cache.liveImageCount}';

/// 采样探针：解码图缓存读数（采样在 binding 初始化之后才开始）。
String? imageCacheProbe() =>
    describeImageCache(PaintingBinding.instance.imageCache);
