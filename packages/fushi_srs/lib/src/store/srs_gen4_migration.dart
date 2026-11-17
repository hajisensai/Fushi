/// 协议 3 → 新代（gen4）的迁移命令（native/fushi_fsrs/src/store/gen4/kernel.rs `global`：`gen4_migrate_status` /
/// `gen4_migrate_profiles` / `gen4_migrate_run` / `gen4_migrate_cancel`，经 `ffsrs_call`，不要库句柄）。
///
/// 迁移是无损的：协议 3 的 `srs.db` 提交后原位封存（不删），新代库 `srs4.db` 在临时名上建好、对拍通过才改名到位
/// （提交点）。旧库没做完的协议 3 收尾（前提补完，G7-2b）在旧库的副本上做：提交点之前任何一步失败或取消，旧库逐字节
/// 是迁移前的样子（写它的那个版本照样能打开），目录回到迁移前的样子。
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

  /// 前提补完（G7-2b）：旧库里协议 3 自己还没做完的收尾（从没同步过的旧行、去重、收段收尾、schema 升级）先用冻结的
  /// 协议 3 代码在旧库的副本上做完（旧库本身不写）。
  prepare('prepare'),
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

  /// 没开始：换代锁在别人手里 / 旧库正被写 / 本进程里同一目录已经在跑 / 旧库没满足迁移前提
  /// （[SrsGen4MigrationOutcome.blockedReason]）。
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

/// [SrsGen4MigrationVerdict.blocked] 的原因分类，按内核给的机器可读 `code`（migrate.rs `BlockCode::wire`）分，不比
/// 原因原文。旧库里协议 3 没做完的收尾现在由迁移自己补完（G7-2b），剩下的分类决定页面怎么说、给不给「重新升级」。
enum SrsGen4BlockedReason {
  /// 换代锁在别的进程手里，或本进程里同一目录已经在跑（`migrating`）：等一会再来。
  migrating,

  /// 协议 3 的旧库正被别的连接写（`busy`）：等一会再来。
  busy,

  /// 旧库是更新的版本写的（`schemaNewer`）：这一版读不了，要装新版本；重试不会变。
  newerBuild,

  /// 旧库文件坏了 / 不是复习库（`corrupt` / `notProtocol3`）：重试不会变，原样保留、带日志联系支持。
  damaged,

  /// 其余（`missingCacheConfig` / `precondition` / 目录状态对不上 / 不认识的 code）：原因原文给用户看，可以重新升级
  /// （前提补完每次都会重做一遍能补的部分）。
  precondition;

  /// 内核 `code` → 分类。
  static SrsGen4BlockedReason of(String? code) => switch (code) {
    'migrating' => migrating,
    'busy' => busy,
    'schemaNewer' => newerBuild,
    'corrupt' || 'notProtocol3' => damaged,
    _ => precondition,
  };

  /// 内核会给的全部 `code`（Dart 测试读 migrate.rs 核对两边一致）。
  static const List<String> kernelCodes = <String>[
    'migrating',
    'busy',
    'missingCacheConfig',
    'schemaNewer',
    'notProtocol3',
    'corrupt',
    'noLibrary',
    'sealedWithoutNew',
    'legacyBesideNew',
    'precondition',
  ];

  /// 再点一次可能就过了：等一会再来的两类，以及前提补完会再做一遍的 [precondition]。其余两类重试不会变。
  /// （旧的 `mergeHalfDone` 已不再拦：并入做到一半的库照常迁移，标记带进新代库由 `profile_merge_commit` 收尾，G9-5。）
  bool get retryable => switch (this) {
    migrating || busy || precondition => true,
    newerBuild || damaged => false,
  };
}

/// `gen4_migrate_run` 的结果（migrate.rs `Outcome::json`）。
final class SrsGen4MigrationOutcome {
  const SrsGen4MigrationOutcome({
    required this.verdict,
    this.code,
    this.reason,
    this.reportPath,
    this.report,
    this.neededBytes,
    this.freeBytes,
  });

  final SrsGen4MigrationVerdict verdict;

  /// [SrsGen4MigrationVerdict.blocked] 的机器可读原因（migrate.rs `BlockCode::wire`）。
  final String? code;

  /// [SrsGen4MigrationVerdict.blocked] 的原因（内核原文，给人看）。
  final String? reason;

