/// 来源扫描的临时落盘区：按**进程会话**分目录，死会话留下的目录可被安全回收。
///
/// 扫描器把网络来源的书 / 漫画卷 / 字幕 / 清单先下到本机临时盘再交导入器。此前每处
/// 各自 `Directory.systemTemp.createTempSync('m1c_scan_*')`、只靠 `finally` 删：进程
/// 被杀（移动端切后台被回收等价于被杀）时整卷漫画、整库书的副本就永远留在系统临时
/// 目录里，没有任何清理。
///
/// 也不能「启动时按名字删 `m1c_scan_*`」：同一台机器常同时开着安装版与开发版（不同
/// 数据根、同一个系统临时目录），一个实例启动会删掉另一个实例正在用的目录。
///
/// 所以归属用**操作系统文件锁**表达：
///
/// ```text
/// <系统临时目录>/fushi_source_scan/
///   s<pid>_<启动微秒>.lock      ← 本进程全程持有排他锁
///   s<pid>_<启动微秒>/          ← 本进程的全部扫描临时目录
///     m1c_scan_books_xxxx/ …
/// ```
///
/// 进程一死（正常退出、闪退、被杀都一样）内核就放锁；[sweepDeadSourceScanSessions]
/// 对每个别人的 `.lock` 试着上锁，**拿得到 = 持有者已死**，才删它的目录。活着的另一个
/// 实例的锁拿不到，原样留着。先建锁文件再建目录，所以「有目录没锁文件」只可能是清到
/// 一半的残留，同样可删。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/source_library/source_auto_scan.dart'
    show SourceScanActivity, sourceScanActivity;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 会话根目录名（系统临时目录下）。
const String kSourceScanTempRootName = 'fushi_source_scan';

const String _lockSuffix = '.lock';

/// 测试替身：把会话根指到别处（默认 `<系统临时目录>/fushi_source_scan`）。
@visibleForTesting
Directory? debugSourceScanTempRoot;

Directory _root() =>
    debugSourceScanTempRoot ??
    Directory(p.join(Directory.systemTemp.path, kSourceScanTempRootName));

/// 本进程的会话：锁文件句柄活到进程结束（不关 = 一直持锁）。
class _Session {
  _Session(this.root, this.name, this.lock);

  /// 建会话时的会话根（测试换根后要重建会话）。
  final String root;
  final String name;

  /// 只为持锁而留着的句柄。
  final RandomAccessFile lock;

  Directory get dir => Directory(p.join(root, name));
}

_Session? _session;

_Session _ensureSession() {
  final Directory root = _root();
  final _Session? live = _session;
  if (live != null && live.root == root.path) return live;
  root.createSync(recursive: true);
  final String name = 's${pid}_${DateTime.now().microsecondsSinceEpoch}';
  // 先建锁文件并上锁，再建目录：清扫方看到目录时锁一定已经在了。
  final RandomAccessFile lock = File(
    p.join(root.path, '$name$_lockSuffix'),
  ).openSync(mode: FileMode.write);
  lock.lockSync(FileLock.exclusive);
  return _session = _Session(root.path, name, lock);
}

/// 测试收尾：放掉本进程会话的锁（否则 Windows 上测试删不掉自己的临时根）。
@visibleForTesting
void debugResetSourceScanTempSession() {
  _session?.lock.closeSync();
  _session = null;
}

/// 在本进程的会话目录下建一个扫描临时目录（名字以 [prefix] 开头）。
///
/// 调用方照旧在 `finally` 里删它；删不到的情形（进程被杀）由下一次
/// [sweepDeadSourceScanSessions] 回收。
Directory createSourceScanTempDir(String prefix) {
  final Directory dir = _ensureSession().dir..createSync(recursive: true);
  return dir.createTempSync(prefix);
}

/// 回收**已死进程**留下的扫描临时目录，返回回收的会话数。
///
/// 只动锁拿得到的会话（见库注释）；本进程自己的会话与其它活着的实例的会话都不碰。
/// 单个目录删不掉（文件被杀毒软件占着等）时留给下一次，不影响其余会话。
Future<int> sweepDeadSourceScanSessions() async {
  final Directory root = _root();
  if (!root.existsSync()) return 0;
  final String? own = _session?.root == root.path ? _session!.name : null;
  final List<FileSystemEntity> entries = root.listSync(followLinks: false);
  final Set<String> lockedNames = <String>{
    for (final FileSystemEntity e in entries)
      if (e is File && e.path.endsWith(_lockSuffix))
        p.basenameWithoutExtension(e.path),
  };
  int reclaimed = 0;
  for (final String name in lockedNames) {
    if (name == own) continue;
    final File lockFile = File(p.join(root.path, '$name$_lockSuffix'));
    final RandomAccessFile handle;
    try {
      handle = lockFile.openSync(mode: FileMode.append);
    } on FileSystemException {
      // 锁文件刚被另一个清扫方删掉 / 打不开：这一轮不管它。
      continue;
    }
    bool dead = false;
    try {
      handle.lockSync(FileLock.exclusive);
      // 拿到锁 = 持有者已死。
      dead = await _deleteTree(Directory(p.join(root.path, name)));
    } on FileSystemException {
      // 拿不到锁 = 持有者还活着。
    } finally {
      // 关句柄即放锁；Windows 上不先关就删不掉锁文件。
      handle.closeSync();
    }
    if (!dead) continue;
    reclaimed++;
    try {
      lockFile.deleteSync();
    } on FileSystemException {
      // 另一个清扫方先删了，结果一样。
    }
  }
  // 有目录没锁文件：清到一半的残留（锁文件先于目录创建，活会话不会是这个形状）。
  for (final FileSystemEntity e in entries) {
    if (e is! Directory) continue;
    final String name = p.basename(e.path);
    if (name == own || lockedNames.contains(name)) continue;
    if (await _deleteTree(e)) reclaimed++;
  }
  return reclaimed;
}

