import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// BUG-5076：开库失败时判断「主库所在卷是不是已经写满」。
///
/// 磁盘写满时 sqlite 报出来的码并不总是 `SQLITE_FULL`(13)：WAL 库开库要先扩
/// `-shm`（unix VFS 逐页写 1 字节，写不进去报 `SQLITE_IOERR_SHMSIZE`），读库时还可能
/// 报 `SQLITE_CORRUPT`(11)「database disk image is malformed」（用户反馈 AwX7bUtymI：
/// iPad 存储写满，日志里满屏 errno 28，`PRAGMA journal_mode=WAL` 报 code 11）。只看
/// sqlite 的结果码分不出「真坏了」和「写不进去」，所以终态分类要直接问卷本身：在库目录
/// 里真写一块 [kDbOpenMinFreeBytes] 字节的探测文件，写不进去且 OS 报的是空间不足，
/// 就是空间问题——此时绝不能把用户引去「恢复备份 / 清空数据」，也绝不能跑删侧车的
/// 恢复阶梯（快照会因同样的空间不足失败，删掉的 `-wal` 是已提交事务的唯一副本）。

/// 开库探测要求卷上至少还能写下的字节数。SQLite 开一个 WAL 库要建 / 扩 `-shm`
/// （32 KiB 一档）、回放 `-wal`、可能还要检查点写主库页；1 MiB 足够覆盖开库本身，
/// 又小到在失败路径上探一次不成负担。
const int kDbOpenMinFreeBytes = 1 << 20;

/// 「空间不足」类 OS 错误码。POSIX（Linux / Android / macOS / iOS）的 `ENOSPC` 都是 28；
/// Windows 是 `ERROR_DISK_FULL`(112) 与 `ERROR_HANDLE_DISK_FULL`(39)。
bool isOutOfSpaceOsError(OSError? error) {
  if (error == null) return false;
  final int code = error.errorCode;
  if (Platform.isWindows) return code == 112 || code == 39;
  return code == 28;
}

/// [error] 本身（或它携带的 OS 错误）是不是「空间不足」。
bool isOutOfSpaceError(Object error) =>
    error is FileSystemException && isOutOfSpaceOsError(error.osError);

/// 仅供测试：替换 [dbVolumeIsOutOfSpace] 的真实探测（返回 true = 卷已写满）。
/// 测试里无法真把磁盘写满，用它模拟 ENOSPC 现场。生产代码从不设置它。
bool Function(String directory)? debugDbVolumeOutOfSpaceForTesting;

/// [directory] 所在卷是否已写满：在目录里写一块 [kDbOpenMinFreeBytes] 字节的探测文件，
/// 写失败且错误是空间不足才返回 true。别的失败（目录不存在、无权限、只读介质）不是
/// 空间问题，返回 false，交给调用方原有的分类。探测文件用完即删。
bool dbVolumeIsOutOfSpace(String directory) {
  final bool Function(String directory)? override =
      debugDbVolumeOutOfSpaceForTesting;
  if (override != null) return override(directory);
  if (!Directory(directory).existsSync()) return false;
  final File probe = File(
    p.join(directory, '.fushi-space-probe-$pid-${_probeSerial++}'),
  );
  try {
    final RandomAccessFile raf = probe.openSync(mode: FileMode.write);
    try {
      raf.writeFromSync(Uint8List(kDbOpenMinFreeBytes));
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    return false;
  } on FileSystemException catch (e) {
    return isOutOfSpaceOsError(e.osError);
  } finally {
    try {
      if (probe.existsSync()) probe.deleteSync();
    } on FileSystemException {
      // 探测文件删不掉不影响判定；它只占 [kDbOpenMinFreeBytes]，下次探测换新名字。
    }
  }
}

int _probeSerial = 0;
