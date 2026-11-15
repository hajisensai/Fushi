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
typedef _SetTempDirC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _SetTempDirDart =
    int Function(
      ffi.Pointer<ffi.Uint8>,
      int,
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
typedef _DiagCountsC =
    ffi.Size Function(ffi.Pointer<ffi.Int64> out, ffi.Size n);
typedef _DiagCountsDart = int Function(ffi.Pointer<ffi.Int64> out, int n);
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
      setTempDir = lib.lookupFunction<_SetTempDirC, _SetTempDirDart>(
        'ffsrs_set_temp_dir',
      ),
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
      readConcurrency = lib.lookupFunction<_StateC, _StateDart>(
        'ffsrs_store_read_concurrency',
      ),
      diagCounts = lib.lookupFunction<_DiagCountsC, _DiagCountsDart>(
        'ffsrs_store_diag_counts',
        isLeaf: true,
      ),
      historyStates = lib.lookupFunction<_HistC, _HistDart>(
        'ffsrs_store_history_states',
      ),
      optimizerItems = lib.lookupFunction<_CmdC, _CmdDart>(
        'ffsrs_store_optimizer_items',
      ),
      calibrationItems = lib.lookupFunction<_CmdC, _CmdDart>(
        'ffsrs_store_calibration_items',
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
  final _SetTempDirDart setTempDir;
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
  final _StateDart readConcurrency;
  final _DiagCountsDart diagCounts;
  final _HistDart historyStates;
  final _CmdDart optimizerItems;
  final _CmdDart calibrationItems;
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

/// [SrsCore.diagCounts] 的一次读数（native/fushi_fsrs/src/store/ffi.rs `ffsrs_store_diag_counts`）。
final class SrsCoreDiagCounts {
  const SrsCoreDiagCounts({
    required this.openHandles,
    required this.liveCores,
    required this.readSessions,
    required this.pooledReaders,
    required this.sqliteBytes,
    required this.sqliteHighwaterBytes,
    required this.dbBytes,
    required this.walBytes,
  });

  /// 原生一次写出的项数（Rust `DIAG_COUNT_LEN`）。
  static const int length = 8;

  /// 句柄表里打开着的库。
  final int openHandles;

  /// 还没释放的库结构体（含已关闭、在途调用还握着的）：大于 [openHandles] = 有退役的库还驻留。
  final int liveCores;

  /// 没结束的只读会话。
  final int readSessions;

  /// 各库只读连接池开着的连接总数。
  final int pooledReaders;

  /// 本库内置 SQLite 的堆用量（页缓存等）与其高水位，字节。
  final int sqliteBytes;
  final int sqliteHighwaterBytes;

  /// 打开着的库文件与其 `-wal` 的总字节（看同步中库 / WAL 有没有在胀）。
  final int dbBytes;
  final int walBytes;

  /// 面包屑里的紧凑写法：`srs=开/存活 sess=… rd=… sqlite=当前/高水位MB db=…MB wal=…MB`。
  String describe() =>
      'srs=$openHandles/$liveCores sess=$readSessions rd=$pooledReaders '
      'sqlite=${sqliteBytes >> 20}/${sqliteHighwaterBytes >> 20}MB '
      'db=${dbBytes >> 20}MB wal=${walBytes >> 20}MB';
}

/// 一个打开的 srs.db。
/// [SrsCore.snapshotQuery] 拒绝非只读查询时的错误消息（与 Rust `store::NOT_SNAPSHOT` 相同）。
const String kSrsNotSnapshotQuery = 'srs: not a snapshot query';

/// srs.db 经 Drift 执行器只读：写语句、事务控制语句、PRAGMA 的报错都以它开头（与 Rust `store::READ_ONLY` 相同）。
/// 生产代码的每一笔写入都是内核命令（`SrsCore.sync2` 等）。
const String kSrsReadOnlyExecutor =
    'srs: srs.db is read-only through the Drift executor';

/// 这个原生库没编进测试专用的原始 SQL 通道（cargo feature `raw_sql`，native/fushi_fsrs/Cargo.toml）时
/// [SrsCore.debugExecRaw] / [SrsCore.debugSelectRaw] / [SrsCore.debugExecBatchRaw] 的报错（与 Rust
/// `store::RAW_SQL_ABSENT` 相同）。发布 / 随包构建都不带；测试用的库（CI 包测试 / 单测分片、dist worker、本机备库
/// 脚本）带。
const String kSrsRawSqlAbsent =
    'srs: the raw SQL channel is not built into this library (cargo feature raw_sql)';

final class SrsCore {
  SrsCore._(this._b, this._handle, {required this.owned});

  final SrsCoreBindings _b;
  ffi.Pointer<ffi.Void> _handle;

  /// 本对象负责关闭（[fromAddress] 包出来的不负责）。
  final bool owned;

  /// 自本次开机以来的毫秒，含睡眠、不受改系统时间影响（`ffsrs_boot_time_ms`）。可信时间
  /// （[SrsTrustedClock]）按它推算；取不到时抛 [StateError]（原生库是硬依赖，不退回别的时钟）。
  int bootTimeMs() => _b._bootTimeMs();

  /// 设本进程 srs.db 的 SQLite 临时目录（大排序、整理、备份快照的溢出文件）：整个进程只设一次，必须在打开任何
  /// srs.db 之前（`ffsrs_set_temp_dir`）。再传同一个目录是空操作，传别的目录抛 [SrsCoreException]。
  ///
  /// Android 上必须设（没有平台默认临时目录，不设打不开库），传 app 的 cache 目录这种跟进程走、不会被删的目录；
  /// 不要传某份库所在的目录（备份恢复会在同一进程开解压到临时目录的源库，那个目录随后被删）。
  static void useTempDirectory(String dir, {String? libraryPath}) {
    final SrsCoreBindings b = SrsCoreBindings.load(libraryPath: libraryPath);
    using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> p, int n) = _utf8(arena, dir);
      final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
      err.value = ffi.nullptr;
      _check(b, b.setTempDir(p, n, err), err);
    });
  }

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

  /// 进程级内存诊断计数（`ffsrs_store_diag_counts`，不需要打开的库，任意 isolate 可调）：
  /// 移动端内存耗尽闪退（BUG-4075）的取证面包屑用。原生库加载不了返回 null。
  static SrsCoreDiagCounts? diagCounts({String? libraryPath}) {
    final SrsCoreBindings b;
    try {
      b = SrsCoreBindings.load(libraryPath: libraryPath);
    } on SrsCoreUnavailableError {
      return null;
    }
    return using((Arena arena) {
      final ffi.Pointer<ffi.Int64> out = arena<ffi.Int64>(
        SrsCoreDiagCounts.length,
      );
      final int n = b.diagCounts(out, SrsCoreDiagCounts.length);
      if (n < SrsCoreDiagCounts.length) return null;
      return SrsCoreDiagCounts(
        openHandles: out[0],
        liveCores: out[1],
        readSessions: out[2],
        pooledReaders: out[3],
        sqliteBytes: out[4],
        sqliteHighwaterBytes: out[5],
        dbBytes: out[6],
        walBytes: out[7],
      );
    });
  }

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

  /// **测试专用**的原始通道：在写连接上执行一条任意语句（测试里直接改库造场景——改缓存行、删本机状态行、装触发器、
  /// 读写 PRAGMA）。生产代码不得调用（守卫 `srs_read_only_executor_guard_test.dart`）：srs.db 的每一笔写入都是内核命令，
  /// Drift 执行器只读（[kSrsReadOnlyExecutor]）。只有带 cargo feature `raw_sql` 的库里有：发布构建里能写库的这段原生代码
  /// 不在，调用抛 [SrsCoreException]（消息 [kSrsRawSqlAbsent]），所以生产代码里的调用在测试里是绿的、到发布包里才失败。
  ///
  /// [select] 时返回「列名行 + 结果行」（PRAGMA、`… RETURNING` 之类有结果行的语句），否则返回一行
  /// `[变更行数, last_insert_rowid]`；都是 [srsDecodeRows] 的页。语句跑完写连接必须回到 autocommit：BEGIN / SAVEPOINT
  /// 这类会把事务留到调用之后的语句当场回滚并抛错。
  Uint8List debugExecRaw(
    String sql, [
    List<Object?> params = const <Object?>[],
    bool select = false,
  ]) => _exec(sql, params, select ? 5 : 4);

  /// [debugExecRaw] 的查询形态：结果行按列名成 Map。
  List<Map<String, Object?>> debugSelectRaw(
    String sql, [
    List<Object?> params = const <Object?>[],
  ]) {
    final (int _, List<List<Object?>> rows) = srsDecodeRows(
      debugExecRaw(sql, params, true),
    );
    final List<String> names = rows.first.cast<String>();
    return <Map<String, Object?>>[
      for (final List<Object?> r in rows.skip(1))
        <String, Object?>{
          for (int i = 0; i < names.length; i++) names[i]: r[i],
        },
    ];
  }

  /// Drift 内联执行器的查询（`runSelect`，fushi_engine `srs_database_executor.dart` 的 `SrsInlineExecutor`）：在内核
  /// 专用的一条只读连接上跑，只看已提交的数据、不排写锁（native/fushi_fsrs/src/store/mod.rs `SrsCore::select`）。
  /// 不是只读查询（写语句、PRAGMA、事务控制语句）不执行、抛 [SrsCoreException]，消息以 [kSrsReadOnlyExecutor] 开头。
  /// 返回页：列名行 + 结果行。
  Uint8List execQuery(String sql, List<Object?> params) =>
      _exec(sql, params, 2);

  /// Drift 查询道的查询（fushi_engine `srs_database_executor.dart` 的读查询那一路）：一律在内核的只读连接池
  /// 里执行，并发的查询各占一条连接、互不排队，只看已提交的数据（native/fushi_fsrs/src/store/mod.rs
  /// `SrsCore::snapshot_select`）。不是只读查询（PRAGMA、`… RETURNING` 等）不执行、抛 [SrsCoreException]，
  /// 消息为 [kSrsNotSnapshotQuery]。返回页同 [execQuery]。
  Uint8List snapshotQuery(String sql, List<Object?> params) =>
      _exec(sql, params, 3);

  /// [mode]：2 = 内联执行器的只读查询，3 = 查询道的只读查询，4 / 5 = 测试专用的原始通道（写连接；5 返回结果行）
  /// （ffi.rs `ffsrs_store_exec`；0 / 1 是以前 Drift 写语句的入口，内核一律拒绝）。
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

  /// [debugExecRaw] 的批量版（**测试专用**）：[applications] 每项是（语句下标, 参数），整批在写连接的一个 SAVEPOINT
  /// 里执行，一条出错整批不落。同 [debugExecRaw] 只有带 `raw_sql` 的库里有。
  void debugExecBatchRaw(
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

  /// [profile] 此刻的进程内刷新键（内核 `refresh_keys`，native/fushi_fsrs/src/store/refresh.rs）：牌组树 / 修改记录 /
  /// 角标 / 统计 / RWKV 分数表这些缓存「还能不能用」的判据，由内核在内存里按 profile 持有、在每次提交之后推进。各键
  /// 是不透明串，只比相等：相等 = 这期间没有那一类变化（同一次打开库里只增不减；每次打开库换一个随机前缀）。
  ///
  /// 只读内存（不碰通道、不拿写锁、不读库），在调用方 isolate 上同步调。库已关闭（本对象已关，或 [fromAddress]
  /// 包的句柄的拥有者已关库）→ null。
  SrsRefreshKeys? refreshKeys(String profile) {
    if (isClosed) return null;
    final Map<String, Object?> k;
    try {
      k = sync2(<String, Object?>{
        'op': 'refresh_keys',
        'profile': profile,
      }).map;
    } on SrsCoreException catch (e) {
      if (e.message == kSrsCoreClosed) return null;
      rethrow;
    }
    return (
      content: k['content']! as String,
      structure: k['structure']! as String,
      rwkv: k['rwkv']! as String,
      stats: k['stats']! as String,
      landed: k['landed']! as String,
    );
  }

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

  /// 复习统计页校准图的训练集：与 [optimizerItems] 同一布局，末尾按列接每个条目的时刻 / 日志数字 ID / 间隔天数 /
  /// 卡数字 id / 记住（`ffsrs_store_calibration_items`）。参数同 [optimizerItems]。
  Uint8List calibrationItems(
    List<List<String>> lineages,
    List<int> cardIds, {
    required int algorithm,
    required int utcOffsetMin,
    required int rolloverHour,
  }) => _command(_b.calibrationItems, _lineagePage(lineages, null), <int>[
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
  ///
  /// 结果随日志总量线性（每条保留评分约 96 字节），从原生内存直接拷进 [TransferableTypedData]：在后台 isolate
  /// 里调用时交回调用方不再整块复制，`materialize` 也不复制（[_commandTransferable]）。
  TransferableTypedData rwkvReplay(
    String profileUid,
    List<List<String>> lineages,
    List<int> ids, {
    required int utcOffsetMin,
    required int rolloverHour,
    required int since,
    int? rebaseSince,
    int? rowsFrom,
  }) => _commandTransferable(
    _b.rwkvRows,
    _lineagePage(lineages, profileUid),
    <int>[
      lineages.length,
      1,
      utcOffsetMin,
      rolloverHour,
      since,
      rebaseSince ?? _noneI64,
      rowsFrom ?? _noneI64,
      ...ids,
    ],
  );

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

  Uint8List _command(_CmdDart f, Uint8List page, List<int> args) =>
      _commandWith(f, page, args, Uint8List.fromList);

  /// [_command]，结果直接拷进 [TransferableTypedData]（大结果跨 isolate 交回时少一份整块副本）。
  TransferableTypedData _commandTransferable(
    _CmdDart f,
    Uint8List page,
    List<int> args,
  ) => _commandWith(
    f,
    page,
    args,
    (Uint8List native) => TransferableTypedData.fromList(<TypedData>[native]),
  );

  /// 跑一条交回字节的内核命令；[take] 在原生缓冲区释放之前把它（原生内存上的视图）拷成调用方要的形态。
  T _commandWith<T>(
    _CmdDart f,
    Uint8List page,
    List<int> args,
    T Function(Uint8List native) take,
  ) => using((Arena arena) {
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
    final T result = take(out.value.asTypedListOutOfLine(len));
    _b._freeBytes(out.value, len);
    return result;
  });

  /// Drift 查询道（[snapshotQuery]）的并发上限：内核只读连接池的连接数上限，按本机核数算
  /// （native/fushi_fsrs/src/store/read_pool.rs `read_concurrency`）。查询道的 worker 数取它，不另写常量。
  int get readConcurrency => using((Arena arena) {
    final ffi.Pointer<ffi.Int32> out = arena();
    final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
    err.value = ffi.nullptr;
    _check(_b, _b.readConcurrency(_h, out, err), err);
    return out.value;
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

/// 已关闭的句柄上调用时内核报的错误文本（native/fushi_fsrs/src/store/mod.rs `CLOSED`）。
const String kSrsCoreClosed = 'srs store is closed';

/// [SrsCore.refreshKeys] 的结果（键的含义见 native/fushi_fsrs/src/store/refresh.rs）：
/// - [content]：复习日志与界面状态以外的事件落库、可见性变化、重读本机状态；
/// - [structure]：[content] 再加界面状态类修改记录（牌组收起 / 展开、排序位）——牌组树与 profile 修改记录的缓存键；
/// - [rwkv]：RWKV 分数表整表重查（牌组 / 配置类事件、别的设备的事件落库；收段会话期间攒着、结束时并成一次）；
/// - [stats]：会改变统计结果的事件（落库事件与可见性变化，去掉界面状态类）；
/// - [landed]：任何落库事件与可见性变化（与落盘修订号同口径，但含收段通道自己做完的片）。
typedef SrsRefreshKeys = ({
  String content,
  String structure,
  String rwkv,
  String stats,
  String landed,
});

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
