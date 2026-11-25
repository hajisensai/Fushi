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

  /// store/ffi.rs 的状态码：-1 一般错误，-2 参数错，-4 / -5 / -6 打开时的代际状态（[SrsStoreOpenBlocked]），
  /// -100 panic。
  final int code;
  final String message;

  /// 按状态码与错误文本给出类型化的异常：打开时的代际状态（[SrsStoreOpenBlocked]）、新代还没接线 / 已删的命令
  /// （[SrsCoreUnwiredException] / [SrsCoreRemovedException]）、一条改动超过载荷上限（[SrsOpTooLargeException]）等，
  /// 其余是一般的 [SrsCoreException]。
  static SrsCoreException of(int code, String message) =>
      SrsStoreOpenBlocked.tryParse(code, message) ??
      SrsCoreUnwiredException.tryParse(code, message) ??
      SrsCoreRemovedException.tryParse(code, message) ??
      SrsProfileUnboundException.tryParse(code, message) ??
      SrsCoreReadOnlyException.tryParse(code, message) ??
      SrsOpTooLargeException.tryParse(code, message) ??
      SrsCoreException(code, message);

  @override
  String toString() => 'SrsCoreException($code): $message';
}

/// 新代分发器里**还没接线**的命令（native/fushi_fsrs/src/store/gen4/kernel.rs `UNWIRED`）：归别的模块接线，
/// 调用方要给出明确的「暂不可用」状态，不当成功、不崩。[owner] 是负责接线的模块号（如 `G9-4`、`G8-7`）。
final class SrsCoreUnwiredException extends SrsCoreException {
  const SrsCoreUnwiredException(
    super.code,
    super.message, {
    required this.op,
    required this.owner,
  });

  /// 错误文本前缀（kernel.rs `UNWIRED`），后面是 ``: `<op>` belongs to <owner>``。
  static const String prefix = 'gen4: not wired yet';

  /// 没接线的命令名（或 C 入口名）。
  final String op;

  /// 负责接线的模块号。
  final String owner;

  static final RegExp _shape = RegExp(
    r'^gen4: not wired yet: `([^`]+)` belongs to (.+)$',
  );

  static SrsCoreUnwiredException? tryParse(int code, String message) {
    final RegExpMatch? m = _shape.firstMatch(message);
    if (m == null) return null;
    return SrsCoreUnwiredException(
      code,
      message,
      op: m.group(1)!,
      owner: m.group(2)!,
    );
  }

  @override
  String toString() =>
      'SrsCoreUnwiredException: `$op` is not wired yet ($owner)';
}

/// 新代里**已删**的命令（kernel.rs `REMOVED`）：调用方不该再发。出现 = Dart 还有没改掉的调用点。
final class SrsCoreRemovedException extends SrsCoreException {
  const SrsCoreRemovedException(super.code, super.message, {required this.op});

  /// 错误文本前缀（kernel.rs `REMOVED`）。
  static const String prefix = 'gen4: removed';

  final String op;

  static final RegExp _shape = RegExp(r'^gen4: removed: `([^`]+)`');

  static SrsCoreRemovedException? tryParse(int code, String message) {
    final RegExpMatch? m = _shape.firstMatch(message);
    if (m == null) return null;
    return SrsCoreRemovedException(code, message, op: m.group(1)!);
  }

  @override
  String toString() => 'SrsCoreRemovedException: `$op` was removed in gen4';
}

/// 这个 profile 在新代库里还没有集合（native/fushi_fsrs/src/store/gen4/dispatch.rs `col_of`）：绑定由迁移或身份命令
/// 建，身份命令 `identity` 归 G9-4（还没接线）。全新安装、迁移之后新建的 profile 在 G9-4 之前都是这个状态。
final class SrsProfileUnboundException extends SrsCoreException {
  const SrsProfileUnboundException(
    super.code,
    super.message, {
    required this.profile,
  });

  /// 负责建绑定的模块号。
  static const String owner = 'G9-4';

  final String profile;

  static final RegExp _shape = RegExp(
    r'^gen4: profile (.+) has no collection on this device',
  );

  static SrsProfileUnboundException? tryParse(int code, String message) {
    final RegExpMatch? m = _shape.firstMatch(message);
    if (m == null) return null;
    return SrsProfileUnboundException(code, message, profile: m.group(1)!);
  }

