/// 保留副本（迁移后原位封存的协议 3 `srs.db`）的到期状态与立即删除：内核全局命令 `gen4_retained_state` /
/// `gen4_retained_delete`（native/fushi_fsrs/src/store/gen4/retained.rs，D32），经 `ffsrs_call`，不要库句柄。
///
/// 到期规则在内核：新代第一次同步成功之后 14 天；从没同步成功过的，迁移提交之后 30 天。到期的副本在 Primary 下次
/// 打开新代库时自动换成墓碑库。删除不可逆，调用方（app 设置、ctl、服务端 admin）先取得用户确认。
library;

import 'dart:isolate';

import 'srs_core.dart';

/// 目录里 `srs.db` 的样子（内核 `retained::CopyState` 的线上名）。
enum SrsRetainedCopyKind {
  /// 没有这个文件。
  absent('absent'),

  /// 已经删过（原路径上是墓碑库）。
  tombstone('tombstone'),

  /// 封存的保留副本：还在、可以删。
  sealed('sealed'),

  /// 在，但不是 SQLite 文件：保留副本已经坏了，不能再用它退回旧版本（新代库不受影响）。不删，只提示（BUG-5079）。
  unreadable('unreadable'),

  /// 别的（没封存的协议 3 库、读不了的文件……）：不是保留副本，不删。
  other('other');

  const SrsRetainedCopyKind(this.wire);

  final String wire;

  static SrsRetainedCopyKind parse(Object? wire) {
    for (final SrsRetainedCopyKind k in values) {
      if (k.wire == wire) return k;
    }
    throw SrsCoreException(-1, 'gen4_retained_state: unknown copy $wire');
  }
}

/// `gen4_retained_state` 的结果。
final class SrsRetainedCopyState {
  const SrsRetainedCopyState({
    required this.kind,
    this.bytes = 0,
    this.migratedAtMs,
    this.firstSyncAtMs,
    this.dueAtMs,
    this.due = false,
    this.error,
  });

  factory SrsRetainedCopyState.fromJson(Map<String, Object?> j) =>
      SrsRetainedCopyState(
        kind: SrsRetainedCopyKind.parse(j['copy']),
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        migratedAtMs: (j['migratedAtMs'] as num?)?.toInt(),
        firstSyncAtMs: (j['firstSyncAtMs'] as num?)?.toInt(),
        dueAtMs: (j['dueAtMs'] as num?)?.toInt(),
        due: j['due'] == true,
        error: j['error'] as String?,
      );

  final SrsRetainedCopyKind kind;

  /// 保留副本（主文件 + `-wal`）的字节数；不是 [SrsRetainedCopyKind.sealed] 时为 0。
  final int bytes;

  /// 迁移提交的时刻（毫秒）。
  final int? migratedAtMs;

  /// 新代第一次同步成功的时刻（毫秒）；没同步成功过 = null。
  final int? firstSyncAtMs;

  /// 到期时刻（毫秒）；不会自动到期 = null（只能手动删）。
  final int? dueAtMs;

  /// 副本在、已经到期（下次开库自动删）。
  final bool due;

  /// 上一次到期自动删没做成的原因。
  final String? error;

  /// 有一份可以删的保留副本。
  bool get present => kind == SrsRetainedCopyKind.sealed;

  /// 保留副本坏了（[SrsRetainedCopyKind.unreadable]）：要提示用户退回旧版本这条路没了。
  bool get unreadable => kind == SrsRetainedCopyKind.unreadable;
}

/// `gen4_retained_delete` 的结果。
final class SrsRetainedCopyDeletion {
  const SrsRetainedCopyDeletion({
    required this.deleted,
    this.freedBytes = 0,
    this.reason,
  });

  factory SrsRetainedCopyDeletion.fromJson(Map<String, Object?> j) =>
      SrsRetainedCopyDeletion(
        deleted: j['deleted'] == true,
        freedBytes: (j['freedBytes'] as num?)?.toInt() ?? 0,
        reason: j['reason'] as String?,
      );

  final bool deleted;
  final int freedBytes;

  /// 没删时的原因：`absent`（没有保留副本）/ `unreadable`（保留副本坏了，不删）/ `migrating`（换代锁被别人拿着）。
  final String? reason;
}

/// 保留副本命令的执行端：app（设置 / 牌组彻底清除）、ctl 路由与服务端共用，测试换成假的。
abstract interface class SrsRetainedCopyBackend {
  /// 到期状态（只读；内核要打开两个 SQLite 文件，在后台 isolate 跑）。
  Future<SrsRetainedCopyState> state(String dir, {required int nowMs});

  /// 立即删除（核对新代库、换墓碑；在后台 isolate 跑）。核对不过抛 [SrsCoreException]，什么都不动。
  Future<SrsRetainedCopyDeletion> delete(String dir);
}

/// 真实的执行端：原生库的全局命令。
final class SrsNativeRetainedCopyBackend implements SrsRetainedCopyBackend {
  const SrsNativeRetainedCopyBackend({this.libraryPath});

  final String? libraryPath;

  @override
  Future<SrsRetainedCopyState> state(String dir, {required int nowMs}) async =>
      SrsRetainedCopyState.fromJson(
        await _callInBackground(<String, Object?>{
          'op': 'gen4_retained_state',
          'dir': dir,
          'now': nowMs,
        }, 'srs-retained-state'),
      );

  @override
  Future<SrsRetainedCopyDeletion> delete(String dir) async =>
      SrsRetainedCopyDeletion.fromJson(
        await _callInBackground(<String, Object?>{
          'op': 'gen4_retained_delete',
          'dir': dir,
        }, 'srs-retained-delete'),
      );

  /// 在后台 isolate 跑一条全局命令（内核报错 = [SrsCoreException]，原样抛回调用方）。
  Future<Map<String, Object?>> _callInBackground(
    Map<String, Object?> request,
    String debugName,
  ) {
    final String? lib = SrsCoreBindings.load(
      libraryPath: libraryPath,
    ).libraryPath;
    return Isolate.run(
      () => (SrsCoreBindings.load(libraryPath: lib).callGlobal(request)! as Map)
          .cast<String, Object?>(),
      debugName: debugName,
    );
  }
}
