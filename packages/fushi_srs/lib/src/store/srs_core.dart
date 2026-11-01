/// srs.db 的 Dart 句柄（docs/specs/2026-10-23-srs-rust-store.md）。连接由 Rust 独占
/// （native/fushi_fsrs/src/store），这里只发粗粒度命令。
///
/// 原生库是硬依赖：加载失败抛 [SrsCoreUnavailableError]，没有 Drift 回退。
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

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

/// 打开时 srs.db 要升级格式，而所在卷的空闲空间不够（store/ffi.rs `STORE_NO_SPACE`）：升级没开始，库一个字节没动；
/// 腾出 [neededBytes] - [freeBytes] 以上的空间后重试即可。
final class SrsUpgradeNoSpaceException extends SrsCoreException {
  const SrsUpgradeNoSpaceException(
    super.code,
    super.message, {
    required this.neededBytes,
    required this.freeBytes,
  });

  /// store/ffi.rs 的状态码。
  static const int statusCode = -3;

  /// Rust 侧错误文本的前缀（store/schema.rs `UPGRADE_NO_SPACE`），后面是 `{"need","free","from","to"}`。
  static const String prefix = 'srs.db upgrade needs more free disk space: ';

  final int neededBytes;
  final int freeBytes;

  /// 按 [statusCode] 的错误文本解析；文本不是约定的形状为 null（照一般错误报）。
  static SrsUpgradeNoSpaceException? tryParse(int code, String message) {
    if (code != statusCode || !message.startsWith(prefix)) return null;
    try {
      final Object? j = jsonDecode(message.substring(prefix.length));
      if (j is! Map) return null;
      final Object? need = j['need'];
      final Object? free = j['free'];
      if (need is! int || free is! int) return null;
      return SrsUpgradeNoSpaceException(
        code,
        message,
        neededBytes: need,
        freeBytes: free,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() =>
      'SrsUpgradeNoSpaceException: upgrading srs.db needs $neededBytes bytes '
      'free on its volume, only $freeBytes available';
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

typedef _ReadBeginC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Pointer<ffi.Void>>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _ReadBeginDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Pointer<ffi.Void>>,
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

typedef _HistC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _HistDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );

/// P6 直读命令的统一签名：输入页（`[下标, 文本]` 两列）+ i64 参数 → Rust 分配的字节。
typedef _CmdC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _CmdDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Int64>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );

/// `ffsrs_store_*` 的绑定。
final class SrsCoreBindings {
  SrsCoreBindings._(FushiFsrs fsrs, ffi.DynamicLibrary lib)
    : _fsrs = fsrs,
      open = lib.lookupFunction<_OpenC, _OpenDart>('ffsrs_store_open'),
      close = lib.lookupFunction<_CloseC, _CloseDart>('ffsrs_store_close'),
      legacyState = lib.lookupFunction<_StateC, _StateDart>(
        'ffsrs_store_legacy_state',
      ),
      legacyBegin = lib.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_begin',
      ),
      legacyPage = lib.lookupFunction<_PageC, _PageDart>(
        'ffsrs_store_legacy_page',
      ),
      legacyCommit = lib.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_commit',
      ),
      legacyAbort = lib.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_abort',
      ),
      legacyMarkNone = lib.lookupFunction<_SimpleC, _SimpleDart>(
        'ffsrs_store_legacy_mark_none',
      ),
      snapshot = lib.lookupFunction<_SnapshotC, _SnapshotDart>(
        'ffsrs_store_snapshot',
      ),
      readBegin = lib.lookupFunction<_ReadBeginC, _ReadBeginDart>(
        'ffsrs_store_read_begin',
      ),
      readQuery = lib.lookupFunction<_QueryC, _QueryDart>(
        'ffsrs_store_read_query',
      ),
      readEnd = lib.lookupFunction<_CloseC, _CloseDart>('ffsrs_store_read_end'),
      debugQuery = lib.lookupFunction<_QueryC, _QueryDart>(
        'ffsrs_store_debug_query',
      ),
      exec = lib.lookupFunction<_ExecC, _ExecDart>('ffsrs_store_exec'),
      execBatch = lib.lookupFunction<_PageC, _PageDart>(
        'ffsrs_store_exec_batch',
      ),
      inTransaction = lib.lookupFunction<_StateC, _StateDart>(
        'ffsrs_store_in_transaction',
      ),
      historyStates = lib.lookupFunction<_HistC, _HistDart>(
        'ffsrs_store_history_states',
      ),
      optimizerItems = lib.lookupFunction<_CmdC, _CmdDart>(
        'ffsrs_store_optimizer_items',
      ),
      rwkvRows = lib.lookupFunction<_CmdC, _CmdDart>('ffsrs_store_rwkv_rows'),
      rwkvLogTail = lib.lookupFunction<_CmdC, _CmdDart>(
        'ffsrs_store_rwkv_log_tail',
      ),
      statProjection = lib.lookupFunction<_HistC, _HistDart>(
        'ffsrs_store_stat_projection',
      ),
      sync2 = lib.lookupFunction<_QueryC, _QueryDart>('ffsrs_store_sync2');

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
  final _ReadBeginDart readBegin;
  final _QueryDart readQuery;
  final _CloseDart readEnd;
  final _ExecDart exec;
  final _PageDart execBatch;
  final _StateDart inTransaction;
  final _HistDart historyStates;
  final _CmdDart optimizerItems;
  final _CmdDart rwkvRows;
  final _CmdDart rwkvLogTail;
  final _HistDart statProjection;
  final _QueryDart sync2;

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
      b = SrsCoreBindings._(lib, _reopen(lib.libraryPath));
    } on ArgumentError catch (e) {
      throw SrsCoreUnavailableError('missing symbol: ${e.message}');
    }
    if (libraryPath == null) _instance = b;
    return b;
  }

  /// 按 [FushiFsrs.libraryPath] 取回同一个已加载的库（null = iOS 进程内静态链接）。
  /// [FushiFsrs] 自己不持有 `DynamicLibrary`：它要能随闭包发进 `Isolate.run`，而
  /// `DynamicLibrary` 不可跨 isolate 发送。
  static ffi.DynamicLibrary _reopen(String? path) => path == null
      ? ffi.DynamicLibrary.process()
      : ffi.DynamicLibrary.open(path);

  /// 实际加载的库路径（后台 isolate 重新加载同一个库用）。
  String? get libraryPath => _fsrs.libraryPath;

  void _freeString(ffi.Pointer<ffi.Char> p) =>
      _fsrs.bindings.ffsrs_free_string(p);

  void _freeBytes(ffi.Pointer<ffi.Uint8> p, int len) =>
      _fsrs.bindings.ffsrs_free_bytes(p, len);

  int _bootTimeMs() {
    final int ms = _fsrs.bindings.ffsrs_boot_time_ms();
    if (ms < 0) throw StateError('ffsrs_boot_time_ms: boot clock unavailable');
    return ms;
  }
}

