// 服务端复习库换代（协议 3 `srs.db` → 新代 `srs4.db`，G10-3）的无头状态机：启动按 `gen4_migrate_status` 判定、
// 要迁移就后台迁移；迁移中复习请求回类型化的「升级中」；失败类状态管理员可见、不自动重跑；叫停 / 停服。
//
// 迁移执行端换成假的（[_FakeMigration]）：结论、进度与时序由测试控制。提交之后的开库走真 SrsStorage（空目录建新代库）。
// 真协议 3 库的端到端迁移见 server_srs_migration_e2e_test.dart。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart' show CtlFailure;
import 'package:fushi_engine/srs/srs_ctl_routes.dart' show SrsCtlHost;
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_remote_store_routes.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_server/src/admin/admin_srs_ctl.dart';
import 'package:fushi_server/src/config/server_srs_config.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'support/fake_rwkv.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';
const String kZh = '01928c3e-0000-7000-8000-00000000b0b0';
const String kOrphan = '01928c3e-0000-7000-8000-00000000cafe';

/// 假的迁移执行端：[state] 是状态命令报的代际状态，每次 [run] 挂一个等测试给结论的 Completer。[cancel] 与内核一样：
/// 在跑的那次以 cancelled 收场；还没开始的（按 runId 先登记）一开始就收场。
final class _FakeMigration implements ServerSrsMigrationBackend {
  SrsGenState state = SrsGenState.needsMigration;
  SrsGen4MigrationProgress? running;
  List<String> legacy = <String>[kJa, kOrphan];
  final List<Completer<SrsGen4MigrationOutcome>> runs =
      <Completer<SrsGen4MigrationOutcome>>[];
  final List<Map<String, Map<String, Object?>>> caches =
      <Map<String, Map<String, Object?>>>[];
  final List<String?> cancels = <String?>[];

  @override
  SrsGen4MigrationStatus status(String dir) =>
      SrsGen4MigrationStatus(state: state, running: running);

  @override
  Future<List<String>> legacyProfiles(String dir) async => legacy;

  @override
  Future<SrsGen4MigrationOutcome> run(
    String dir, {
    required Map<String, Map<String, Object?>> caches,
    required int nowMs,
    required String runId,
  }) {
    this.caches.add(caches);
    final Completer<SrsGen4MigrationOutcome> c =
        Completer<SrsGen4MigrationOutcome>();
    runs.add(c);
    if (_cancelArmed) {
      _cancelArmed = false;
      c.complete(_cancelled);
    }
    return c.future;
  }

  bool _cancelArmed = false;

  static const SrsGen4MigrationOutcome _cancelled = SrsGen4MigrationOutcome(
    verdict: SrsGen4MigrationVerdict.cancelled,
  );

  @override
  bool cancel(String dir, {String? runId}) {
    cancels.add(runId);
    if (runs.isNotEmpty && !runs.last.isCompleted) {
      running = null;
      runs.last.complete(_cancelled);
    } else {
      _cancelArmed = true;
    }
    return true;
  }

  /// 给最近一次 [run] 结论；[after] 是结论之后状态命令报的状态。
  void finish(SrsGen4MigrationOutcome o, {required SrsGenState after}) {
    state = after;
    running = null;
    runs.last.complete(o);
  }
}

