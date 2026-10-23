/// srs.db 的 Dart 句柄（docs/specs/2026-10-23-srs-rust-store.md）。连接由 Rust 独占
/// （native/fushi_fsrs/src/store），这里只发粗粒度命令。
///
/// 原生库是硬依赖：加载失败抛 [SrsCoreUnavailableError]，没有 Drift 回退。
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ffi/fushi_fsrs_library.dart';
import 'srs_rows.dart';

/// 原生库不可用（没编 / ABI 不符 / 缺 `ffsrs_store_*` 符号）。
final class SrsCoreUnavailableError extends StateError {
  SrsCoreUnavailableError(String detail)
    : super(
        'srs store (fushi_fsrs ffsrs_store_*) is not available: $detail; '
        'build native/fushi_fsrs (tool/native_libs.ps1) or set FUSHI_FSRS_LIB',
      );
}

/// Rust 侧命令失败（SQL 错误、坏数据、状态不对）。
final class SrsCoreException implements Exception {
  const SrsCoreException(this.code, this.message);

  /// store/ffi.rs 的状态码：-1 一般错误，-2 参数错，-100 panic。
  final int code;
  final String message;

  @override
  String toString() => 'SrsCoreException($code): $message';
}

typedef _OpenC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Void>>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _OpenDart =
    int Function(
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Void>>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _CloseC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CloseDart = void Function(ffi.Pointer<ffi.Void>);
typedef _SimpleC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _SimpleDart =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>);
typedef _StateC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _StateDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _PageC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _PageDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _SnapshotC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Int32,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _SnapshotDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _QueryC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _QueryDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );

typedef _ExecC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Int32,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _ExecDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );

/// `ffsrs_store_*` 的绑定。
final class SrsCoreBindings {
  SrsCoreBindings._(FushiFsrs lib)
    : _fsrs = lib,
      open = lib.library.lookupFunction<_OpenC, _OpenDart>('ffsrs_store_open'),
      close = lib.library.lookupFunction<_CloseC, _CloseDart>(
        'ffsrs_store_close',
      ),
      legacyState = lib.library.lookupFunction<_StateC, _StateDart>(
        'ffsrs_store_legacy_state',
      ),
      legacyBegin = lib.library.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_begin',
      ),
      legacyPage = lib.library.lookupFunction<_PageC, _PageDart>(
        'ffsrs_store_legacy_page',
      ),
      legacyCommit = lib.library.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_commit',
      ),
      legacyAbort = lib.library.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_abort',
      ),
      legacyMarkNone = lib.library.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_mark_none',
      ),
      snapshot = lib.library.lookupFunction<_SnapshotC, _SnapshotDart>(
        'ffsrs_store_snapshot',
      ),
      debugQuery = lib.library.lookupFunction<_QueryC, _QueryDart>(
        'ffsrs_store_debug_query',
      ),
      exec = lib.library.lookupFunction<_ExecC, _ExecDart>('ffsrs_store_exec'),
      execBatch = lib.library.lookupFunction<_PageC, _PageDart>(
        'ffsrs_store_exec_batch',
      ),
      inTransaction = lib.library.lookupFunction<_StateC, _StateDart>(
        'ffsrs_store_in_transaction',
      );

  final FushiFsrs _fsrs;
  final _OpenDart open;
  final _CloseDart close;
  final _StateDart legacyState;
  final _SimpleDart legacyBegin;
  final _PageDart legacyPage;
  final _SimpleDart legacyCommit;
  final _SimpleDart legacyAbort;
  final _SimpleDart legacyMarkNone;
  final _SnapshotDart snapshot;
  final _QueryDart debugQuery;
  final _ExecDart exec;
  final _PageDart execBatch;
  final _StateDart inTransaction;

  static SrsCoreBindings? _instance;

  /// 按 [FushiFsrs] 的定位规则加载（[libraryPath] 只试这一个）。失败抛 [SrsCoreUnavailableError]。
  static SrsCoreBindings load({String? libraryPath}) {
    if (libraryPath == null && _instance != null) return _instance!;
    final FushiFsrs? lib = libraryPath == null
        ? FushiFsrs.instance
        : FushiFsrs.tryLoad(libraryPath: libraryPath);
    if (lib == null) throw SrsCoreUnavailableError('library not found');
    final SrsCoreBindings b;
    try {
      b = SrsCoreBindings._(lib);
    } on ArgumentError catch (e) {
      throw SrsCoreUnavailableError('missing symbol: ${e.message}');
    }
    if (libraryPath == null) _instance = b;
    return b;
  }

  /// 实际加载的库路径（后台 isolate 重新加载同一个库用）。
  String? get libraryPath => _fsrs.libraryPath;

  void _freeString(ffi.Pointer<ffi.Char> p) =>
      _fsrs.bindings.ffsrs_free_string(p);

  void _freeBytes(ffi.Pointer<ffi.Uint8> p, int len) =>
      _fsrs.bindings.ffsrs_free_bytes(p, len);
}