/// 一个打开的 srs.db。
/// [SrsCore.snapshotQuery] 拒绝非只读查询时的错误消息（与 Rust `store::NOT_SNAPSHOT` 相同）。
const String kSrsNotSnapshotQuery = 'srs: not a snapshot query';

final class SrsCore {
  SrsCore._(this._b, this._handle, {required this.owned});

  final SrsCoreBindings _b;
  ffi.Pointer<ffi.Void> _handle;

  /// 本对象负责关闭（[fromAddress] 包出来的不负责）。
  final bool owned;

  /// 自本次开机以来的毫秒，含睡眠、不受改系统时间影响（`ffsrs_boot_time_ms`）。可信时间
  /// （[SrsTrustedClock]）按它推算；取不到时抛 [StateError]（原生库是硬依赖，不退回别的时钟）。
  int bootTimeMs() => _b._bootTimeMs();

  /// 在当前 isolate 同步打开 / 新建 [path]（`<数据库目录>/srs.db`）。可能整段做格式升级：只给测试与已在
  /// 后台 isolate 里的代码用，app 走 [openInBackground]（守卫 fushi/test/build/srs_store_open_off_ui_isolate_guard_test.dart）。
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

  /// 在后台 isolate 打开 / 新建 [path]，返回的句柄归调用方拥有（[close] 关库）。产品代码一律走这里。
  ///
  /// 打开会把库升级到当前格式（store/schema.rs `migrate`：整表重建、单事务），库大时要几分钟。
  /// Android / iOS 上 UI isolate 跑在平台主线程，在那里同步 [open] 就是整段升级期间主线程被占：
  /// 一帧都出不来、系统启动画面撤不掉（3.1.0 白屏）。后台 isolate 打开后只把句柄号（原生句柄表里的编号，
  /// 进程内通用）带回来。
  static Future<SrsCore> openInBackground(
    String path, {
    String? libraryPath,
  }) async {
    final SrsCoreBindings b = SrsCoreBindings.load(libraryPath: libraryPath);
    final String? resolvedLibraryPath = b.libraryPath;
    final int address = await Isolate.run(
      () => _openAddress(path, resolvedLibraryPath),
      debugName: 'srs-store-open',
    );
    return SrsCore._(
      b,
      ffi.Pointer<ffi.Void>.fromAddress(address),
      owned: true,
    );
  }

