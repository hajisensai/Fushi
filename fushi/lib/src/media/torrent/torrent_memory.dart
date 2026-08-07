import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// libtorrent 内存占用相关的 session 设置（由内存预算推导，喂给 native
/// `ht_apply_memory_settings`）。libtorrent（尤其 2.x mmap 磁盘缓存 + 每连接
/// 收发缓冲 + peer 列表）不设限会「有多少内存吃多少」；这些字段把它压到一个
/// 与机器内存挂钩的预算内。纯数据。
class TorrentMemorySettings {
  const TorrentMemorySettings({
    required this.connectionsLimit,
    required this.maxQueuedDiskBytes,
    required this.sendBufferWatermark,
    required this.maxPeerlistSize,
  });

  /// 全局最大连接数（peer 数是可伸缩内存的大头）。
  final int connectionsLimit;

  /// 磁盘写缓冲上限（字节）。
  final int maxQueuedDiskBytes;

  /// 每连接发送缓冲高水位（字节）。
  final int sendBufferWatermark;

  /// 每种子 peer 列表最大条目数（peer 列表内存）。
  final int maxPeerlistSize;
}

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// 由「内存预算」推导 libtorrent 内存设置。纯函数（RAM 由参数注入，便于测试）。
///
/// [memoryLimitMb] > 0 时作为硬预算；为 0（自动）时按 [totalRamMb] 取一档：
/// 约 1/8 物理内存，夹在 [128, 2048] MB（RAM 未知/<=0 → 保守 256MB）。
/// 各字段随预算线性缩放并夹在合理区间，避免极端值。启发式，默认值待真机调优。
TorrentMemorySettings computeTorrentMemorySettings({
  required int memoryLimitMb,
  required int totalRamMb,
}) {
  final int budgetMb = memoryLimitMb > 0
      ? memoryLimitMb
      : (totalRamMb > 0 ? _clampInt(totalRamMb ~/ 8, 128, 2048) : 256);

  const int mb = 1024 * 1024;
  return TorrentMemorySettings(
    // 每 peer 粗估几百 KB 收发缓冲；连接数随预算走，夹 [50, 800]。
    connectionsLimit: _clampInt(budgetMb * 2, 50, 800),
    // 写缓冲取预算的 ~1/4，夹 [4MB, 256MB]。
    maxQueuedDiskBytes: _clampInt(budgetMb ~/ 4, 4, 256) * mb,
    // 发送缓冲高水位，夹 [512KB, 4MB]。
    sendBufferWatermark: _clampInt(budgetMb * 8 * 1024, 512 * 1024, 4 * mb),
    // peer 列表条目，夹 [500, 4000]。
    maxPeerlistSize: _clampInt(budgetMb * 20, 500, 4000),
  );
}

/// 尽力探测物理内存总量（MB）。失败/不支持平台返回 null（调用方回落保守默认）。
/// Linux/Android 读 `/proc/meminfo`；Windows 调 `GlobalMemoryStatusEx`；
/// macOS 调 `sysctlbyname("hw.memsize")`。全部同步、无外部依赖（除 dart:ffi）。
int? detectTotalMemoryMb() {
  try {
    if (Platform.isLinux || Platform.isAndroid) {
      return _linuxTotalMemoryMb();
    }
    if (Platform.isWindows) {
      return _windowsTotalMemoryMb();
    }
    if (Platform.isMacOS || Platform.isIOS) {
      return _sysctlTotalMemoryMb();
    }
  } on Object {
    return null;
  }
  return null;
}

/// 解析 `/proc/meminfo` 的 `MemTotal:` 行（单位 kB）。纯函数，便于测试。
int? parseProcMeminfoMemTotalMb(String content) {
  for (final String line in content.split('\n')) {
    if (!line.startsWith('MemTotal:')) continue;
    final Match? m = RegExp(r'MemTotal:\s+(\d+)\s*kB').firstMatch(line);
    if (m == null) return null;
    final int? kb = int.tryParse(m.group(1)!);
    return kb == null ? null : kb ~/ 1024;
  }
  return null;
}

int? _linuxTotalMemoryMb() {
  final File f = File('/proc/meminfo');
  if (!f.existsSync()) return null;
  return parseProcMeminfoMemTotalMb(f.readAsStringSync());
}

int? _windowsTotalMemoryMb() {
  // MEMORYSTATUSEX：dwLength(4) dwMemoryLoad(4) ullTotalPhys(8) ...；共 64 字节。
  final DynamicLibrary k32 = DynamicLibrary.open('kernel32.dll');
  final int Function(Pointer<Uint8>) globalMemoryStatusEx = k32.lookupFunction<
      Int32 Function(Pointer<Uint8>),
      int Function(Pointer<Uint8>)>('GlobalMemoryStatusEx');
  final Pointer<Uint8> buf = calloc<Uint8>(64);
  try {
    buf.cast<Uint32>().value = 64; // dwLength
    if (globalMemoryStatusEx(buf) == 0) return null;
    // ullTotalPhys 在偏移 8（4+4）处，小端 64 位。
    final int totalPhys = (buf + 8).cast<Uint64>().value;
    return totalPhys ~/ (1024 * 1024);
  } finally {
    calloc.free(buf);
  }
}

int? _sysctlTotalMemoryMb() {
  final DynamicLibrary libc = DynamicLibrary.process();
  final int Function(
          Pointer<Utf8>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Void>, int)
      sysctlbyname = libc.lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Uint64>, Pointer<Uint64>,
              Pointer<Void>, IntPtr),
          int Function(Pointer<Utf8>, Pointer<Uint64>, Pointer<Uint64>,
              Pointer<Void>, int)>('sysctlbyname');
  final Pointer<Utf8> name = 'hw.memsize'.toNativeUtf8();
  final Pointer<Uint64> out = calloc<Uint64>();
  final Pointer<Uint64> size = calloc<Uint64>()..value = 8;
  try {
    if (sysctlbyname(name, out, size, nullptr, 0) != 0) return null;
    return out.value ~/ (1024 * 1024);
  } finally {
    calloc.free(name);
    calloc.free(out);
    calloc.free(size);
  }
}
