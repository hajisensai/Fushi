import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// 桌面 Mihon sidecar 一个 JVM 进程的 `java.io.tmpdir`：每次起 JVM 一个独占目录，
/// 进程退出就删；宿主被强杀时留下的目录由下一次起 JVM 时清扫（BUG-5046）。
///
/// 为什么由宿主持有：JVM 往临时目录写两类东西，而且自己收不掉——
/// - 随包 NanoHTTPD 2.3.1 把每个超过 1 KB 的请求体落成 `NanoHTTPD-*` 临时文件并 mmap，
///   Windows 上映射没释放时删不掉；桥调用的请求体都带整份 APK base64，等于每次调用
///   留一个文件，以前落在系统临时目录、永不清理；
/// - 扩展 jar 解在 `mextensionserver*` 目录，靠 JVM shutdown hook 删，而 Windows Job
///   Object / SIGKILL 结束进程时 hook 不跑。
///
/// 目录活着的判据是旁边的 `<目录名>.lock` 被持有者独占锁住：锁随持有进程退出由操作
/// 系统释放，所以「能锁上」就说明持有者已经不在了。POSIX 的文件锁按进程计，同一进程
/// 再锁一次也会成功，因此本进程自己活着的目录另记一份名单，清扫时跳过。
///
/// 创建方「建锁文件」和「锁上」是两步，中间锁文件存在却没上锁。共用同一数据目录的
/// 另一个进程这时清扫会把它判成无主并删掉；POSIX 上删除不受已打开的句柄阻拦，创建方
/// 随后锁住的是已脱离路径的文件，建出的目录旁没有锁文件，下一次清扫就会把正在跑的
/// JVM 的目录当孤儿删掉。所以协议是：清扫方只用只读句柄探锁（不会把已删的锁文件重新
/// 建出来），并在**仍持有探测锁时**删锁文件；创建方阻塞等锁，拿到锁后锁文件路径还在，
/// 就说明没有清扫方在它之前认领过这个名字，否则换一个新名字重来。
class MihonSidecarTempDir {
  MihonSidecarTempDir._(this.directory, this._lockFile, this._lock);

  /// 交给 JVM 的 `-Djava.io.tmpdir`。
  final Directory directory;
  final File _lockFile;
  final RandomAccessFile _lock;
  bool _released = false;

  static const String _prefix = 'jvm-';
  static const String _lockSuffix = '.lock';

  /// 本进程里还没释放的目录名。
  static final Set<String> _liveInThisProcess = <String>{};

  /// 全部 JVM 临时目录的上级：`<数据目录>/sidecar-tmp`。
  static Directory rootOf(Directory dataDirectory) =>
      Directory(p.join(dataDirectory.path, 'sidecar-tmp'));

  /// 测试注入点：创建方建好锁文件、还没锁上时调用，用来模拟别的进程的清扫插进来。
  @visibleForTesting
  static Future<void> Function(File lockFile)? debugBeforeLock;

  /// 清掉持有者已不在的旧目录，再建一个新目录并锁住。
  static Future<MihonSidecarTempDir> create(Directory dataDirectory) async {
    final Directory root = rootOf(dataDirectory);
    await root.create(recursive: true);
    await sweepStale(root);
    while (true) {
      final MihonSidecarTempDir? created = await _tryCreate(root);
      if (created != null) return created;
    }
  }