  /// [SrsGen4MigrationVerdict.aborted] 时诊断报告的文件路径（只含 ID 与计数）。
  final String? reportPath;

  /// 报告本体（提交 / 放弃时有）。
  final Object? report;

  final int? neededBytes;
  final int? freeBytes;

  /// [SrsGen4MigrationVerdict.blocked] 时的原因分类；其余结论 = null。
  SrsGen4BlockedReason? get blockedReason =>
      verdict == SrsGen4MigrationVerdict.blocked
      ? SrsGen4BlockedReason.of(code)
      : null;

  static SrsGen4MigrationOutcome fromJson(Map<String, Object?> j) {
    final SrsGen4MigrationVerdict? v = SrsGen4MigrationVerdict.tryParse(
      j['verdict'],
    );
    if (v == null) {
      throw SrsCoreException(-1, 'gen4_migrate_run: unknown verdict $j');
    }
    return SrsGen4MigrationOutcome(
      verdict: v,
      code: j['code'] as String?,
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
  /// 目录的代际状态与本进程里正在跑的进度（只读，快：只看文件与锁、读旧库的一行 schema，可在 UI isolate 上轮询）。
  static SrsGen4MigrationStatus status(String dir, {String? libraryPath}) {
    final Object? r = SrsCoreBindings.load(
      libraryPath: libraryPath,
    ).callGlobal(<String, Object?>{'op': 'gen4_migrate_status', 'dir': dir});
    return SrsGen4MigrationStatus.fromJson((r! as Map).cast<String, Object?>());
  }

  /// 旧库里全部有数据的 profile uid（内核 `legacy::all_profiles`，含主库 profile 表里没有的孤儿 uid）：[run] 的
  /// `caches` 要每个都有。要读旧库的几张大表（每张按 profile 跳着取），在后台 isolate 里调。没有旧库 / 读不了 =
  /// [SrsCoreException]。
  static Future<List<String>> legacyProfiles(
    String dir, {
    String? libraryPath,
  }) async {
    final String? lib = SrsCoreBindings.load(
      libraryPath: libraryPath,
    ).libraryPath;
    final Map<String, Object?> request = <String, Object?>{
      'op': 'gen4_migrate_profiles',
      'dir': dir,
    };
    final Object? r = await Isolate.run(
      () =>
          (SrsCoreBindings.load(libraryPath: lib).callGlobal(request)!
              as Map)['profiles'],
      debugName: 'srs-gen4-profiles',
    );
    return <String>[for (final Object? u in (r as List?) ?? const []) '$u'];
  }

  /// 跑一次迁移（阻塞几十秒到几分钟，放后台 isolate）。[caches]：每个 profile uid → 它的缓存配置（只有 Dart 知道
  /// 的内置笔记类型默认值与默认牌组；[legacyProfiles] 里每个都要有，缺了迁移拦下、`code` 为 `missingCacheConfig`）。
  /// [runId] 让早于开跑到达的 [cancel] 不丢。进度用 [status] 轮询。
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

/// 迁移命令的执行端：app 的迁移控制器（`fushi/lib/src/srs/srs_gen4_migration_controller.dart`）与服务端的无头状态机
/// （`packages/fushi_server/lib/src/server_srs.dart`）共用这一份接口，测试换成假的。
abstract interface class SrsGen4MigrationBackend {
  SrsGen4MigrationStatus status(String dir);

  /// 旧库里全部有数据的 profile（[SrsGen4Migration.legacyProfiles]，后台 isolate）。
  Future<List<String>> legacyProfiles(String dir);

  Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    required String runId,
  });

  bool cancel(String dir, {String? runId});
}

/// 真实的执行端：原生库的全局命令（[SrsGen4Migration]；`run` / `legacyProfiles` 在后台 isolate）。
final class SrsNativeGen4MigrationBackend implements SrsGen4MigrationBackend {
  const SrsNativeGen4MigrationBackend();

  @override
  SrsGen4MigrationStatus status(String dir) => SrsGen4Migration.status(dir);

  @override
  Future<List<String>> legacyProfiles(String dir) =>
      SrsGen4Migration.legacyProfiles(dir);

  @override
  Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    required String runId,
  }) => SrsGen4Migration.run(dir, caches: caches, nowMs: nowMs, runId: runId);

  @override
  bool cancel(String dir, {String? runId}) =>
      SrsGen4Migration.cancel(dir, runId: runId);
}