  /// [openInBackground] 的后台一半（顶层签名只带可发送的参数，闭包不捕获 [SrsCoreBindings]）。
  static int _openAddress(String path, String? libraryPath) =>
      open(path, libraryPath: libraryPath).address;

  /// 包装别的 isolate 打开的同一个句柄（不拥有，[close] 不关）。
  static SrsCore fromAddress(int address, {String? libraryPath}) => SrsCore._(
    SrsCoreBindings.load(libraryPath: libraryPath),
    ffi.Pointer<ffi.Void>.fromAddress(address),
    owned: false,
  );

  /// 句柄值（跨 isolate 传递用）：原生句柄表里的编号而不是指针，拥有者关库后经它的调用一律报
  /// 「已关闭」（[SrsCoreException]），不会碰到已释放的内存。
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
    p.asTypedListOutOfLine(page.length).setAll(0, page);
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
  ]) => _rowsQuery(_b, _b.debugQuery, _h, sql, params);

  /// 另开一条独立只读连接并开读事务：返回时快照已定下，之后的写入都不在里面（备份读快照用）。
  /// 用完 [SrsReadSession.close]。可以在拿到句柄后交给后台 isolate（[SrsReadSession.fromAddress]）。
  SrsReadSession beginRead() => using((Arena arena) {
    final ffi.Pointer<ffi.Pointer<ffi.Void>> out = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(_b, _b.readBegin(_h, out, err), err);
    return SrsReadSession._(_b, out.value, owned: true);
  });

  static List<Map<String, Object?>> _rowsQuery(
    SrsCoreBindings b,
    _QueryDart f,
    ffi.Pointer<ffi.Void> h,
    String sql,
    List<Object?> params,
  ) => using((Arena arena) {
    final (ffi.Pointer<ffi.Uint8> s, int sn) = _utf8(arena, sql);
    final Uint8List encoded = params.isEmpty
        ? Uint8List(0)
        : srsEncodeRows(params.length, <List<Object?>>[params]);
    final ffi.Pointer<ffi.Uint8> pp = _copy(arena, encoded);
    final ffi.Pointer<ffi.Pointer<ffi.Uint8>> out = arena();
    final ffi.Pointer<ffi.Size> outLen = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(b, f(h, s, sn, pp, encoded.length, out, outLen, err), err);
    final int len = outLen.value;
    final Uint8List bytes = Uint8List.fromList(
      out.value.asTypedListOutOfLine(len),
    );
    b._freeBytes(out.value, len);
    final (int _, List<List<Object?>> rows) = srsDecodeRows(bytes);
    final List<String> names = rows.first.cast<String>();
    return <Map<String, Object?>>[
      for (final List<Object?> r in rows.skip(1))
        <String, Object?>{
          for (int i = 0; i < names.length; i++) names[i]: r[i],
        },
    ];
  });

  /// 在写连接上执行一条语句（Drift 执行器的写语句与 `runCustom` 后端，见 fushi_engine
  /// `srs_database_executor.dart`）。[select] 时返回「列名行 + 结果行」，否则返回一行
  /// `[变更行数, last_insert_rowid]`；都是 [srsDecodeRows] 的页。事务控制语句（BEGIN / COMMIT /
  /// SAVEPOINT）必须走这里：内核据此知道 Drift 事务是否开着（[execQuery] 的选路）。
  Uint8List exec(String sql, List<Object?> params, {required bool select}) =>
      _exec(sql, params, select ? 1 : 0);

  /// Drift 的查询（`runSelect`）：Drift 事务开着时在写连接上跑（看得见事务里未提交的行），否则只读查询走
  /// 内核的读连接快照、不排写锁（native/fushi_fsrs/src/store/mod.rs `SrsCore::select`）。返回页同 [exec] 的查询。
  Uint8List execQuery(String sql, List<Object?> params) =>
      _exec(sql, params, 2);

  /// Drift 事务**外**的查询（fushi_engine `srs_database_executor.dart` 的读查询那一路）：一律在内核的只读连接池
  /// 里执行，并发的查询各占一条连接、互不排队，只看已提交的数据（native/fushi_fsrs/src/store/mod.rs
  /// `SrsCore::snapshot_select`）。不是只读查询（PRAGMA、`… RETURNING` 等）不执行、抛 [SrsCoreException]，
  /// 消息为 [kSrsNotSnapshotQuery]，调用方改走 [execQuery]。返回页同 [execQuery]。
  Uint8List snapshotQuery(String sql, List<Object?> params) =>
      _exec(sql, params, 3);

  /// [mode]：0 = 写语句，1 = 写连接上返回结果行的语句，2 = 选路查询，3 = 事务外快照查询
  /// （ffi.rs `ffsrs_store_exec`）。
  Uint8List _exec(String sql, List<Object?> params, int mode) =>
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
          _b.exec(_h, s, sn, pp, encoded.length, mode, out, outLen, err),
          err,
        );
        final int len = outLen.value;
        final Uint8List bytes = Uint8List.fromList(
          out.value.asTypedListOutOfLine(len),
        );
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

  /// 同步 v2 的命令（native/fushi_fsrs/src/store/ffi.rs `ffsrs_store_sync2`，命令表见那里的
  /// `sync2_dispatch`）：[request] 是 `{"op": ..., "profile": ..., ...}`，[blobs] 是段 / head 文件或
  /// `apply` 的事件数组 JSON。一次调用一个粗粒度命令；可能较慢（收段、迁移、全量重放），调用方放后台 isolate。
  SrsSync2Result sync2(
    Map<String, Object?> request, {
    List<Uint8List> blobs = const <Uint8List>[],
  }) => using((Arena arena) {
    final (ffi.Pointer<ffi.Uint8> rq, int rqn) = _utf8(
      arena,
      jsonEncode(request),
    );
    // 段直接分帧写进原生缓冲（不先拼一份 Dart 侧的帧再整份拷过去；审查 S-9）。
    final int framedLen = srsSync2FramesLength(blobs);
    final ffi.Pointer<ffi.Uint8> bp = arena(framedLen == 0 ? 1 : framedLen);
    srsSync2FramesInto(bp.asTypedListOutOfLine(framedLen), blobs);
    final ffi.Pointer<ffi.Pointer<ffi.Uint8>> out = arena();
    final ffi.Pointer<ffi.Size> outLen = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(_b, _b.sync2(_h, rq, rqn, bp, framedLen, out, outLen, err), err);
    final int len = outLen.value;
    final Uint8List bytes = Uint8List.fromList(
      out.value.asTypedListOutOfLine(len),
    );
    _b._freeBytes(out.value, len);
    return SrsSync2Result.decode(bytes);
  });

  /// 卡片历史的当前状态，Rust 直接从写连接读日志（含事务里未提交的行）。[lineages] 每项是一份
  /// 历史的血统（自己 + 全部前身的卡 ID）。返回 `srsDecodeHistoryStates` 的布局。
  Uint8List historyStates(List<List<String>> lineages) => using((Arena arena) {
    final Uint8List page = srsEncodeRows(2, <List<Object?>>[
      for (int g = 0; g < lineages.length; g++)
        for (final String c in lineages[g]) <Object?>[g, c],
    ]);
    final ffi.Pointer<ffi.Pointer<ffi.Uint8>> out = arena();
    final ffi.Pointer<ffi.Size> outLen = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(
      _b,
      _b.historyStates(
        _h,
        _copy(arena, page),
        page.length,
        lineages.length,
        out,
        outLen,
        err,
      ),
      err,
    );
    final int len = outLen.value;
    final Uint8List bytes = Uint8List.fromList(
      out.value.asTypedListOutOfLine(len),
    );
    _b._freeBytes(out.value, len);
    return bytes;
  });

  /// 有效复习投影（`SrsStatReviews` 的行），Rust 直接从写连接读日志（含事务里未提交的行）。[groups]
  /// 每项是一个归属组（归属卡在前，再列出归它的前身卡），组内日志合在一起投影。返回 9 列行页
  /// （[srsDecodeRows]）：组下标, logId, occurredAt, utcOffsetMin, rating|null, kind, durationMs,
  /// prevDueDay|null, maturityDelta。
  Uint8List statProjection(List<List<String>> groups) => using((Arena arena) {
    final Uint8List page = srsEncodeRows(2, <List<Object?>>[
      for (int g = 0; g < groups.length; g++)
        for (final String c in groups[g]) <Object?>[g, c],
    ]);
    final ffi.Pointer<ffi.Pointer<ffi.Uint8>> out = arena();
    final ffi.Pointer<ffi.Size> outLen = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(
      _b,
      _b.statProjection(
        _h,
        _copy(arena, page),
        page.length,
        groups.length,
        out,
        outLen,
        err,
      ),
      err,
    );
    final int len = outLen.value;
    final Uint8List bytes = Uint8List.fromList(
      out.value.asTypedListOutOfLine(len),
    );
    _b._freeBytes(out.value, len);
    return bytes;
  });

  // ---------------------------------------------------------------- P6 直读命令
  //
  // 都在读连接上一个读事务里执行（只看已提交的行，不挡写连接），布局见 native/fushi_fsrs/src/store/
  // projections.rs；解包在 fushi_engine `srs_projections.dart`。调用方放后台 isolate。

  /// 优化器训练集：[lineages] 每项是一张卡的血统，[cardIds] 是它们的 53 位数字 id；[algorithm] 0 fsrs6 /
  /// 1 fsrs7 / 2 rwkv。
  Uint8List optimizerItems(
    List<List<String>> lineages,
    List<int> cardIds, {
    required int algorithm,
    required int utcOffsetMin,
    required int rolloverHour,
  }) => _command(_b.optimizerItems, _lineagePage(lineages, null), <int>[
    lineages.length,
    algorithm,
    utcOffsetMin,
    rolloverHour,
    ...cardIds,
  ]);

  /// RWKV 逐卡的保留评分行与摘要（[ids] 每卡 4 个：卡 / 笔记 / 牌组 / 预设）。
  Uint8List rwkvCards(
    List<List<String>> lineages,
    List<int> ids, {
    required int utcOffsetMin,
    required int rolloverHour,
  }) => _command(_b.rwkvRows, _lineagePage(lineages, null), <int>[
    lineages.length,
    0,
    utcOffsetMin,
    rolloverHour,
    0,
    ...ids,
  ]);

  /// RWKV 全量回放（[profileUid] 的日志一条语句扫出；[since] 之后的漏卡一并返回）。
  ///
  /// [rebaseSince] 给了就是局部重放（lib.rs `SrsCore::rwkv_replay`）：同一快照里算出 rowid 在它之后的日志
  /// 造成的分歧时刻，行从 [rowsFrom]（给了的话）或分歧时刻起取。
  Uint8List rwkvReplay(
    String profileUid,
    List<List<String>> lineages,
    List<int> ids, {
    required int utcOffsetMin,
    required int rolloverHour,
    required int since,
    int? rebaseSince,
    int? rowsFrom,
  }) => _command(_b.rwkvRows, _lineagePage(lineages, profileUid), <int>[
    lineages.length,
    1,
    utcOffsetMin,
    rolloverHour,
    since,
    rebaseSince ?? _noneI64,
    rowsFrom ?? _noneI64,
    ...ids,
  ]);

  /// Rust 侧的「无」（`NONE_I64` = i64::MIN）。
  static const int _noneI64 = -0x8000000000000000;

  /// RWKV 对齐的日志指纹（与 rowid 在 [since] 之后的行数），[withRows] 时连同这些新行。
  /// [incremental]：只数 rowid 在 [since] 之后的行（O(新增)），行数 / 最大 rowid 只算新增部分。
  Uint8List rwkvLogTail(
    String profileUid, {
    required int since,
    required bool withRows,
    bool incremental = false,
  }) => _command(
    _b.rwkvLogTail,
    _lineagePage(const <List<String>>[], profileUid),
    <int>[since, if (withRows) 1 else 0, if (incremental) 1 else 0],
  );

  static Uint8List _lineagePage(List<List<String>> lineages, String? profile) =>
      srsEncodeRows(2, <List<Object?>>[
        if (profile != null) <Object?>[-1, profile],
        for (int g = 0; g < lineages.length; g++)
          for (final String c in lineages[g]) <Object?>[g, c],
      ]);

  Uint8List _command(_CmdDart f, Uint8List page, List<int> args) => using((
    Arena arena,
  ) {
    final ffi.Pointer<ffi.Int64> a = arena<ffi.Int64>(
      args.isEmpty ? 1 : args.length,
    );
    a.asTypedListOutOfLine(args.isEmpty ? 1 : args.length).setAll(0, args);
    final ffi.Pointer<ffi.Pointer<ffi.Uint8>> out = arena();
    final ffi.Pointer<ffi.Size> outLen = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(
      _b,
      f(_h, _copy(arena, page), page.length, a, args.length, out, outLen, err),
      err,
    );
    final int len = outLen.value;
    final Uint8List bytes = Uint8List.fromList(
      out.value.asTypedListOutOfLine(len),
    );
    _b._freeBytes(out.value, len);
    return bytes;
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
    p.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
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
    p.asTypedListOutOfLine(b.length).setAll(0, b);
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
    throw SrsUpgradeNoSpaceException.tryParse(rc, message) ??
        SrsCoreException(rc, message);
  }
}