  /// 用一个新名字建锁文件、锁上、再建目录。锁文件在锁上之前被别的进程的清扫认领删掉
  /// 时返回 null，由 [create] 换名重来（见类注释）。
  static Future<MihonSidecarTempDir?> _tryCreate(Directory root) async {
    final String name =
        '$_prefix$pid-${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32)}';
    // 先锁再建目录：清扫只认「锁文件能锁上」或「目录旁没有锁文件」，目录出现时锁
    // 已经在手，别的进程的清扫不会把它当成无主目录。
    final File lockFile = File(p.join(root.path, '$name$_lockSuffix'));
    final RandomAccessFile lock = await lockFile.open(mode: FileMode.write);
    _liveInThisProcess.add(name);
    try {
      await debugBeforeLock?.call(lockFile);
      // 阻塞等锁：清扫方的探测锁只在它处理这个名字的短时间内持有。
      await lock.lock(FileLock.blockingExclusive);
      // 清扫方删锁文件发生在它放开探测锁之前，所以此刻路径还在，就说明没被认领过；
      // 名字唯一、清扫方又不会新建文件，路径上的只能是自己手上这一份。
      if (!lockFile.existsSync()) {
        _liveInThisProcess.remove(name);
        await lock.close();
        return null;
      }
      final Directory directory = Directory(p.join(root.path, name));
      await directory.create();
      return MihonSidecarTempDir._(directory, lockFile, lock);
    } catch (_) {
      _liveInThisProcess.remove(name);
      await lock.close();
      await _deleteIfPresent(lockFile);
      rethrow;
    }
  }

  /// JVM 已退出后调用：删目录、放锁、删锁文件。目录删不动（杀毒软件正扫着）时它变成
  /// 没有锁文件的孤儿目录，下一次 [create] 的清扫会收掉。
  Future<void> release() async {
    if (_released) return;
    _released = true;
    final String name = p.basename(directory.path);
    await _deleteIfPresent(directory);
    await _lock.close();
    _liveInThisProcess.remove(name);
    await _deleteIfPresent(_lockFile);
  }

  /// 收掉 [root] 下持有者已不在的 JVM 临时目录与锁文件。持有者还活着的（锁不上）、
  /// 本进程自己的、暂时删不动的都留着，下一次再看。
  @visibleForTesting
  static Future<void> sweepStale(Directory root) async {
    final Set<String> dirNames = <String>{};
    final Set<String> lockNames = <String>{};
    await for (final FileSystemEntity entity in root.list(followLinks: false)) {
      final String base = p.basename(entity.path);
      if (!base.startsWith(_prefix)) continue;
      if (entity is Directory) {
        dirNames.add(base);
      } else if (entity is File && base.endsWith(_lockSuffix)) {
        lockNames.add(base.substring(0, base.length - _lockSuffix.length));
      }
    }
    for (final String name in <String>{...dirNames, ...lockNames}) {
      if (_liveInThisProcess.contains(name)) continue;
      final Directory directory = Directory(p.join(root.path, name));
      final File lockFile = File(p.join(root.path, '$name$_lockSuffix'));
      if (!lockNames.contains(name)) {
        // 没有锁文件：持有者总是先删目录再删锁文件、先建锁文件再建目录，所以这是
        // 上一次释放时没删动的孤儿目录。
        await _deleteIfPresent(directory);
        continue;
      }
      // 只读打开：锁文件已被别的清扫方删掉时打开失败，而不是把它重新建出来。
      final RandomAccessFile probe;
      try {
        probe = await lockFile.open();
      } on FileSystemException {
        continue;
      }
      try {
        try {
          // 共享锁与持有者的独占锁互斥；多个清扫方可以同时拿到，各自删的都是无主目录。
          await probe.lock(FileLock.shared);
        } on FileSystemException {
          continue; // 持有者还活着。
        }
        await _deleteIfPresent(directory);
        // 持锁期间删锁文件（POSIX 可以），等着锁的创建方拿到锁时就能看出名字已被认领。
        if (!directory.existsSync()) await _deleteIfPresent(lockFile);
      } finally {
        await probe.close();
      }
      // Windows 不能删自己还开着的文件，放锁后再删；创建方开着锁文件时这一步删不动。
      if (!directory.existsSync()) await _deleteIfPresent(lockFile);
    }
  }

  static Future<void> _deleteIfPresent(FileSystemEntity entity) async {
    try {
      await entity.delete(recursive: entity is Directory);
    } on FileSystemException {
      // 不存在，或被占用暂时删不动：留给下一次清扫（见类注释）。
    }
  }
}
