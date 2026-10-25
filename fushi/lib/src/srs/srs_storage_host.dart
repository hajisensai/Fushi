/// 进程级的 SRS 存储（`<数据库目录>/srs.db`，Rust 独占连接；
/// docs/specs/2026-10-23-srs-rust-store.md §2 / §3）。
///
/// - 一个进程一份，所有 profile 共用；第一次需要 SRS 时才打开（复习模块关着时从不打开）。
/// - 主进程打开时把主库里残留的旧 SRS 表搬进来（[SrsStorage.open] 的 `legacy`）。
/// - 非主进程（`:popup`）不搬迁：主进程还没写下搬迁标记时，当作「没有 SRS 数据」（[acquire]
///   返回 null），绝不去读主库旧表。
/// - 生命周期跟 app 走：关主库前先关它（[close]），覆盖恢复在此之后换 / 删 srs.db 文件。
library;

import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/srs/srs_storage.dart';

/// 打开 srs.db 的方式（测试可换成同 isolate 执行器）。
typedef SrsStorageOpener =
    Future<SrsStorage> Function({required String path, FushiDatabase? legacy});

Future<SrsStorage> _defaultOpener({
  required String path,
  FushiDatabase? legacy,
}) => SrsStorage.open(path: path, legacy: legacy);

/// 进程级 SRS 存储的持有者。
class SrsStorageHost {
  SrsStorageHost({
    required String dbDirectory,
    required bool isMainProcess,
    required FushiDatabase Function() legacyDatabase,
    SrsStorageOpener opener = _defaultOpener,
  }) : _path = SrsStorage.pathIn(dbDirectory),
       _isMainProcess = isMainProcess,
       _legacyDatabase = legacyDatabase,
       _opener = opener;

  final String _path;
  final bool _isMainProcess;
  final FushiDatabase Function() _legacyDatabase;
  final SrsStorageOpener _opener;

  Future<SrsStorage?>? _opening;
  bool _closed = false;

  /// srs.db 的绝对路径。
  String get path => _path;

  /// 打开（或复用已打开的）存储。非主进程在搬迁标记写下之前返回 null（且不缓存，下次再看）。
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
        // 打开失败不缓存：下次（例如用户点「重试」）重新打开。
        _opening = null;
        Error.throwWithStackTrace(e, st);
      },
    );
  }

  Future<SrsStorage?> _open() async {
    if (_isMainProcess) {
      return _opener(path: _path, legacy: _legacyDatabase());
    }
    final SrsStorage s = await _opener(path: _path);
    if (!s.core.legacyImported) {
      // 主进程还没完成首次搬迁：旧数据仍在主库里，这里不读它，按「没有 SRS 数据」处理。
      await s.close();
      return null;
    }
    return s;
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