/// srs.db 上一条独立只读连接的读事务（[SrsCore.beginRead]）：所有查询看到开会话那一刻的同一个快照，
/// 不占 [SrsCore] 的读 / 写连接。同一时刻只许一个调用；[close] 回滚并关连接。
final class SrsReadSession {
  SrsReadSession._(this._b, this._handle, {required this.owned});

  /// 包装别的 isolate 开的同一个会话（不拥有，[close] 不关）。
  static SrsReadSession fromAddress(int address, {String? libraryPath}) =>
      SrsReadSession._(
        SrsCoreBindings.load(libraryPath: libraryPath),
        ffi.Pointer<ffi.Void>.fromAddress(address),
        owned: false,
      );

  final SrsCoreBindings _b;
  ffi.Pointer<ffi.Void> _handle;

  /// 本对象负责结束会话。
  final bool owned;

  /// 句柄地址（跨 isolate 传递用）。
  int get address => _handle.address;

  bool get isClosed => _handle == ffi.nullptr;

  /// 在会话的读事务里跑一条只读语句（写语句报错）。返回每行一个「列名 → 值」。
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) {
    if (isClosed) throw StateError('srs read session is closed');
    return SrsCore._rowsQuery(_b, _b.readQuery, _handle, sql, params);
  }

  void close() {
    if (isClosed) return;
    if (owned) _b.readEnd(_handle);
    _handle = ffi.nullptr;
  }
}

