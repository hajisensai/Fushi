/// 进程级的 SRS 存储（库目录 `<数据库目录>`，新代库 `srs4.db`，Rust 独占连接；
/// docs/specs/2026-10-23-srs-rust-store.md §2 / §3，docs/specs/2026-11-15-srs-gen4-handoff.md §8.1）。
///
/// - 一个进程一份，所有 profile 共用；第一次需要 SRS 时才打开（复习模块关着时从不打开）。
/// - 主进程按 Primary 打开（唯一的写者；全新安装建空库），非主进程（Android `:popup`、查词窗口）按 Secondary
///   打开（只读、不建库、不迁移）。
/// - 库目录处在某个代际状态（要迁移 / 别的进程在迁移 / 只剩封存旧库 / 上次迁移失败 / 旁边有没迁移的旧库）时
///   [acquire] 抛 [SrsStoreOpenBlocked] 的子类，由页面给迁移页 / 恢复页（srs_generation_view.dart）。迁移提交后
///   [reopen] 再开。非主进程在主进程还没建库时（`ready`）按「没有 SRS 数据」处理（[acquire] 返回 null）。
/// - 生命周期跟 app 走：关主库前先关它（[close]）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnectionUser;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show SrsCore, SrsGenState, SrsOpenMode, SrsStoreNotMigrated;
import 'package:path_provider/path_provider.dart';

/// 给本进程的 SRS 库定 SQLite 临时目录（[SrsCore.useTempDirectory]）：开任何 SRS 库（含备份恢复里的源库）之前调。
///
/// 只有 Android 需要：那里没有平台默认临时目录，大库迁移 / 整理 / 剥表快照的排序溢出无处可落（不设 Rust 侧拒绝打开）。
/// 用 app 的 cache 目录：跟进程走、不随某份库或某次恢复被删。其它平台用系统默认临时目录，不设。
Future<void> useSrsTempDirectory() async {
  if (!Platform.isAndroid) return;
  final Directory cache = await getTemporaryDirectory();
  SrsCore.useTempDirectory(cache.path);
}

/// 打开 SRS 存储的方式（测试可换成同 isolate 执行器 / 假的状态）。
typedef SrsStorageOpener =
    Future<SrsStorage> Function({
      required String directory,
      required SrsOpenMode mode,
      DatabaseConnectionUser? legacy,
    });

Future<SrsStorage> _defaultOpener({
  required String directory,
  required SrsOpenMode mode,
  DatabaseConnectionUser? legacy,
}) => SrsStorage.open(directory: directory, mode: mode, legacy: legacy);

/// 进程级 SRS 存储的持有者。
class SrsStorageHost {
  SrsStorageHost({
    required String dbDirectory,
    required bool isMainProcess,
    required FushiDatabase Function() legacyDatabase,
    SrsStorageOpener opener = _defaultOpener,
  }) : _directory = dbDirectory,
       _isMainProcess = isMainProcess,
       _legacyDatabase = legacyDatabase,
       _opener = opener;

  final String _directory;
  final bool _isMainProcess;
  final FushiDatabase Function() _legacyDatabase;
  final SrsStorageOpener _opener;

  Future<SrsStorage?>? _opening;
  bool _closed = false;

  /// 库目录（迁移命令与 [SrsStorage.open] 用的同一个）。
  String get directory => _directory;

  /// 新代库的路径。
  String get path => SrsStorage.gen4PathIn(_directory);

  /// 协议 3 库的路径（迁移来源 / 迁移后封存的旧库）。
  String get legacyPath => SrsStorage.legacyPathIn(_directory);

  /// 本机有没有复习库文件：新代库，或协议 3 的库（还没迁移的活库 / 迁移后封存的旧库）。备份导出 / 资料删除清理据此
  /// 判断「本机用过复习、数据得随备份走」——只看新代库会让没迁移、复习模块又关着的用户做出不带卡片的备份。
  bool get hasStoredLibrary =>
      File(path).existsSync() || File(legacyPath).existsSync();

  /// 备份导出 / 资料删除清理要读的存储：复习模块开着（[moduleEnabled]）时照常打开；关着时只在本机有复习库文件
  /// （[hasStoredLibrary]）时打开，否则 null（没用过复习的设备不凭空建库）。只有协议 3 库、还没迁移时打开抛
  /// [SrsStoreNotMigrated]：备份明确失败（先升级），不会静默漏掉卡片。
  Future<SrsStorage?> acquireIfStored({required bool moduleEnabled}) {
    if (!moduleEnabled && !hasStoredLibrary) {
      return Future<SrsStorage?>.value();
    }
    return acquire();
  }

  /// 本进程是不是主进程（只有主进程迁移、写库）。
  bool get isMainProcess => _isMainProcess;

  /// 打开（或复用已打开的）存储。非主进程在主进程还没建库时返回 null（且不缓存，下次再看）。
  /// 代际状态抛 [SrsStoreOpenBlocked] 的子类（不缓存：迁移完 / 别的进程迁完后再调就重开）。
  /// [close] 之后抛 [StateError]（库正在关 / 已关，不能再开）。
  Future<SrsStorage?> acquire() {
    if (_closed) {
      return Future<SrsStorage?>.error(StateError('srs storage is closed'));
    }
    return _opening ??= _open().then(
      (SrsStorage? s) {
        if (s == null) _opening = null;
        return s;
      },
      onError: (Object e, StackTrace st) {
        // 打开失败不缓存：下次（例如用户点「重试」、迁移提交之后）重新打开。
        _opening = null;
        Error.throwWithStackTrace(e, st);
      },
    );
  }

  Future<SrsStorage?> _open() async {
    if (_isMainProcess) {
      return _opener(
        directory: _directory,
        mode: SrsOpenMode.primary,
        legacy: _legacyDatabase(),
      );
    }
    try {
      return await _opener(directory: _directory, mode: SrsOpenMode.secondary);
    } on SrsStoreNotMigrated catch (e) {
      // 主进程还没建库（全新安装、主进程还没开过复习）：这里不建库，按「没有 SRS 数据」处理。
      if (e.state == SrsGenState.ready) return null;
      rethrow;
    }
  }

  /// 丢掉缓存的打开结果、下次 [acquire] 重新打开（迁移提交之后）。已经打开的句柄先关掉（迁移只在打不开时跑，
  /// 这时本来就没有句柄）。
  Future<void> reopen() async {
    final Future<SrsStorage?>? opening = _opening;
    _opening = null;
    if (opening == null) return;
    try {
      await (await opening)?.close();
    } on Object {
      // 上次本来就没打开：没有要关的。
    }
  }

  /// 关闭（幂等）。之后 [acquire] 一律失败——关库路径（恢复 / 退出 / 弹窗收尾）用。
  Future<void> close() async {
    _closed = true;
    final Future<SrsStorage?>? opening = _opening;
    _opening = null;
    if (opening == null) return;
    SrsStorage? s;
    try {
      s = await opening;
    } on Object {
      return; // 没打开成功，没有要关的。
    }
    await s?.close();
  }

  bool get isClosed => _closed;
}