  @override
  String toString() =>
      'SrsProfileUnboundException: profile $profile has no gen4 collection '
      'yet (bindings arrive with $owner)';
}

/// 只读打开（[SrsOpenMode.secondary]）的库上发了写命令（gen4/kernel.rs `READ_ONLY`）：写要交给主进程。
final class SrsCoreReadOnlyException extends SrsCoreException {
  const SrsCoreReadOnlyException(super.code, super.message);

  /// 错误文本（kernel.rs `READ_ONLY`）的开头。
  static const String prefix = 'gen4 store: opened read-only (secondary)';

  static SrsCoreReadOnlyException? tryParse(int code, String message) =>
      message.startsWith(prefix)
      ? SrsCoreReadOnlyException(code, message)
      : null;

  @override
  String toString() => 'SrsCoreReadOnlyException: $message';
}

/// 内核拒收一条载荷超过上限（16 MiB，native/fushi_fsrs/src/gen4/op.rs `MAX_OP_PAYLOAD`）的改动，整笔回滚：本机写入
/// （`gen4 store: op too large: …; nothing was saved`）、`.fushisrs` 导入（`gen4 import: op too large: …; nothing was
/// imported`）、.apkg / 文本导入落库的那一批都报这一句。多半是字段里内嵌了图片 / 文件。界面按**类型**认它给专门的
/// 本地化提示（`fushi/lib/src/srs/srs_action_error_text.dart`），不在界面里匹配内核的英文原话。
final class SrsOpTooLargeException extends SrsCoreException {
  const SrsOpTooLargeException(super.code, super.message);

  /// 内核报错里的标记（op.rs `ERR_OP_TOO_LARGE` 加冒号；前面可能有 `gen4 store: ` / `gen4 import: ` 等前缀）。改内核那句
  /// 要同步改这里。
  static const String marker = 'op too large: ';

  static SrsOpTooLargeException? tryParse(int code, String message) =>
      message.contains(marker) ? SrsOpTooLargeException(code, message) : null;

  @override
  String toString() => 'SrsOpTooLargeException: $message';
}

/// 库目录的代际状态（native/fushi_fsrs/src/store/gen4/migrate.rs `GenState` 的线上名）。
enum SrsGenState {
  /// 新代库可用；或什么都没有、辅助进程比主进程先到（等主进程建库）。
  ready('ready'),

  /// 有协议 3 的 `srs.db` 要迁移。
  needsMigration('needsMigration'),

  /// 别的进程正在迁移（拿着换代锁）。
  migratingElsewhere('migratingElsewhere'),

  /// 只剩封存的旧库 / 墓碑，新代库不见了。不建空库顶上，给恢复页。
  sealedOldOnly('sealedOldOnly'),

  /// 上次迁移没完成（原因由内核判定，[SrsGen4MigrationFailure]）。不自动重跑，给恢复页。
  migrationFailed('migrationFailed');

  const SrsGenState(this.wire);

  final String wire;

