// 内存采样探针（[PreviousExitLog.startMemorySampling]）：原生内存归因（BUG-4075 证据缺口 ⑩）。
//
// 截至 #fyqsAwZOjU：关掉动画（每 30 s 只 24 帧）、停在阅读器（几乎不出帧）、同步一开头就失败（没进媒体
// 阶段）时，malloc 照样每 30 s 涨 0.6–1 GB 直到 Scudo OOM；同窗口 SRS 账本里什么操作都没有。剩下的
// 嫌疑都在「后台线程上的原生代码」——Dart 侧账本看不见它们。这里不靠猜，直接问内核：
//
// - `cpu=[…]`：每个窗口里各线程（按线程名归组，数字折成 #）吃了多少 CPU 秒。在涨内存的那条线程
//   必然在跑：rayon / fushi-rwkv-# = RWKV，DartWorker = 后台 isolate 里的 FFI，1.raster = 渲染……
// - `vm=[…]`：`/proc/self/maps` 里匿名映射按名字（`[anon:scudo:secondary]`、`dart-*`……）归组的
//   虚拟大小 / 映射数；`sec=[…]`：Scudo secondary（大块分配，各自一段 mmap）的块大小分布——看得出是
//   一堆同样大小的块在涨（某个循环每轮分配一块没放）还是少数巨块。
// - malloc 首次越过 [kNativeAttributionDumpThresholdsMb] 的每一档：后台 isolate 读一遍
//   `/proc/self/smaps`，按映射名记 Rss，连同全部线程的累计 CPU 写一条诊断日志（随反馈上传）。
//
// 只在 Android / Linux 有 /proc；别的平台返回 null。读 /proc 都是小文件或一次顺序读，
// 每 30 s 一次，开销在毫秒级。

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/diagnostics/native_heap_probe.dart';

/// 汇总里最多列几项。
const int kNativeAttributionTop = 8;

/// malloc（MB）首次越过这些值时记一份详细 dump（每档一次）。
const List<int> kNativeAttributionDumpThresholdsMb = <int>[800, 1600, 2400];

/// 线程 CPU 的时钟节拍（Android / Linux 的 USER_HZ 固定 100）。
const int kProcClockTicksPerSecond = 100;

bool get _hasProc => Platform.isAndroid || Platform.isLinux;

/// 一条线程的 `/proc/<pid>/task/<tid>/stat` 解析结果。
@immutable
class ProcThreadStat {
  const ProcThreadStat({
    required this.name,
    required this.state,
    required this.ticks,
  });

  final String name;
  final String state;

  /// utime + stime（节拍）。
  final int ticks;
}

/// 解析 `stat` 正文（线程名可能带空格 / 括号，以最后一个 `)` 为界）；格式不对返回 null。
@visibleForTesting
ProcThreadStat? parseProcThreadStat(String stat) {
  final int open = stat.indexOf('(');
  final int close = stat.lastIndexOf(')');
  if (open < 0 || close < open) return null;
  final List<String> rest = stat
      .substring(close + 1)
      .trim()
      .split(RegExp(r'\s+'));
  // rest[0] = state（字段 3）；utime = 字段 14 = rest[11]，stime = 字段 15 = rest[12]。
  if (rest.length < 13) return null;
  final int? utime = int.tryParse(rest[11]);
  final int? stime = int.tryParse(rest[12]);
  if (utime == null || stime == null) return null;
  return ProcThreadStat(
    name: stat.substring(open + 1, close),
    state: rest[0],
    ticks: utime + stime,
  );
}

/// 线程名归组：数字折成 `#`（`fushi-rwkv-3` → `fushi-rwkv-#`、`DartWorker` 原样）。
@visibleForTesting
String threadGroupOf(String name) => name.replaceAll(RegExp(r'\d+'), '#');

Map<int, ProcThreadStat> _readThreads() {
  final Map<int, ProcThreadStat> out = <int, ProcThreadStat>{};
  final Directory dir = Directory('/proc/self/task');
  final List<FileSystemEntity> tasks;
  try {
    tasks = dir.listSync(followLinks: false);
  } on FileSystemException {
    return out;
  }
  for (final FileSystemEntity t in tasks) {
    final int? tid = int.tryParse(t.path.split('/').last);
    if (tid == null) continue;
    try {
      final ProcThreadStat? s = parseProcThreadStat(
        File('${t.path}/stat').readAsStringSync(),
      );
      if (s != null) out[tid] = s;
    } on FileSystemException {
      // 线程刚退出。
    }
  }
  return out;
}