/// 删整棵目录；不存在算成功，删不掉返回 false（留给下一次清扫）。
Future<bool> _deleteTree(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
    return true;
  } on FileSystemException catch (e) {
    debugPrint('source scan temp sweep: cannot delete ${dir.path}: $e');
    return false;
  }
}

// ── 「仅此一次」导入的临时来源行 ─────────────────────────────────────────────

// 临时行是一条普通来源行，只靠 `finally` 删；进程在扫描中途被杀时它就成了来源页上
// 一条用户没加过的常驻来源。行的 `configJson` 带 [kSourceConfigOneShotKey] 标记，下次
// 进程里就能认出并清掉（[sweepStaleOneShotSources]）。

/// 本进程里正在跑的「仅此一次」导入的临时行：清扫时不能动它们。
final Set<int> _liveOneShotSourceIds = <int>{};

/// 一条临时来源行的 `configJson`：[kSourceConfigOneShotKey] 标记，[bookmark]（iOS
/// 安全作用域书签）非空时并进同一个 JSON。
String oneShotSourceConfig(String? bookmark) =>
    encodeSourceConfig(<String, Object?>{
      kSourceConfigOneShotKey: true,
      if (bookmark != null) kSourceConfigIosBookmarkKey: bookmark,
    })!;

/// [row] 是不是「仅此一次」导入的临时来源行。
bool isOneShotSourceRow(MediaSourceRow row) =>
    decodeSourceConfig(row.configJson)[kSourceConfigOneShotKey] == true;

/// 临时行 [sourceId] 的导入开始 / 结束（[importLocalFolderOnceAt] 成对调用）。
void markOneShotSourceLive(int sourceId) => _liveOneShotSourceIds.add(sourceId);

void markOneShotSourceDone(int sourceId) =>
    _liveOneShotSourceIds.remove(sourceId);

/// 删掉**以前的进程**留下的临时来源行（带标记、且不是本进程正在跑的那几条），返回
/// 删掉的行数。与正常收尾同一个动作：释放访问授权后删行，已导入的媒体靠 FK setNull
/// 留在库里。
///
/// 每一行都在这个来源的扫描锁里删（[SourceScanActivity.tryRun]，拍板台
/// design-nmv-fyi-tail ③）：有人正在扫它（用户对着残留行点了「重新扫描」、或调用方
/// 自己就是这次扫描）就跳过，留到下一次进程再清，不把扫描脚下的行删掉；删的期间
/// 到来的扫描排在后面，拿到锁时发现行已不在（[SourceLibraryScanner.scan] 会复核）。
/// 以前靠调用方传 `keep` 排除「自己正在扫的那条」：首页首帧的清扫不在任何来源锁里，
/// 又与扫描入口共用每库一次的结果，那条 `keep` 管不到首帧之后才发起的重扫。
Future<int> sweepStaleOneShotSources(
  FushiDatabase db, {
  Future<void> Function(int sourceId)? releaseAccess,
  SourceScanActivity? activity,
}) async {
  final SourceScanActivity locks = activity ?? sourceScanActivity;
  int removed = 0;
  for (final MediaSourceRow row in await db.getAllMediaSources()) {
    if (!isOneShotSourceRow(row) || _liveOneShotSourceIds.contains(row.id)) {
      continue;
    }
    final Future<bool>? deleted = locks.tryRun<bool>(row.id, () async {
      // 拿锁前读到的行可能已被别处删掉 / 认领：锁里再确认一次。
      if (_liveOneShotSourceIds.contains(row.id) ||
          await db.getMediaSourceById(row.id) == null) {
        return false;
      }
      await releaseAccess?.call(row.id);
      await db.deleteMediaSource(row.id);
      return true;
    });
    if (deleted != null && await deleted) removed++;
  }
  return removed;
}

final Expando<Future<void>> _leftoverSweeps = Expando<Future<void>>();

/// 每个库实例只跑一次的残留清扫：以前的进程留下的临时来源行 + 临时目录。
///
/// 清扫失败（库正忙、目录删不掉）不能连累调用它的那次扫描，所以错误在这里报进
/// 错误日志、不向上抛；下一次进程启动再试。谁先调都一样：正在被扫的来源由扫描锁
/// 排除（[sweepStaleOneShotSources]），不依赖调用方是谁。
Future<void> sweepSourceScanLeftoversOnce(
  FushiDatabase db, {
  Future<void> Function(int sourceId)? releaseAccess,
}) => _leftoverSweeps[db] ??= () async {
  try {
    await sweepStaleOneShotSources(db, releaseAccess: releaseAccess);
    await sweepDeadSourceScanSessions();
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'source scan',
        context: ErrorDescription('sweeping leftovers of interrupted scans'),
      ),
    );
  }
}();