  /// 线上名 → 状态；不认识的为 null（调用方当一般错误报，不猜）。
  static SrsGenState? tryParse(Object? wire) {
    for (final SrsGenState s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// [SrsGenState.migrationFailed] 的原因（migrate.rs `Failure::wire`）。判定只在内核状态命令一处，与「是不是失败」同一份
/// 身份核对；Dart 不读报告文件、不另判。
enum SrsGen4MigrationFailureReason {
  /// 上次迁移对拍有差异、已撤回（有报告）。
  fail('fail'),

  /// 上次迁移对拍没法做全（旧库一侧的缓存基准拿不到，例如笔记缺笔记类型）、已撤回（有报告）。
  incomplete('incomplete'),

  /// 上次迁移准备某个 profile 时出错、已撤回（有报告）。
  error('error'),

  /// 旧库不见了、只剩迁移临时文件：上次跑到一半进程没了（没有报告）。
  interrupted('interrupted');

  const SrsGen4MigrationFailureReason(this.wire);

  final String wire;

  /// 线上名 → 原因；不认识的为 null。
  static SrsGen4MigrationFailureReason? tryParse(Object? wire) {
    for (final SrsGen4MigrationFailureReason r in values) {
      if (r.wire == wire) return r;
    }
    return null;
  }
}

/// 上次迁移没完成的原因与诊断报告（migrate.rs `Failure::json`：`{reason, reportPath?}`）。状态命令、打开错误、
/// 中止的迁移结论三处同一形状。
final class SrsGen4MigrationFailure {
  const SrsGen4MigrationFailure({required this.reason, this.reportPath});

  final SrsGen4MigrationFailureReason reason;

  /// 诊断报告的路径（只含 ID 与计数）；[SrsGen4MigrationFailureReason.interrupted] 没有。
  final String? reportPath;

  /// `null` / 不是对象 / 原因不认识 = null（内核与 Dart 同包发布，认不出只可能是坏数据，不猜）。
  static SrsGen4MigrationFailure? tryParse(Object? j) {
    if (j is! Map) return null;
    final SrsGen4MigrationFailureReason? reason =
        SrsGen4MigrationFailureReason.tryParse(j['reason']);
    if (reason == null) return null;
    return SrsGen4MigrationFailure(
      reason: reason,
      reportPath: j['reportPath'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SrsGen4MigrationFailure &&
      other.reason == reason &&
      other.reportPath == reportPath;

  @override
  int get hashCode => Object.hash(reason, reportPath);

  @override
  String toString() =>
      'SrsGen4MigrationFailure(${reason.wire}${reportPath == null ? '' : ', $reportPath'})';
}

/// 打开模式（`ffsrs_store_open_mode` 的 `mode`）。
enum SrsOpenMode {
  /// 主进程：唯一的写者，全新安装时建空库。
  primary(0),

  /// 查词弹窗等辅助进程：只读，不建库、不迁移；写命令报只读。
  secondary(1);

  const SrsOpenMode(this.wire);

  final int wire;
}

/// 打开时库目录处在某个代际状态、句柄没开出来（库一概没动）。各子类对应 store/ffi.rs 的一个返回码：
///
/// - [SrsStoreNotMigrated]（`STORE_NOT_MIGRATED` -4）：还没有新代库，[SrsStoreNotMigrated.state] 区分要迁移 /
///   只剩封存旧库 / 上次迁移失败 / 辅助进程先到；
/// - [SrsStoreMigrating]（`STORE_MIGRATING` -5）：别的进程正拿着换代锁；
/// - [SrsStoreLegacyUnmigrated]（`STORE_LEGACY_UNMIGRATED` -6）：新代库旁边有一份没迁移过的协议 3 库。
sealed class SrsStoreOpenBlocked extends SrsCoreException {
  const SrsStoreOpenBlocked(super.code, super.message);

  static SrsStoreOpenBlocked? tryParse(int code, String message) =>
      switch (code) {
        SrsStoreNotMigrated.statusCode => SrsStoreNotMigrated._parse(message),
        SrsStoreMigrating.statusCode => SrsStoreMigrating(message),
        SrsStoreLegacyUnmigrated.statusCode => SrsStoreLegacyUnmigrated(
          message,
        ),
        _ => null,
      };
}

/// 还没有新代库（`STORE_NOT_MIGRATED`）。
final class SrsStoreNotMigrated extends SrsStoreOpenBlocked {
  const SrsStoreNotMigrated(String message, this.state, {this.failure})
    : super(statusCode, message);

  static const int statusCode = -4;

  final SrsGenState state;

  /// [SrsGenState.migrationFailed] 时内核判定的原因（与 [state] 同一次判定）；其余状态 = null。
  final SrsGen4MigrationFailure? failure;

  /// 错误文本末尾是 `{"failure": ..., "state": <线上名>}`（store/ffi.rs `open_error`，migrate.rs `GenState::json`；
  /// 前面的说明文字里没有 `{`）。状态读不出来 = null（照一般错误报）。
  static SrsStoreNotMigrated? _parse(String message) {
    final int at = message.indexOf('{');
    if (at < 0) return null;
    try {
      final Object? j = jsonDecode(message.substring(at));
      if (j is! Map) return null;
      final SrsGenState? s = SrsGenState.tryParse(j['state']);
      return s == null
          ? null
          : SrsStoreNotMigrated(
              message,
              s,
              failure: SrsGen4MigrationFailure.tryParse(j['failure']),
            );
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'SrsStoreNotMigrated(${state.wire}): $message';
}

/// 别的进程正在迁移（`STORE_MIGRATING`）。
final class SrsStoreMigrating extends SrsStoreOpenBlocked {
  const SrsStoreMigrating(String message) : super(statusCode, message);

  static const int statusCode = -5;

  @override
  String toString() => 'SrsStoreMigrating: $message';
}

/// 新代库旁边有一份没迁移过的协议 3 `srs.db`（`STORE_LEGACY_UNMIGRATED`）：那份库没动，新代库也没开。
final class SrsStoreLegacyUnmigrated extends SrsStoreOpenBlocked {
  const SrsStoreLegacyUnmigrated(String message) : super(statusCode, message);

  static const int statusCode = -6;

  @override
  String toString() => 'SrsStoreLegacyUnmigrated: $message';
}

typedef _OpenC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Int32,
      ffi.Pointer<ffi.Pointer<ffi.Void>>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _OpenDart =
    int Function(
      ffi.Pointer<ffi.Uint8>,
      int,
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
      open = lib.lookupFunction<_OpenC, _OpenDart>('ffsrs_store_open_mode'),
      setTempDir = lib.lookupFunction<_SetTempDirC, _SetTempDirDart>(
        'ffsrs_set_temp_dir',
      ),
      close = lib.lookupFunction<_CloseC, _CloseDart>('ffsrs_store_close'),
      closeBegin = lib.lookupFunction<_CloseC, _CloseDart>(
        'ffsrs_store_close_begin',
      ),
      snapshot = lib.lookupFunction<_SnapshotC, _SnapshotDart>(
        'ffsrs_store_snapshot',
      ),
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

  /// 收尾关闭：等在途命令退出（已被 [closeBegin] 取消）、关连接。会阻塞，只在后台 isolate 调（[SrsCore.close]）。
  final _CloseDart close;

  /// 开始关闭：摘句柄、取消在途命令，不等任何东西（任意线程可调）。
  final _CloseDart closeBegin;
  final _SnapshotDart snapshot;
  final _QueryDart debugQuery;
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

  /// 不针对已打开库的全局 JSON 命令（`ffsrs_call`，lib.rs `dispatch` → gen4/kernel.rs `global`）：回 `ok` 的值，
  /// `error` 抛 [SrsCoreException]（按文本类型化，见 [SrsCoreException.of]）。
  Object? callGlobal(Map<String, Object?> request) {
    final ffi.Pointer<ffi.Char> req = jsonEncode(
      request,
    ).toNativeUtf8().cast<ffi.Char>();
    final ffi.Pointer<ffi.Char> resp;
    try {
      resp = _fsrs.bindings.ffsrs_call(req);
    } finally {
      calloc.free(req);
    }
    if (resp == ffi.nullptr) {
      throw const SrsCoreException(-1, 'null response from ffsrs_call');
    }
    final String text;
    try {
      text = resp.cast<Utf8>().toDartString();
    } finally {
      _freeString(resp);
    }
    final Object? body = jsonDecode(text);
    if (body is! Map) throw SrsCoreException(-1, 'bad response: $text');
    if (body.containsKey('error')) {
      throw SrsCoreException.of(-1, '${body['error']}');
    }
    return body['ok'];
  }

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
    required this.pooledReaders,
    required this.sqliteBytes,
    required this.sqliteHighwaterBytes,
    required this.dbBytes,
    required this.walBytes,
  });

  /// 原生一次写出的项数（Rust `DIAG_COUNT_LEN`）。
  static const int length = 7;

  /// 句柄表里打开着的库。
  final int openHandles;

  /// 还没释放的库结构体（含已关闭、在途调用还握着的）：大于 [openHandles] = 有退役的库还驻留。
  final int liveCores;

  /// 各库只读连接池开着的连接总数。
  final int pooledReaders;

  /// 本库内置 SQLite 的堆用量（页缓存等）与其高水位，字节。
  final int sqliteBytes;
  final int sqliteHighwaterBytes;

  /// 打开着的库文件与其 `-wal` 的总字节（看同步中库 / WAL 有没有在胀）。
  final int dbBytes;
  final int walBytes;

  /// 面包屑里的紧凑写法：`srs=开/存活 rd=… sqlite=当前/高水位MB db=…MB wal=…MB`。
  String describe() =>
      'srs=$openHandles/$liveCores rd=$pooledReaders '
      'sqlite=${sqliteBytes >> 20}/${sqliteHighwaterBytes >> 20}MB '
      'db=${dbBytes >> 20}MB wal=${walBytes >> 20}MB';
}

/// 这个原生库没编进测试专用的原始 SQL 通道（cargo feature `raw_sql`，native/fushi_fsrs/Cargo.toml）时
/// [SrsCore.debugExecRaw] / [SrsCore.debugSelectRaw] / [SrsCore.debugExecBatchRaw] 的报错（与 Rust
/// `store::RAW_SQL_ABSENT` 相同）。发布 / 随包构建都不带；测试用的库（CI 包测试 / 单测分片、dist worker、本机备库
/// 脚本）带。
const String kSrsRawSqlAbsent =
    'srs: the raw SQL channel is not built into this library (cargo feature raw_sql)';

/// 一个打开的 SRS 库（新代 `srs4.db`）。
final class SrsCore {
  SrsCore._(
    this._b,
    this._handle, {
    required this.owned,
    this.mode = SrsOpenMode.primary,
  });

  final SrsCoreBindings _b;
  ffi.Pointer<ffi.Void> _handle;

  /// 本对象负责关闭（[fromAddress] 包出来的不负责）。
  final bool owned;

  /// 打开模式：[SrsOpenMode.secondary] 的库只读（写命令报 [SrsCoreReadOnlyException]），开库时的注册类写入要跳过。
  /// [fromAddress] 包出来的取调用方给的值（worker 只发读写命令，不看它）。
  final SrsOpenMode mode;

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

  /// 在当前 isolate 同步打开库目录 [dir]（`<数据库目录>`，新代库 `srs4.db` 在它里面）的新代库
  /// （`ffsrs_store_open_mode`，native/fushi_fsrs/src/store/gen4/files.rs 的打开模式）。[mode] 缺省 Primary：
  /// 全新安装时建空库。只给测试与已在后台 isolate 里的代码用，app 走 [openInBackground]（守卫
  /// fushi/test/build/srs_store_open_off_ui_isolate_guard_test.dart）。
  ///
  /// 打不开时库目录的代际状态抛 [SrsStoreOpenBlocked] 的子类（要迁移 / 别的进程在迁移 / 旁边有没迁移的旧库），
  /// 绝不静默打开协议 3 的 `srs.db`；别的错误抛 [SrsCoreException]。
  static SrsCore open(
    String dir, {
    SrsOpenMode mode = SrsOpenMode.primary,
    String? libraryPath,
  }) {
    final SrsCoreBindings b = SrsCoreBindings.load(libraryPath: libraryPath);
    return using((Arena arena) {
      final (ffi.Pointer<ffi.Uint8> p, int n) = _utf8(arena, dir);
      final ffi.Pointer<ffi.Pointer<ffi.Void>> out = arena();
      final ffi.Pointer<ffi.Pointer<ffi.Char>> err = arena();
      err.value = ffi.nullptr;
      final int rc = b.open(p, n, mode.wire, out, err);
      _check(b, rc, err);
      return SrsCore._(b, out.value, owned: true, mode: mode);
    });
  }

  /// 在后台 isolate 打开 [dir] 的新代库（同 [open]），返回的句柄归调用方拥有（[close] 关库）。产品代码一律走这里。
  ///
  /// Primary 首次打开要在换代锁里建库、补做中断的封存，Android / iOS 上 UI isolate 跑在平台主线程，在那里同步 [open]
  /// 会占住主线程（3.1.0 白屏）。后台 isolate 打开后只把句柄号（原生句柄表里的编号，进程内通用）带回来；打不开时
  /// 的 [SrsStoreOpenBlocked] 原样传回。
  static Future<SrsCore> openInBackground(
    String dir, {
    SrsOpenMode mode = SrsOpenMode.primary,
    String? libraryPath,
  }) async {
    final SrsCoreBindings b = SrsCoreBindings.load(libraryPath: libraryPath);
    final String? resolvedLibraryPath = b.libraryPath;
    final int address = await Isolate.run(
      () => _openAddress(dir, mode, resolvedLibraryPath),
      debugName: 'srs-store-open',
    );
    return SrsCore._(
      b,
      ffi.Pointer<ffi.Void>.fromAddress(address),
      owned: true,
      mode: mode,
    );
  }

  /// [openInBackground] 的后台一半（顶层签名只带可发送的参数，闭包不捕获 [SrsCoreBindings]）。
  static int _openAddress(String dir, SrsOpenMode mode, String? libraryPath) =>
      open(dir, mode: mode, libraryPath: libraryPath).address;

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
        pooledReaders: out[2],
        sqliteBytes: out[3],
        sqliteHighwaterBytes: out[4],
        dbBytes: out[5],
        walBytes: out[6],
      );
    });
  }

  /// 包装别的 isolate 打开的同一个句柄（不拥有，[close] 不关）。
  static SrsCore fromAddress(
    int address, {
    String? libraryPath,
    SrsOpenMode mode = SrsOpenMode.primary,
  }) => SrsCore._(
    SrsCoreBindings.load(libraryPath: libraryPath),
    ffi.Pointer<ffi.Void>.fromAddress(address),
    owned: false,
    mode: mode,
  );

  /// 句柄值（跨 isolate 传递用）：原生句柄表里的编号而不是指针，拥有者关库后经它的调用一律报
  /// 「已关闭」（[SrsCoreException]），不会碰到已释放的内存。
  int get address => _handle.address;

  /// 加载的原生库路径（跨 isolate 传递用）。
  String? get libraryPath => _b.libraryPath;

  bool get isClosed => _handle == ffi.nullptr;

  Future<void>? _closing;

  /// 关库（幂等；借来的句柄 [owned] 为假，只丢掉自己这份、不关库）。
  ///
  /// 同步部分摘句柄并取消在途命令（`ffsrs_store_close_begin`，不等任何东西）：返回时这个包装与经句柄号的任何调用
  /// （别的 isolate、已经排着队的 worker 命令）都报「已关闭」；已经在途的命令（可能是开库时几十秒的整层重建）在
  /// Rust 的下一个批次边界 / 语句进度回调里退出、写事务整笔回滚、同样报「已关闭」（native/fushi_fsrs
  /// `store/gen4/cancel.rs`，拍板台 review-merge-1124-leftovers 第 5 条）。等它们退出、关连接的那一步
  /// （`ffsrs_store_close`）仍在后台 isolate 里做：Android / iOS 上 UI isolate 就是平台主线程（反馈 3he3GEoqcU）。
  /// Future 完成时连接已关、库文件可以换 / 删（覆盖恢复）。
  Future<void> close() {
    final Future<void>? closing = _closing;
    if (closing != null) return closing;
    if (isClosed) return Future<void>.value();
    final ffi.Pointer<ffi.Void> handle = _handle;
    _handle = ffi.nullptr;
    if (!owned) return _closing = Future<void>.value();
    _b.closeBegin(handle);
    return _closing = _finishCloseInBackground(handle.address, _b.libraryPath);
  }

  /// [close] 的后台一半（静态：闭包只带句柄号与库路径，不捕获 [SrsCoreBindings]）。
  static Future<void> _finishCloseInBackground(
    int address,
    String? libraryPath,
  ) => Isolate.run(
    () => _finishClose(address, libraryPath),
    debugName: 'srs-store-close',
  );

  static void _finishClose(int address, String? libraryPath) =>
      SrsCoreBindings.load(
        libraryPath: libraryPath,
      ).close(ffi.Pointer<ffi.Void>.fromAddress(address));

  ffi.Pointer<ffi.Void> get _h {
    if (isClosed) throw StateError('srs store is closed');
    return _handle;
  }

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
  /// 每一次读都是内核读命令（`read` / `read_lib`，native/fushi_fsrs/src/store/reads.rs）。
  /// 只有带 cargo feature `raw_sql` 的库里有：发布构建里能写库的这段原生代码不在，调用抛 [SrsCoreException]
  /// （消息 [kSrsRawSqlAbsent]），所以生产代码里的调用在测试里是绿的、到发布包里才失败。
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

  /// [mode]：4 / 5 = 测试专用的原始通道（写连接；5 返回结果行）（ffi.rs `ffsrs_store_exec`；别的取值内核不认——
  /// srs.db 的读只有内核读命令 `read` / `read_lib`，写只有内核命令）。
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

  /// [profile] 此刻的刷新键：牌组树 / 修改记录 / 角标 / 统计 / RWKV 分数表这些缓存「还能不能用」的判据。各键是
  /// 不透明串，只比相等：相等 = 这期间没有变化。
  ///
  /// 内核命令 `refresh_keys`（native/fushi_fsrs/src/store/gen4/refresh.rs）一次取回五个键：主进程（Primary）里是内核
  /// 按 profile、按类别持有的进程内计数，写命令提交之后由内核推进——只读内存，不读库、不排写锁，在调用方 isolate 上
  /// 同步调。各键随什么变、特意不随什么变见 [SrsRefreshKeys]（作答只动 `stats` / `landed`）。辅助进程（Secondary）
  /// 看不见主进程的计数，五个键同值（本机状态行的纪元 + 修订号 + 缓存层代号，一个读快照），随主进程的任何写入变。
  /// Dart 不存计数的镜像。
  ///
  /// 库已关闭（本对象已关，或 [fromAddress] 包的句柄的拥有者已关库）→ null。
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
    return srsRefreshKeysOf(k);
  }

  /// 卡片历史的当前状态，Rust 直接从写连接读日志（含事务里未提交的行）。[lineages] 每项是一份
  /// 历史的血统（自己 + 全部前身的卡 ID）。返回 `srsDecodeHistoryStates` 的布局。
  ///
  /// [profile]：读哪个 profile 的集合（页里的 `[-1, profile]` 行，native/fushi_fsrs/src/store/gen4/dispatch.rs
  /// `direct_col`）。store 的调用方一律给；不给时内核按卡认集合（只剩给裸库测试用的兜底）。
  Uint8List historyStates(List<List<String>> lineages, {String? profile}) =>
      using((Arena arena) {
        final Uint8List page = _lineagePage(lineages, profile);
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
  /// prevDueDay|null, maturityDelta。[profile] 同 [historyStates]。
  Uint8List statProjection(List<List<String>> groups, {String? profile}) =>
      using((Arena arena) {
        final Uint8List page = _lineagePage(groups, profile);
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
  /// 1 fsrs7 / 2 rwkv。[profile] 同 [historyStates]。
  Uint8List optimizerItems(
    List<List<String>> lineages,
    List<int> cardIds, {
    required int algorithm,
    required int utcOffsetMin,
    required int rolloverHour,
    String? profile,
  }) => _command(_b.optimizerItems, _lineagePage(lineages, profile), <int>[
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
    String? profile,
  }) => _command(_b.calibrationItems, _lineagePage(lineages, profile), <int>[
    lineages.length,
    algorithm,
    utcOffsetMin,
    rolloverHour,
    ...cardIds,
  ]);

  /// RWKV 逐卡的保留评分行与摘要（[ids] 每卡 4 个：卡 / 笔记 / 牌组 / 预设）。[profile] 同 [historyStates]。
  Uint8List rwkvCards(
    List<List<String>> lineages,
    List<int> ids, {
    required int utcOffsetMin,
    required int rolloverHour,
    String? profile,
  }) => _command(_b.rwkvRows, _lineagePage(lineages, profile), <int>[
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

  /// 查询道（内核读命令 `read` / `read_lib`）的并发上限：内核只读连接池的连接数上限，按本机核数算
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
    throw SrsCoreException.of(rc, message);
  }
}

/// 已关闭的句柄上调用时内核报的错误文本（native/fushi_fsrs/src/store/mod.rs `CLOSED`）。
const String kSrsCoreClosed = 'srs store is closed';

/// `refresh_keys` 回包 → [SrsRefreshKeys]（五个键都必须在、都是串；缺了是内核与 Dart 对不上，报错）。
SrsRefreshKeys srsRefreshKeysOf(Map<String, Object?> reply) {
  String key(String k) => switch (reply[k]) {
    final String v => v,
    _ => throw StateError(
      'srs: `refresh_keys` reply lacks `$k` (the native core and Dart do not '
      'match): $reply',
    ),
  };
  return (
    content: key('content'),
    structure: key('structure'),
    rwkv: key('rwkv'),
    stats: key('stats'),
    landed: key('landed'),
  );
}

/// [SrsCore.refreshKeys] 的结果（键的含义见 native/fushi_fsrs/src/store/gen4/refresh.rs 文件头的表，口径同协议 3 的
/// `store/refresh.rs`；新代没有收段会话的延后，等同步命令接线时补）：
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
