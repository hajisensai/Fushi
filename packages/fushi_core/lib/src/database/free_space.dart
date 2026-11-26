/// 写备份前的磁盘空间检查（自动备份第五期，docs/specs/2026-11-25-auto-backup-restore-points.md
/// 「Phase 5」）：app 的定时 / 操作前 / 更新前还原点、取回本机的副本，以及无头服务端的整机备份，动笔之前先估
/// 这次要写多少、和目标卷的可用空间比，不够就不开始（不写半截、不把盘写满）。
///
/// 平台实现只有一份：fushi_fsrs 的 `ffsrs_volume_free_bytes`（与复习库压缩的空间检查共用 `free_bytes`）。本包
/// 不依赖 fushi_srs，所以由宿主在启动时 [registerVolumeFreeBytes]（app / 服务端都接
/// `FfiFsrsEngine.volumeFreeBytes`）；没登记、或平台取不到时一律当「不知道」，照常写（不因查不到空间而拒绝备份）。
library;

import 'dart:io';

/// 空间不够时记进状态 / 回给调用方的错误码。
const String kNotEnoughSpaceError = 'not_enough_space';

/// 估算之外留的余量（与复习库压缩 `MARGIN` 同为 64 MiB）：文件系统元数据、估算误差、别的程序同时在写。
const int kBackupSpaceMarginBytes = 64 << 20;

/// [path] 所在卷可用的字节数；不知道返回 null。
typedef VolumeFreeBytes = int? Function(String path);

VolumeFreeBytes? _registered;

/// 登记进程里的可用空间探针（app / 服务端启动时）；null = 撤销（测试）。
void registerVolumeFreeBytes(VolumeFreeBytes? probe) => _registered = probe;

/// [path] 所在卷的可用空间：[probe] 优先，否则用登记的探针；都没有、探针抛错或给负数返回 null。
int? volumeFreeBytes(String path, {VolumeFreeBytes? probe}) {
  final VolumeFreeBytes? f = probe ?? _registered;
  if (f == null) return null;
  try {
    final int? free = f(path);
    return free == null || free < 0 ? null : free;
  } on Object {
    return null;
  }
}

/// 一次写入在 [directory] 所在卷上要占的字节数。
class SpaceNeed {
  const SpaceNeed(this.directory, this.bytes);

  final String directory;
  final int bytes;
}

/// 空间不够：`toString` 就是错误码 [kNotEnoughSpaceError]（状态文件、提示文案、ctl 都按码认），细节在
/// [detail]（只进调试日志）。
class NotEnoughSpaceException implements Exception {
  const NotEnoughSpaceException({
    required this.directory,
    required this.neededBytes,
    required this.freeBytes,
  });

  /// 不够的那个卷上的一个目标目录。
  final String directory;

  /// 估算要写的字节数（含余量）。
  final int neededBytes;
  final int freeBytes;

  String get code => kNotEnoughSpaceError;

  String get detail =>
      'need about $neededBytes bytes in $directory, $freeBytes free';

  @override
  String toString() => kNotEnoughSpaceError;
}

/// [needs] 里每个目标卷的可用空间都够（估算 + [marginBytes]）才返回，否则抛 [NotEnoughSpaceException]。
///
/// 两个目标在同一个卷上（例如备份目录与 `tmp/`）要加在一起算：Dart 拿不到卷的身份，这里把**可用空间读数
/// 相同**的目标当作同一个卷（同一时刻两次读数在不同的卷上恰好相等几乎不会发生，真发生了也只是更严）。
/// 不知道可用空间的目标跳过（照常写）。
void ensureFreeSpace(
  Iterable<SpaceNeed> needs, {
  VolumeFreeBytes? probe,
  int marginBytes = kBackupSpaceMarginBytes,
}) {
  final Map<int, ({String directory, int bytes})> byVolume =
      <int, ({String directory, int bytes})>{};
  for (final SpaceNeed need in needs) {
    final int? free = volumeFreeBytes(need.directory, probe: probe);
    if (free == null) continue;
    final ({String directory, int bytes})? seen = byVolume[free];
    byVolume[free] = (
      directory: seen?.directory ?? need.directory,
      bytes: (seen?.bytes ?? 0) + need.bytes,
    );
  }
  for (final MapEntry<int, ({String directory, int bytes})> e
      in byVolume.entries) {
    final int needed = e.value.bytes + marginBytes;
    if (e.key < needed) {
      throw NotEnoughSpaceException(
        directory: e.value.directory,
        neededBytes: needed,
        freeBytes: e.key,
      );
    }
  }
}

/// 文件大小；不存在 / 读不了为 0。
int fileBytesOrZero(String path) {
  try {
    return File(path).lengthSync();
  } on FileSystemException {
    return 0;
  }
}

/// 目录树里普通文件的大小之和（不跟链接）；不存在为 0，遍历途中消失 / 读不了的部分不计。
int treeBytes(String directory) {
  int total = 0;
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) return 0;
  try {
    for (final FileSystemEntity e in dir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (e is File) {
        try {
          total += e.lengthSync();
        } on FileSystemException {
          // 正在被删 / 改名：不计。
        }
      }
    }
  } on FileSystemException {
    // 列到一半目录没了：照已数到的算。
  }
  return total;
}
