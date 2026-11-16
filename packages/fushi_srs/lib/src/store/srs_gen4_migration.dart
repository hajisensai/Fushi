/// 协议 3 → 新代（gen4）的迁移命令（native/fushi_fsrs/src/store/gen4/kernel.rs `global`：`gen4_migrate_status` /
/// `gen4_migrate_run` / `gen4_migrate_cancel`，经 `ffsrs_call`，不要库句柄）。
///
/// 迁移是无损的：协议 3 的 `srs.db` 提交后原位封存（不删），新代库 `srs4.db` 在临时名上建好、对拍通过才改名到位
/// （提交点）。提交点之前任何一步失败或取消，目录回到迁移前的样子。
///
/// Dart 侧的顺序（交接说明 §8.1）：开库 → [SrsStoreNotMigrated] 且 [SrsGenState.needsMigration] → 关掉所有协议 3
/// 句柄（S1 之后进程里不会再有：`ffsrs_store_open` 已删）→ [SrsGen4Migration.run] → 再开。
/// [SrsGenState.sealedOldOnly] / [SrsGenState.migrationFailed] 给恢复页，不自动重跑。
library;

import 'dart:isolate';

import 'srs_core.dart';

/// 迁移的步骤（migrate.rs `Step` 的线上名），按执行顺序。[commit] 是提交点：在它之前可以取消。
enum SrsGen4MigrationStep {
  space('space'),
  lock('lock'),
  precondition('precondition'),
  translate('translate'),
  salts('salts'),
  rebuild('rebuild'),
  parity('parity'),
  commit('commit'),
  seal('seal');

  const SrsGen4MigrationStep(this.wire);

  final String wire;

  /// 还在提交点之前（[SrsGen4Migration.cancel] 有效）。
  bool get cancellable => index < commit.index;

  static SrsGen4MigrationStep? tryParse(Object? wire) {
    for (final SrsGen4MigrationStep s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }
}

/// 本进程里正在跑的那次迁移的进度（`gen4_migrate_status` 的 `running`）。
typedef SrsGen4MigrationProgress = ({
  SrsGen4MigrationStep step,
  int done,
  int total,
});

/// `gen4_migrate_status` 的结果。
final class SrsGen4MigrationStatus {
  const SrsGen4MigrationStatus({required this.state, this.running});

  final SrsGenState state;

  /// 本进程里这个目录正在跑的迁移；没有 = null（别的进程在迁移看 [state] == [SrsGenState.migratingElsewhere]）。
  final SrsGen4MigrationProgress? running;

  static SrsGen4MigrationStatus fromJson(Map<String, Object?> j) {
    final SrsGenState? state = SrsGenState.tryParse(j['state']);
    if (state == null) {
      throw SrsCoreException(-1, 'gen4_migrate_status: unknown state $j');
    }
    final Object? r = j['running'];
    SrsGen4MigrationProgress? running;
    if (r is Map) {
      final SrsGen4MigrationStep? step = SrsGen4MigrationStep.tryParse(
        r['step'],
      );
      if (step != null) {
        running = (
          step: step,
          done: (r['done'] as num?)?.toInt() ?? 0,
          total: (r['total'] as num?)?.toInt() ?? 0,
        );
      }
    }
    return SrsGen4MigrationStatus(state: state, running: running);
  }
}

/// 迁移的结论（migrate.rs `Outcome::verdict`）。
enum SrsGen4MigrationVerdict {
  /// 提交了：新代库到位、旧库已封存。
  committed('committed'),

  /// 对拍或前提没过，整次放弃（旧库没动），诊断报告写在 [SrsGen4MigrationOutcome.reportPath]。
  aborted('aborted'),

  /// 没开始：换代锁在别人手里 / 旧库正被写 / 本进程里同一目录已经在跑。
  blocked('blocked'),

  /// 没开始：卷上空间不够（[SrsGen4MigrationOutcome.neededBytes] / [SrsGen4MigrationOutcome.freeBytes]）。
  noSpace('noSpace'),