void main() {
  late Directory tmp;
  late Directory support;
  late _FakeMigration fake;
  late ServerSrsConfig config;
  late ServerSrs srs;

  ServerSrs make() => ServerSrs(
    rwkvHttpClient: noNetworkHttpClient,
    support: support,
    syncData: Directory(p.join(tmp.path, 'interconnect'))..createSync(),
    deviceId: 'server-device',
    hostId: 'server-srs-migration-test',
    config: () => config,
    engine: () => null,
    migration: fake,
    migrationPollInterval: const Duration(milliseconds: 5),
    // 不等重试间隔：「不自动重跑」靠的是结论本身，不是间隔。
    migrationRetryDelay: Duration.zero,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_srs_mig_');
    support = Directory(p.join(tmp.path, 'support'))..createSync();
    fake = _FakeMigration();
    config = const ServerSrsConfig(profiles: <String>[kJa, kZh]);
    srs = make();
  });

  tearDown(() async {
    for (final Completer<SrsGen4MigrationOutcome> c in fake.runs) {
      if (!c.isCompleted) {
        c.complete(
          const SrsGen4MigrationOutcome(
            verdict: SrsGen4MigrationVerdict.cancelled,
          ),
        );
      }
    }
    await srs.stop();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  /// 等迁移跑完、跑完后的重新套用配置也做完。
  Future<void> settle() async {
    for (int i = 0; i < 400 && srs.migrationRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(srs.migrationRunning, isFalse);
    await srs.applyConfig();
  }

  Future<void> until(bool Function() ok, String what) async {
    for (int i = 0; i < 400 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ok(), isTrue, reason: what);
  }

  /// 等第 [n] 次迁移真的调到执行端（开始之后要先在后台 isolate 列旧库 profile、读同步目录）。
  Future<void> runs(int n) =>
      until(() => fake.runs.length == n, '$n migration run(s) started');

  Future<(int, String?)> remoteHello([String? profile]) async {
    final shelf.Response r = await handleSrsRemoteStoreRequest(
      srs.remoteStore!,
      shelf.Request(
        'POST',
        Uri.parse('http://host/api/srs/remote/call'),
        body: jsonEncode(<String, Object?>{'op': 'hello', 'profile': ?profile}),
      ),
      'POST',
      '/api/srs/remote/call',
    );
    final Object? body = jsonDecode(await r.readAsString());
    return (r.statusCode, body is Map ? body['error'] as String? : null);
  }

  Future<CtlFailure> ctlRefusal(String? profile) async {
    final SrsCtlHost host = serverSrsCtlHost(() => srs);
    try {
      await host.open(profile);
    } on CtlFailure catch (f) {
      return f;
    }
    fail('open($profile) should be refused');
  }

  test('协议 3 库：启动即后台迁移；迁移中各入口回「升级中」；提交后开库', () async {
    await srs.start();
    expect(srs.migrationRunning, isTrue, reason: '启动不等迁移跑完');
    expect(srs.generation.state, ServerSrsGenState.migrating);
    await runs(1);
    // 缓存配置：旧库列出的（含孤儿 uid）∪ 配置里提供的。
    expect(fake.caches.single.keys.toSet(), <String>{kJa, kZh, kOrphan});

    for (final String uid in <String>[kJa, kZh]) {
      expect(srs.profile(uid)!.state, ServerSrsProfileState.upgrading);
      expect(srs.storeFor(uid), isNull);
    }
    // 远程复习：不是 404「没开复习」，是类型化的 503 migrating（默认与点名都一样）。
    expect(srs.remoteStore, isNotNull);
    expect(await remoteHello(), (503, SrsRemoteStoreError.migrating));
    expect(await remoteHello(kJa), (503, SrsRemoteStoreError.migrating));
    // 不在提供之列的 uid 仍是「profile 变了」。
    expect(await remoteHello(kOrphan), (
      409,
      SrsRemoteStoreError.profileChanged,
    ));
    // admin ctl 的复习内容端点：503 srs_upgrading，不是 409 / 500。
    for (final String? uid in <String?>[kJa, null]) {
      final CtlFailure f = await ctlRefusal(uid);
      expect((f.status, f.code), (503, 'srs_upgrading'), reason: '$uid');
    }
    expect(srs.upgradeRefusal, ServerSrsUpgradeRefusal.upgrading);

    // 进度进状态（admin / ctl 看得到）。
    fake.running = (step: SrsGen4MigrationStep.parity, done: 1, total: 2);
    await until(
      () => srs.generation.step == SrsGen4MigrationStep.parity,
      'progress polled',
    );
    final Map<String, Object?> gen = (srs.status()['generation']! as Map)
        .cast<String, Object?>();
    expect(gen['state'], 'migrating');
    expect(gen['step'], 'parity');
    expect(gen['done'], 1);
    expect(gen['total'], 2);
    expect(gen['cancellable'], isTrue);

    // 迁移中重新套用配置（兜底定时器 / WebUI 保存）不另起一次。
    await srs.applyConfig();
    expect(fake.runs, hasLength(1));

    fake.finish(
      const SrsGen4MigrationOutcome(verdict: SrsGen4MigrationVerdict.committed),
      after: SrsGenState.ready,
    );
    await settle();
    expect(srs.generation.state, ServerSrsGenState.ready);
    expect(srs.generation.verdict, 'committed');
    expect(srs.upgradeRefusal, isNull);
    expect(File(SrsStorage.gen4PathIn(support.path)).existsSync(), isTrue);
    for (final String uid in <String>[kJa, kZh]) {
      expect(
        srs.profile(uid)!.state,
        isNot(
          anyOf(
            ServerSrsProfileState.upgrading,
            ServerSrsProfileState.upgradeBlocked,
          ),
        ),
        reason: uid,
      );
    }
    expect(fake.runs, hasLength(1));
  });

  test('被拦下（mergeHalfDone）：管理员看得到 code 与处置，不自动重跑；手动开始再跑；对拍不过记报告', () async {
    await srs.start();
    await runs(1);
    fake.finish(
      const SrsGen4MigrationOutcome(
        verdict: SrsGen4MigrationVerdict.blocked,
        code: 'mergeHalfDone',
        reason: 'profile merge half done',
      ),
      after: SrsGenState.needsMigration,
    );
    await settle();
    expect(srs.generation.state, ServerSrsGenState.blocked);
    expect(srs.generation.code, 'mergeHalfDone');
    expect(srs.generation.autoRetry, isFalse);
    expect(srs.generation.advice, contains('merge'));
    expect(srs.profile(kJa)!.state, ServerSrsProfileState.upgradeBlocked);
    expect(srs.profile(kJa)!.lastError, srs.generation.advice);
    expect(srs.upgradeRefusal, ServerSrsUpgradeRefusal.blocked);
    expect(await remoteHello(), (503, SrsRemoteStoreError.migrationFailed));
    final CtlFailure f = await ctlRefusal(kJa);
    expect((f.status, f.code), (503, 'srs_upgrade_blocked'));

    // 兜底定时器 / 改配置：不重跑。
    await srs.applyConfig();
    await srs.applyConfig();
    expect(fake.runs, hasLength(1));
    expect(srs.migrationRunning, isFalse);

    // 管理员处理后手动开始。
    expect(await srs.startMigration(), isNull);
    expect(srs.migrationRunning, isTrue);
    await runs(2);
    expect(await srs.startMigration(), 'srs_migration_running');
    expect(srs.profile(kJa)!.state, ServerSrsProfileState.upgrading);

    fake.finish(
      const SrsGen4MigrationOutcome(
        verdict: SrsGen4MigrationVerdict.aborted,
        reportPath: '/data/srs.db-gen4-report.json',
      ),
      after: SrsGenState.migrationFailed,
    );
    await settle();
    expect(srs.generation.state, ServerSrsGenState.migrationFailed);
    expect(srs.generation.reportPath, '/data/srs.db-gen4-report.json');
    expect(srs.generation.advice, contains('/data/srs.db-gen4-report.json'));
    expect(srs.profile(kJa)!.state, ServerSrsProfileState.upgradeBlocked);
    await srs.applyConfig();
    expect(fake.runs, hasLength(2), reason: '对拍不过不自动重跑');
    expect(
      srs.generation.reportPath,
      '/data/srs.db-gen4-report.json',
      reason: '状态命令报的 migrationFailed 不盖掉本进程的报告路径',
    );
  });

  test('启动时目录已是失败类状态：管理员可见、不迁移、不删文件', () async {
    final File legacy = File(SrsStorage.legacyPathIn(support.path))
      ..writeAsStringSync('stand-in for a protocol 3 library');
    for (final (SrsGenState state, ServerSrsGenState want)
        in <(SrsGenState, ServerSrsGenState)>[
          (SrsGenState.migrationFailed, ServerSrsGenState.migrationFailed),
          (SrsGenState.sealedOldOnly, ServerSrsGenState.sealedOldOnly),
          (
            SrsGenState.migratingElsewhere,
            ServerSrsGenState.migratingElsewhere,
          ),
        ]) {
      await srs.stop();
      fake = _FakeMigration()..state = state;
      srs = make();
      await srs.start();
      expect(srs.generation.state, want, reason: '$state');
      expect(fake.runs, isEmpty, reason: '$state');
      expect(srs.storeFor(kJa), isNull);
      expect(legacy.readAsStringSync(), 'stand-in for a protocol 3 library');
      final ServerSrsProfileState profileState =
          state == SrsGenState.migratingElsewhere
          ? ServerSrsProfileState.upgrading
          : ServerSrsProfileState.upgradeBlocked;
      expect(srs.profile(kJa)!.state, profileState, reason: '$state');
      expect((srs.status()['generation']! as Map)['advice'], isA<String>());
    }
    // 别的进程迁完了：兜底的下一轮自动接着迁（迁移本身可重入）。
    fake.state = SrsGenState.needsMigration;
    await srs.applyConfig();
    await runs(1);
    expect(srs.generation.state, ServerSrsGenState.migrating);
  });

  test('各结论映射成管理员可见的状态；只有「等一会再来」的旁路重试', () async {
    final List<(SrsGen4MigrationOutcome, ServerSrsGenState, bool)> cases =
        <(SrsGen4MigrationOutcome, ServerSrsGenState, bool)>[
          (
            const SrsGen4MigrationOutcome(
              verdict: SrsGen4MigrationVerdict.blocked,
              code: 'legacyBesideNew',
            ),
            ServerSrsGenState.legacyBesideNew,
            false,
          ),
          (
            const SrsGen4MigrationOutcome(
              verdict: SrsGen4MigrationVerdict.blocked,
              code: 'sealedWithoutNew',
            ),
            ServerSrsGenState.sealedOldOnly,
            false,
          ),
          (
            const SrsGen4MigrationOutcome(
              verdict: SrsGen4MigrationVerdict.noSpace,
              neededBytes: 100,
              freeBytes: 10,
            ),
            ServerSrsGenState.noSpace,
            false,
          ),
          (
            const SrsGen4MigrationOutcome(
              verdict: SrsGen4MigrationVerdict.blocked,
              code: 'busy',
            ),
            ServerSrsGenState.blocked,
            true,
          ),
        ];
    for (final (SrsGen4MigrationOutcome o, ServerSrsGenState want, bool retry)
        in cases) {
      await srs.stop();
      fake = _FakeMigration();
      srs = make();
      await srs.start();
      await runs(1);
      fake.finish(o, after: SrsGenState.needsMigration);
      final ServerSrsGeneration seen = ServerSrsGeneration(
        state: want,
        code: o.code,
      );
      expect(seen.autoRetry, retry, reason: o.code ?? o.verdict.wire);
      expect(
        seen.refusal,
        retry
            ? ServerSrsUpgradeRefusal.upgrading
            : ServerSrsUpgradeRefusal.blocked,
      );
      if (retry) {
        // 旧库正被写：过了重试间隔（本测试为 0）的下一次判定自动再试，期间请求仍是「升级中」。
        await runs(2);
        expect(srs.generation.state, ServerSrsGenState.migrating);
        expect(srs.generation.verdict, o.verdict.wire);
        expect(srs.upgradeRefusal, ServerSrsUpgradeRefusal.upgrading);
        continue;
      }
      await settle();
      expect(srs.generation.state, want, reason: o.code ?? o.verdict.wire);
      expect(srs.generation.autoRetry, isFalse, reason: o.code);
      expect(srs.upgradeRefusal, ServerSrsUpgradeRefusal.blocked);
      expect(srs.generation.advice, isNotEmpty);
      // 重试间隔为 0 也不重跑：靠的是结论本身。
      await srs.applyConfig();
      expect(fake.runs, hasLength(1), reason: o.code ?? o.verdict.wire);
    }
  });

  test('叫停：提交点之前叫停、结论 cancelled 后不自动重跑；过了提交点拒绝；停服等迁移停下', () async {
    await srs.start();
    fake.running = (step: SrsGen4MigrationStep.commit, done: 0, total: 1);
    await until(
      () => srs.generation.step == SrsGen4MigrationStep.commit,
      'commit polled',
    );
    expect(srs.cancelMigration(), 'srs_migration_past_commit');
    expect(fake.cancels, isEmpty);

    fake.running = (step: SrsGen4MigrationStep.translate, done: 0, total: 1);
    await until(
      () => srs.generation.step == SrsGen4MigrationStep.translate,
      'translate polled',
    );
    await runs(1);
    expect(srs.cancelMigration(), isNull);
    expect(fake.cancels, hasLength(1));
    expect(srs.generation.cancelRequested, isTrue);
    await settle();
    expect(srs.generation.state, ServerSrsGenState.needsMigration);
    expect(srs.generation.verdict, 'cancelled');
    expect(fake.runs, hasLength(1));
    expect(srs.cancelMigration(), 'srs_migration_not_running');

    // 停服：过了提交点的那次不叫停（改名 / 封存不能被打断），等它跑完再关。
    expect(await srs.startMigration(), isNull);
    await runs(2);
    fake.running = (step: SrsGen4MigrationStep.seal, done: 0, total: 1);
    await until(
      () => srs.generation.step == SrsGen4MigrationStep.seal,
      'seal polled',
    );
    bool stopped = false;
    final Future<void> stopping = srs.stop().then((_) => stopped = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(stopped, isFalse, reason: '迁移有结论之前不算停好');
    expect(fake.cancels, hasLength(1), reason: '过了提交点不叫停');
    fake.finish(
      const SrsGen4MigrationOutcome(verdict: SrsGen4MigrationVerdict.committed),
      after: SrsGenState.ready,
    );
    await stopping;
    expect(stopped, isTrue);
    expect(srs.generation.verdict, 'committed');
    expect(await srs.startMigration(), 'srs_stopped');
  });

  test('停服时迁移在提交点之前：叫停、等到结论再关', () async {
    await srs.start();
    await runs(1);
    await srs.stop();
    expect(fake.cancels, hasLength(1));
    expect(srs.migrationRunning, isFalse);
    expect(srs.generation.verdict, 'cancelled');
  });

  test('迁移命令报错：记成 error、可见原因、不自动重跑', () async {
    await srs.start();
    await runs(1);
    fake.runs.last.completeError(const SrsCoreException(-1, 'kernel boom'));
    await settle();
    expect(srs.generation.state, ServerSrsGenState.error);
    expect(srs.generation.reason, contains('kernel boom'));
    await srs.applyConfig();
    expect(fake.runs, hasLength(1));
  });

  test('复习关（没选 profile）：不判定、不迁移', () async {
    config = const ServerSrsConfig();
    await srs.start();
    expect(fake.runs, isEmpty);
    expect(srs.generation.state, ServerSrsGenState.ready);
    expect(srs.remoteStore, isNull);
  });
}