/// 两次读数之间各线程组的 CPU 增量（节拍），连同组里线程数与此刻在跑（R）的线程数。
/// 新出现的线程按它的全部累计算（窗口里新建的线程也算进这个窗口）。
@visibleForTesting
String? describeThreadCpuDelta(
  Map<int, ProcThreadStat> previous,
  Map<int, ProcThreadStat> current, {
  int top = kNativeAttributionTop,
}) {
  final Map<String, (int ticks, int threads, int running)> groups =
      <String, (int, int, int)>{};
  int total = 0;
  for (final MapEntry<int, ProcThreadStat> e in current.entries) {
    final ProcThreadStat now = e.value;
    final ProcThreadStat? before = previous[e.key];
    final int delta = before != null && before.name == now.name
        ? now.ticks - before.ticks
        : now.ticks;
    if (delta < 0) continue;
    total += delta;
    final String g = threadGroupOf(now.name);
    final (int, int, int) acc = groups[g] ?? (0, 0, 0);
    groups[g] = (
      acc.$1 + delta,
      acc.$2 + 1,
      acc.$3 + (now.state == 'R' ? 1 : 0),
    );
  }
  final List<MapEntry<String, (int, int, int)>> busy =
      groups.entries.where((e) => e.value.$1 > 0).toList()
        ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
  if (busy.isEmpty) return null;
  String sec(int ticks) =>
      (ticks / kProcClockTicksPerSecond).toStringAsFixed(1);
  final String body = busy
      .take(top)
      .map((MapEntry<String, (int, int, int)> e) {
        final (int ticks, int threads, int running) = e.value;
        return '${e.key}${threads > 1 ? '×$threads' : ''} ${sec(ticks)}s'
            '${running > 0 ? ' R$running' : ''}';
      })
      .join('; ');
  return 'cpu=${sec(total)}s[$body${busy.length > top ? '; +${busy.length - top}' : ''}]';
}

Map<int, ProcThreadStat> _lastThreads = <int, ProcThreadStat>{};

/// `cpu=…s[组 秒 …]`：上次采样以来各线程组吃的 CPU。
String? threadCpuProbe() {
  if (!_hasProc) return null;
  final Map<int, ProcThreadStat> now = _readThreads();
  final String? out = describeThreadCpuDelta(_lastThreads, now);
  _lastThreads = now;
  return out;
}

/// 一段映射的归组名：`[anon:scudo:secondary]` → `scudo:secondary`，无名匿名 → `anon`，
/// 文件映射 → null（不计；文件页由 `file=` 读数管）。名字里的数字 / 十六进制串折掉。
@visibleForTesting
String? mappingGroupOf(String name, {required int inode}) {
  if (name.isEmpty) return inode == 0 ? 'anon' : null;
  if (name.startsWith('[anon:')) {
    return name
        .substring(6, name.length - 1)
        .replaceAll(RegExp(r'[0-9a-fA-Fx]{4,}|\d+'), '#');
  }
  if (name.startsWith('[')) return name; // [heap] [stack] ……
  return null;
}

/// 一行 maps：(起, 止, 名字, inode)；解析不了返回 null。
(int, int, String, int)? _parseMapsLine(String line) {
  final List<String> f = line.split(RegExp(r'\s+'));
  if (f.length < 5) return null;
  final int dash = f[0].indexOf('-');
  if (dash < 0) return null;
  final int? start = int.tryParse(f[0].substring(0, dash), radix: 16);
  final int? end = int.tryParse(f[0].substring(dash + 1), radix: 16);
  final int? inode = int.tryParse(f[4]);
  if (start == null || end == null || inode == null) return null;
  return (start, end, f.length > 5 ? f.sublist(5).join(' ') : '', inode);
}

String _mb(int bytes) => bytes >= 1 << 20
    ? '${(bytes / (1 << 20)).toStringAsFixed(bytes >= 100 << 20 ? 0 : 1)}MB'
    : '${(bytes / 1024).ceil()}KB';