  /// 在提交点之前被取消（旧库没动）。
  cancelled('cancelled');

  const SrsGen4MigrationVerdict(this.wire);

  final String wire;

  static SrsGen4MigrationVerdict? tryParse(Object? wire) {
    for (final SrsGen4MigrationVerdict v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

/// `gen4_migrate_run` 的结果（migrate.rs `Outcome::json`）。
final class SrsGen4MigrationOutcome {
  const SrsGen4MigrationOutcome({
    required this.verdict,
    this.reason,
    this.reportPath,
    this.report,
    this.neededBytes,
    this.freeBytes,
  });

  final SrsGen4MigrationVerdict verdict;

  /// [SrsGen4MigrationVerdict.blocked] 的原因（内核原文）。
  final String? reason;

  /// [SrsGen4MigrationVerdict.aborted] 时诊断报告的文件路径（只含 ID 与计数）。
  final String? reportPath;

  /// 报告本体（提交 / 放弃时有）。
  final Object? report;

  final int? neededBytes;
  final int? freeBytes;

  static SrsGen4MigrationOutcome fromJson(Map<String, Object?> j) {
    final SrsGen4MigrationVerdict? v = SrsGen4MigrationVerdict.tryParse(
      j['verdict'],
    );
    if (v == null) {
      throw SrsCoreException(-1, 'gen4_migrate_run: unknown verdict $j');
    }
    return SrsGen4MigrationOutcome(
      verdict: v,
      reason: j['reason'] as String?,
      reportPath: j['reportPath'] as String?,
      report: j['report'],
      neededBytes: (j['needed'] as num?)?.toInt(),
      freeBytes: (j['free'] as num?)?.toInt(),
    );
  }
}

/// 迁移的三条全局命令。全部按库目录 [dir]（`<数据库目录>`，与 [SrsCore.open] 同一个）。
abstract final class SrsGen4Migration {
  /// 目录的代际状态与本进程里正在跑的进度（只读，快）。
  static SrsGen4MigrationStatus status(String dir, {String? libraryPath}) {
    final Object? r = SrsCoreBindings.load(
      libraryPath: libraryPath,
    ).callGlobal(<String, Object?>{'op': 'gen4_migrate_status', 'dir': dir});
    return SrsGen4MigrationStatus.fromJson((r! as Map).cast<String, Object?>());
  }

  /// 跑一次迁移（阻塞几十秒到几分钟，放后台 isolate）。[caches]：每个 profile uid → 它的缓存配置（只有 Dart 知道
  /// 的内置笔记类型默认值与默认牌组；协议 3 库里每个 profile 都要有，缺了迁移按前提不满足放弃）。[runId] 让早于开跑
  /// 到达的 [cancel] 不丢。进度用 [status] 轮询。
  static Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    String? runId,
    int? batch,
    String? libraryPath,
  }) async {
    final String? lib = SrsCoreBindings.load(
      libraryPath: libraryPath,
    ).libraryPath;
    final Map<String, Object?> request = <String, Object?>{
      'op': 'gen4_migrate_run',
      'dir': dir,
      'caches': caches,
      'now': nowMs,
      'runId': ?runId,
      'batch': ?batch,
    };
    final Map<String, Object?> r = await Isolate.run(
      () => (SrsCoreBindings.load(libraryPath: lib).callGlobal(request)! as Map)
          .cast<String, Object?>(),
      debugName: 'srs-gen4-migrate',
    );
    return SrsGen4MigrationOutcome.fromJson(r);
  }

  /// 叫停正在跑的那次（提交点之前有效）；还没开始的按 [runId] 先登记。返回这一刻是不是真有一次在跑。
  static bool cancel(String dir, {String? runId, String? libraryPath}) {
    final Object? r = SrsCoreBindings.load(libraryPath: libraryPath).callGlobal(
      <String, Object?>{
        'op': 'gen4_migrate_cancel',
        'dir': dir,
        'runId': ?runId,
      },
    );
    return (r! as Map)['cancelled'] == true;
  }
}