/// 一个打开的 srs.db。
final class SrsCore {
  SrsCore._(this._b, this._handle, {required this.owned});

  final SrsCoreBindings _b;
  ffi.Pointer<ffi.Void> _handle;

  /// 本对象负责关闭（[fromAddress] 包出来的不负责）。
  final bool owned;

  /// 打开 / 新建 [path]（`<数据库目录>/srs.db`）。
  static SrsCore open(String path, {String? libraryPath}) {
    final SrsCoreBindings b = SrsCoreBindings.load(libraryPath: libraryPath);
    return using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> p, int n) = _utf8(arena, path);
      final ffi.Pointer<ffi.Pointer<ffi.Void>> out = arena();
      final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
      err.value = ffi.nullptr;
      final int rc = b.open(p, n, out, err);
      _check(b, rc, err);
      return SrsCore._(b, out.value, owned: true);
    });
  }

  /// 包装别的 isolate 打开的同一个句柄（不拥有，[close] 不关）。
  static SrsCore fromAddress(int address, {String? libraryPath}) => SrsCore._(
    SrsCoreBindings.load(libraryPath: libraryPath),
    ffi.Pointer<ffi.Void>.fromAddress(address),
    owned: false,
  );

  /// 句柄地址（跨 isolate 传递用）。
  int get address => _handle.address;

  /// 加载的原生库路径（跨 isolate 传递用）。
  String? get libraryPath => _b.libraryPath;

  bool get isClosed => _handle == ffi.nullptr;

  void close() {
    if (isClosed) return;
    if (owned) _b.close(_handle);
    _handle = ffi.nullptr;
  }

  ffi.Pointer<ffi.Void> get _h {
    if (isClosed) throw StateError('srs store is closed');
    return _handle;
  }

  /// 旧主库里的 SRS 数据已搬进来（或确认没有）。
  bool get legacyImported => using((Arena arena) {
    final ffi.Pointer<ffi.Int32> out = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(_b, _b.legacyState(_h, out, err), err);
    return out.value != 0;
  });

  void legacyBegin() => _simple(_b.legacyBegin);
  void legacyCommit() => _simple(_b.legacyCommit);
  void legacyAbort() => _simple(_b.legacyAbort);
  void legacyMarkNone() => _simple(_b.legacyMarkNone);

  /// 一页旧表行（列序见 store/schema.rs `TABLES`）。
  void legacyPage(String table, Uint8List page) => using((Arena arena) {
    final (ffi.Pointer<ffi.Uint8> t, int tn) = _utf8(arena, table);
    final ffi.Pointer<ffi.Uint8> p = arena(page.isEmpty ? 1 : page.length);
    p.asTypedList(page.length).setAll(0, page);
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(_b, _b.legacyPage(_h, t, tn, p, page.length, err), err);
  });

  /// `VACUUM INTO` 一份快照到 [path]（必须不存在）。
  void snapshotInto(String path, {required bool stripDeviceLocal}) =>
      using((Arena arena) {
        final (ffi.Pointer<ffi.Uint8> p, int n) = _utf8(arena, path);
        final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
        err.value = ffi.nullptr;
        _check(_b, _b.snapshot(_h, p, n, stripDeviceLocal ? 1 : 0, err), err);
      });

  /// 只读调试查询（测试 / 诊断；产品代码走命令）。返回每行一个「列名 → 值」。
  List<Map<String, Object?>> debugQuery(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) => using((Arena arena) {
    final (ffi.Pointer<ffi.Uint8> s, int sn) = _utf8(arena, sql);
    final Uint8List encoded = params.isEmpty
        ? Uint8List(0)
        : srsEncodeRows(params.length, <List<Object?>>[params]);
    final ffi.Pointer<ffi.Uint8> pp = arena(
      encoded.isEmpty ? 1 : encoded.length,
    );
    pp.asTypedList(encoded.length).setAll(0, encoded);
    final ffi.Pointer<ffi.Pointer<ffi.Uint8>> out = arena();
    final ffi.Pointer<ffi.Size> outLen = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(
      _b,
      _b.debugQuery(_h, s, sn, pp, encoded.length, out, outLen, err),
      err,
    );
    final int len = outLen.value;
    final Uint8List bytes = Uint8List.fromList(out.value.asTypedList(len));
    _b._freeBytes(out.value, len);
    final (int _, List<List<Object?>> rows) = srsDecodeRows(bytes);
    final List<String> names = rows.first.cast<String>();
    return <Map<String, Object?>>[
      for (final List<Object?> r in rows.skip(1))
        <String, Object?>{
          for (int i = 0; i < names.length; i++) names[i]: r[i],
        },
    ];
  });

  /// 在写连接上执行一条语句（Drift 执行器后端，见 fushi_engine `srs_database_executor.dart`）。
  /// [select] 时返回「列名行 + 结果行」，否则返回一行 `[变更行数, last_insert_rowid]`；都是
  /// [srsDecodeRows] 的页。
  Uint8List exec(String sql, List<Object?> params, {required bool select}) =>
      using((Arena arena) {
        final (ffi.Pointer<ffi.Uint8> s, int sn) = _utf8(arena, sql);
        final Uint8List encoded = params.isEmpty
            ? Uint8List(0)
            : srsEncodeRows(params.length, <List<Object?>>[params]);
        final ffi.Pointer<ffi.Uint8> pp = _copy(arena, encoded);
        final ffi.Pointer<ffi.Pointer<ffi.Uint8>> out = arena();
        final ffi.Pointer<ffi.Size> outLen = arena();
        final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
        err.value = ffi.nullptr;
        _check(
          _b,
          _b.exec(
            _h,
            s,
            sn,
            pp,
            encoded.length,
            select ? 1 : 0,
            out,
            outLen,
            err,
          ),
          err,
        );
        final int len = outLen.value;
        final Uint8List bytes = Uint8List.fromList(out.value.asTypedList(len));
        _b._freeBytes(out.value, len);
        return bytes;
      });

  /// 批量语句：[applications] 每项是（语句下标, 参数）。
  void execBatch(
    List<String> statements,
    List<(int, List<Object?>)> applications,
  ) => using((Arena arena) {
    final Uint8List stmts = srsEncodeRows(1, <List<Object?>>[
      for (final String s in statements) <Object?>[s],
    ]);
    final Uint8List apps = srsEncodeRows(2, <List<Object?>>[
      for (final (int i, List<Object?> args) in applications)
        <Object?>[
          i,
          args.isEmpty
              ? Uint8List(0)
              : srsEncodeRows(args.length, <List<Object?>>[args]),
        ],
    ]);
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(
      _b,
      _b.execBatch(
        _h,
        _copy(arena, stmts),
        stmts.length,
        _copy(arena, apps),
        apps.length,
        err,
      ),
      err,
    );
  });

  /// 写连接当前是否在事务里。
  bool get inTransaction => using((Arena arena) {
    final ffi.Pointer<ffi.Int32> out = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(_b, _b.inTransaction(_h, out, err), err);
    return out.value != 0;
  });

  static ffi.Pointer<ffi.Uint8> _copy(Arena arena, Uint8List bytes) {
    final ffi.Pointer<ffi.Uint8> p = arena(bytes.isEmpty ? 1 : bytes.length);
    p.asTypedList(bytes.length).setAll(0, bytes);
    return p;
  }

  void _simple(_SimpleDart f) => using((Arena arena) {
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(_b, f(_h, err), err);
  });

  static (ffi.Pointer<ffi.Uint8>, int) _utf8(Arena arena, String s) {
    final Uint8List b = utf8.encode(s);
    final ffi.Pointer<ffi.Uint8> p = arena(b.isEmpty ? 1 : b.length);
    p.asTypedList(b.length).setAll(0, b);
    return (p, b.length);
  }

  static void _check(
    SrsCoreBindings b,
    int rc,
    ffi.Pointer<ffi.Pointer<ffi.Char>> err,
  ) {
    if (rc == 0) return;
    String message = 'srs store error';
    if (err.value != ffi.nullptr) {
      message = err.value.cast<Utf8>().toDartString();
      b._freeString(err.value);
    }
    throw SrsCoreException(rc, message);
  }
}