/// [SrsCore.sync2] 的结果：命令的 JSON 结果，以及发件 / 写 head 产出的文件（相对路径 → 字节）。
final class SrsSync2Result {
  const SrsSync2Result(this.json, this.files);

  final Object? json;
  final List<(String, Uint8List)> files;

  Map<String, Object?> get map => (json! as Map).cast<String, Object?>();

  /// `u32 json_len + JSON`，再 `u32 n` 与 n 组分帧的 `(路径, 字节)`（小端）。各文件是 [b] 上的视图（不逐个复制；
  /// 审查 S-9），[b] 由调用方交出、之后不再改。
  static SrsSync2Result decode(Uint8List b) {
    final ByteData d = ByteData.sublistView(b);
    int at = 0;
    int u32() {
      final int v = d.getUint32(at, Endian.little);
      at += 4;
      return v;
    }

    Uint8List take(int n) {
      final Uint8List s = Uint8List.sublistView(b, at, at + n);
      at += n;
      return s;
    }

    final Object? json = jsonDecode(utf8.decode(take(u32())));
    final int n = u32();
    final List<(String, Uint8List)> files = <(String, Uint8List)>[];
    for (int i = 0; i < n; i++) {
      final String path = utf8.decode(take(u32()));
      files.add((path, take(u32())));
    }
    return SrsSync2Result(json, files);
  }
}

/// 分帧：`u32 n`，再 n 个 `u32 len + 字节`（小端）。空列表 = 0 字节。
Uint8List srsSync2Frames(List<Uint8List> blobs) {
  final Uint8List out = Uint8List(srsSync2FramesLength(blobs));
  srsSync2FramesInto(out, blobs);
  return out;
}

/// [srsSync2Frames] 的总字节数。
int srsSync2FramesLength(List<Uint8List> blobs) {
  if (blobs.isEmpty) return 0;
  int total = 4;
  for (final Uint8List x in blobs) {
    total += 4 + x.length;
  }
  return total;
}

/// 把 [blobs] 分帧写进 [out]（长度必须是 [srsSync2FramesLength]）：调用方给原生缓冲的视图，段只拷这一次。
void srsSync2FramesInto(Uint8List out, List<Uint8List> blobs) {
  if (blobs.isEmpty) return;
  final ByteData d = ByteData.sublistView(out);
  d.setUint32(0, blobs.length, Endian.little);
  int at = 4;
  for (final Uint8List x in blobs) {
    d.setUint32(at, x.length, Endian.little);
    at += 4;
    out.setRange(at, at + x.length, x);
    at += x.length;
  }
}