/// `/proc/self/maps` 正文 → `vm=[组 虚拟大小/映射数 …] sec=[块大小×个数 …]`。
@visibleForTesting
String? describeMaps(String maps, {int top = kNativeAttributionTop}) {
  final Map<String, (int bytes, int count)> groups = <String, (int, int)>{};
  final Map<int, int> secondary = <int, int>{};
  for (final String line in maps.split('\n')) {
    final (int, int, String, int)? m = _parseMapsLine(line);
    if (m == null) continue;
    final (int start, int end, String name, int inode) = m;
    final String? g = mappingGroupOf(name, inode: inode);
    if (g == null) continue;
    final int size = end - start;
    final (int, int) acc = groups[g] ?? (0, 0);
    groups[g] = (acc.$1 + size, acc.$2 + 1);
    if (g == 'scudo:secondary') {
      // 按 64 KB 取整（每块前后带保护页，同一种分配大小落在同一档）。
      final int bucket = (size + 0xFFFF) & ~0xFFFF;
      secondary[bucket] = (secondary[bucket] ?? 0) + 1;
    }
  }
  if (groups.isEmpty) return null;
  final List<MapEntry<String, (int, int)>> big = groups.entries.toList()
    ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
  final StringBuffer b = StringBuffer('vm=[')
    ..write(
      big
          .take(top)
          .map((e) => '${e.key} ${_mb(e.value.$1)}/${e.value.$2}')
          .join('; '),
    )
    ..write(']');
  if (secondary.isNotEmpty) {
    final List<MapEntry<int, int>> sizes = secondary.entries.toList()
      ..sort((a, b) => (b.key * b.value).compareTo(a.key * a.value));
    b.write(
      ' sec=[${sizes.take(5).map((e) => '${_mb(e.key)}×${e.value}').join(' ')}]',
    );
  }
  return b.toString();
}

/// `vm=[…] sec=[…]`：匿名映射分组。
String? nativeMapsProbe() {
  if (!_hasProc) return null;
  try {
    return describeMaps(File('/proc/self/maps').readAsStringSync());
  } on FileSystemException {
    return null;
  }
}

/// `/proc/self/smaps` 正文 → 按映射组（含文件映射，按文件名）累计 Rss，前 [top] 项。
@visibleForTesting
String describeSmapsRss(String smaps, {int top = 16}) {
  final Map<String, int> rss = <String, int>{};
  String? current;
  for (final String line in smaps.split('\n')) {
    final (int, int, String, int)? m =
        RegExp(r'^[0-9a-f]+-[0-9a-f]+ ').hasMatch(line)
        ? _parseMapsLine(line)
        : null;
    if (m != null) {
      final (int _, int _, String name, int inode) = m;
      current =
          mappingGroupOf(name, inode: inode) ??
          (name.isEmpty ? 'file?' : name.split('/').last);
      continue;
    }
    if (current != null && line.startsWith('Rss:')) {
      final int? kb = int.tryParse(
        line.substring(4).trim().split(RegExp(r'\s+')).first,
      );
      if (kb != null) rss[current] = (rss[current] ?? 0) + kb * 1024;
    }
  }
  final List<MapEntry<String, int>> sorted = rss.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.take(top).map((e) => '${e.key} ${_mb(e.value)}').join('; ');
}

final Set<int> _dumped = <int>{};

/// 每次采样后调用：malloc 首次越过某一档时，后台读 smaps + 全部线程累计 CPU，交给 [sink]。
/// [mallocMb] 取不到（非 Android）时什么都不做。
void maybeDumpNativeAttribution(
  int? mallocMb,
  void Function(String text) sink,
) {
  if (!_hasProc || mallocMb == null) return;
  for (final int t in kNativeAttributionDumpThresholdsMb) {
    if (mallocMb < t || !_dumped.add(t)) continue;
    final Map<int, ProcThreadStat> threads = _readThreads();
    final String cpu =
        describeThreadCpuDelta(
          const <int, ProcThreadStat>{},
          threads,
          top: 40,
        ) ??
        '-';
    Isolate.run<String>(() {
          try {
            return describeSmapsRss(
              File('/proc/self/smaps').readAsStringSync(),
            );
          } on Object catch (e) {
            return 'smaps! $e';
          }
        })
        .then((String rss) {
          sink('malloc≥${t}MB rss=[$rss] 累计$cpu');
        })
        .catchError((Object e) {
          sink('malloc≥${t}MB smaps! $e 累计$cpu');
        });
    return;
  }
}

/// [nativeAttributionDumpProbe] 的 dump 去处（生产启动时接到诊断日志）。
void Function(String text)? nativeAttributionSink;

/// 采样探针形态的 dump 触发器：不出读数（返回 null），只在 malloc 越档时触发 dump。
String? nativeAttributionDumpProbe() {
  final void Function(String text)? sink = nativeAttributionSink;
  if (sink != null) maybeDumpNativeAttribution(nativeHeapAllocatedMb(), sink);
  return null;
}

/// 测试收尾：清掉跨调用状态。
@visibleForTesting
void resetNativeAttributionProbe() {
  _lastThreads = <int, ProcThreadStat>{};
  _dumped.clear();
}
