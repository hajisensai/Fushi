// Contract of how a dist_test run ends early (tool/test_flow/dist_stop.dart):
// the workers' remote runs are killed and their checkouts released before
// the process exits, and a loop that checks in afterwards starts nothing.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_plan.dart';
import '../../tool/test_flow/dist_snapshot.dart';
import '../../tool/test_flow/dist_stop.dart';
import '../../tool/test_flow/dist_workers.dart';

class _Exited implements Exception {
  _Exited(this.code);
  final int code;
}

Never _throwExit(int code) => throw _Exited(code);

/// Records what a stop asks of it.
class _FakeWorker extends DistWorker {
  _FakeWorker(String name, this.calls)
    : super(
        DistWorkerConfig(
          name: name,
          kind: DistWorkerKind.sshTrusted,
          platform: DistPlatform.macos,
          host: 'u@$name',
        ),
      );

  final List<String> calls;

  @override
  Future<void> abandon() async => calls.add('abandon $name');

  @override
  Future<void> cancel() async => calls.add('cancel $name');

  @override
  Future<void> finish(String runId) async => calls.add('finish $name $runId');

  @override
  Future<void> prepare(DistSnapshot snapshot, String runId, IOSink log) =>
      throw UnimplementedError();

  @override
  Future<DistBatchRun> run(
    DistBatch batch, {
    required String package,
    required List<String> flutterArgs,
    required IOSink stderrLog,
    required Duration timeout,
    int? concurrencyCap,
  }) => throw UnimplementedError();

  @override
  Future<DistBatchRun> analyze(
    List<String> paths, {
    required List<String> options,
    required IOSink stderrLog,
    required Duration timeout,
  }) => throw UnimplementedError();

  @override
  Future<DistBatchRun> build(
    DistBuild build, {
    required IOSink stderrLog,
    required Duration timeout,
  }) => throw UnimplementedError();

  @override
  Future<String?> jobBlocker(DistJob job) async => null;

  @override
  Future<String> status() async => 'fake';
}

void main() {
  test('a stop kills every remote run, then releases every checkout', () async {
    final List<String> calls = <String>[];
    final DistStopper stopper = DistStopper(exitWith: _throwExit)
      ..register(<DistWorker>[_FakeWorker('a', calls), _FakeWorker('b', calls)])
      ..runId = 'r1';
    await expectLater(
      stopper.stop(130, 'interrupted'),
      throwsA(isA<_Exited>().having((_Exited e) => e.code, 'code', 130)),
    );
    expect(stopper.requested, isTrue);
    // Every prepare abandoned and every remote run killed before any
    // checkout is released (a released checkout may be taken by another run).
    expect(calls, <String>[
      'abandon a',
      'abandon b',
      'cancel a',
      'cancel b',
      'finish a r1',
      'finish b r1',
    ]);
  });

  test('a second stop waits on the first and stops nothing twice', () async {
    final List<String> calls = <String>[];
    final DistStopper stopper = DistStopper(exitWith: _throwExit)
      ..register(<DistWorker>[_FakeWorker('a', calls)])
      ..runId = 'r1';
    bool secondDone = false;
    bool holdDone = false;
    final Future<Never> first = stopper.stop(124, 'deadline');
    unawaited(
      stopper.stop(130, 'interrupted').whenComplete(() => secondDone = true),
    );
    unawaited(stopper.holdIfStopping().whenComplete(() => holdDone = true));
    await expectLater(
      first,
      throwsA(isA<_Exited>().having((_Exited e) => e.code, 'code', 124)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(secondDone, isFalse);
    expect(holdDone, isFalse, reason: 'nothing new may start');
    expect(calls, <String>['abandon a', 'cancel a', 'finish a r1']);
  });

  test('nothing to release before the run has an id', () async {
    final List<String> calls = <String>[];
    final DistStopper stopper = DistStopper(exitWith: _throwExit)
      ..register(<DistWorker>[_FakeWorker('a', calls)]);
    await expectLater(stopper.stop(130, 'x'), throwsA(isA<_Exited>()));
    expect(calls, <String>['abandon a', 'cancel a']);
  });

  test('the deadline stops the run itself with 124', () async {
    final List<String> calls = <String>[];
    final Completer<int> exited = Completer<int>();
    final DistStopper stopper =
        DistStopper(
            exitWith: (int code) {
              exited.complete(code);
              throw _Exited(code);
            },
          )
          ..register(<DistWorker>[_FakeWorker('a', calls)])
          ..runId = 'r1';
    runZonedGuarded(
      () => stopper.watch(deadline: const Duration(milliseconds: 100)),
      (Object e, StackTrace _) {},
    );
    expect(calls, isEmpty);
    expect(await exited.future, 124);
    expect(calls, <String>['abandon a', 'cancel a', 'finish a r1']);
    await stopper.dispose();
  });

  test('an untouched stopper lets the run end normally', () async {
    final DistStopper stopper = DistStopper(exitWith: _throwExit)
      ..watch(deadline: const Duration(minutes: 5));
    expect(stopper.requested, isFalse);
    await stopper.holdIfStopping();
    await stopper.dispose();
  });
}
