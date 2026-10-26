import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_settings_task_routes.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi_cli/fushi_cli.dart';

/// 设置类后台任务登记表与 `/api/admin/tasks` 路由：起任务即返回、进度 / 取消 /
/// 提交阶段拒绝取消、等待、取消后保留已完成部分的结果。
void main() {
  late SettingsCliTaskRegistry registry;

  setUp(() => registry = SettingsCliTaskRegistry());

  test('run 同步跑到第一个 await：detail / onCancel 出现在 start 返回的快照里', () async {
    final Completer<void> gate = Completer<void>();
    final SettingsCliTask task = registry.start(
      kind: 'demo',
      run: (SettingsCliTask t) async {
        t
          ..onCancel = () {}
          ..detail['link'] = 'https://example'
          ..report(phase: 'waiting', progress: 0.25);
        await gate.future;
        return <String, Object?>{'ok': true};
      },
    );
    final Map<String, Object?> snapshot = task.toJson();
    expect(snapshot['status'], 'running');
    expect(snapshot['detail'], <String, Object?>{'link': 'https://example'});
    expect(snapshot['progress'], 25.0);
    expect(snapshot['cancellable'], isTrue);
    expect(registry.activeOf('demo'), same(task));
    gate.complete();
    await task.whenDone;
    expect(task.status, SettingsCliTaskStatus.done);
    expect(task.result, <String, Object?>{'ok': true});
    expect(registry.activeOf('demo'), isNull);
  });

  test(
    '取消：调登记的 onCancel，执行体抛 SettingsCliTaskCancelled = cancelled，保留已设的 result',
    () async {
      final Completer<void> stop = Completer<void>();
      final SettingsCliTask task = registry.start(
        kind: 'demo',
        run: (SettingsCliTask t) async {
          t.onCancel = () => stop.complete();
          await stop.future;
          t.result = <String, Object?>{'done': 3};
          throw const SettingsCliTaskCancelled();
        },
      );
      expect(registry.cancel(task), SettingsCliCancelOutcome.requested);
      await task.whenDone;
      expect(task.status, SettingsCliTaskStatus.cancelled);
      expect(task.result, <String, Object?>{'done': 3});
      expect(registry.cancel(task), SettingsCliCancelOutcome.finished);
    },
  );

  test('没登记 onCancel / 进入提交阶段后拒绝取消', () async {
    final Completer<void> gate = Completer<void>();
    final SettingsCliTask plain = registry.start(
      kind: 'a',
      run: (SettingsCliTask t) async {
        await gate.future;
        return null;
      },
    );
    expect(registry.cancel(plain), SettingsCliCancelOutcome.refused);
    final SettingsCliTask committing = registry.start(
      kind: 'b',
      run: (SettingsCliTask t) async {
        t
          ..onCancel = () {}
          ..markCommitting();
        await gate.future;
        return null;
      },
    );
    expect(committing.toJson()['cancellable'], isFalse);
    expect(registry.cancel(committing), SettingsCliCancelOutcome.refused);
    gate.complete();
    await Future.wait(<Future<void>>[plain.whenDone, committing.whenDone]);
  });

  test('isCancellation 认得的异常 = cancelled；其它异常 = failed 并带文案', () async {
    final SettingsCliTask cancelled = registry.start(
      kind: 'a',
      isCancellation: (Object e) => e is TimeoutException,
      run: (SettingsCliTask t) async => throw TimeoutException('x'),
    );
    final SettingsCliTask failed = registry.start(
      kind: 'b',
      describe: (Object e) => '坏了：$e',
      run: (SettingsCliTask t) async => throw StateError('boom'),
    );
    await Future.wait(<Future<void>>[cancelled.whenDone, failed.whenDone]);
    expect(cancelled.status, SettingsCliTaskStatus.cancelled);
    expect(failed.status, SettingsCliTaskStatus.failed);
    expect(failed.error, contains('坏了'));
  });

  group('/api/admin/tasks 路由', () {
    test('get --wait 等到结束；越界 400；未知 id 404', () async {
      final Completer<void> gate = Completer<void>();
      final SettingsCliTask task = registry.start(
        kind: 'update-download',
        run: (SettingsCliTask t) async {
          await gate.future;
          return <String, Object?>{'file': 'x'};
        },
      );
      final Map<String, Object?> running = await getSettingsTask(
        registry,
        task.id,
      );
      expect(running['finished'], isFalse);
      unawaited(Future<void>(gate.complete));
      final Map<String, Object?> done = await getSettingsTask(
        registry,
        task.id,
        waitSeconds: 5,
      );
      expect(done['finished'], isTrue);
      expect(done['status'], 'done');
      expect(done['result'], <String, Object?>{'file': 'x'});
      await expectLater(
        getSettingsTask(registry, task.id, waitSeconds: 601),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
      await expectLater(
        getSettingsTask(registry, 'nope'),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
        ),
      );
    });

    test('ls 的 kind 认前缀族；cancel 不可取消时 409', () async {
      final Completer<void> gate = Completer<void>();
      registry.start(
        kind: 'update-download',
        run: (SettingsCliTask t) async {
          await gate.future;
          return null;
        },
      );
      final SettingsCliTask install = registry.start(
        kind: 'update-install',
        run: (SettingsCliTask t) async {
          t.markCommitting();
          await gate.future;
          return null;
        },
      );
      registry.start(
        kind: 'plex-sign-in',
        run: (SettingsCliTask t) async {
          await gate.future;
          return null;
        },
      );
      final List<Object?> updates =
          listSettingsTasks(registry, 'update')['tasks']! as List<Object?>;
      expect(updates, hasLength(2));
      expect(
        () => cancelSettingsTask(registry, install.id),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 409),
        ),
      );
      gate.complete();
    });

    test('路由表三条都在', () {
      final List<String> patterns = <String>[
        for (final CtlRoute r in buildSettingsTaskCtlRoutes(registry: registry))
          '${r.method} ${r.pattern}',
      ];
      expect(patterns, <String>[
        'GET /api/admin/tasks',
        'GET /api/admin/tasks/:id',
        'POST /api/admin/tasks/:id/cancel',
      ]);
    });
  });
}
