import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart';
import 'package:fushi/src/platform/app_exit_coordinator.dart';

class _RecordingSink implements ExitMarkerSink {
  final List<String> events = <String>[];

  @override
  void exitRequested(String reason) => events.add('requested:$reason');

  @override
  void exitStage(String stage) => events.add('stage:$stage');

  @override
  void cleanExit(String terminatedBy) => events.add('clean:$terminatedBy');
}

/// 退出协调器：有意退出的第一步同步落盘意图，终止只经唯一出口（先 clean 再 exit），
/// 看门狗时长由步骤预算推出（反馈 GrZ_kLCjue 等「关窗被误报闪退」）。
void main() {
  late _RecordingSink sink;
  late List<int> exits;
  late AppExitCoordinator coordinator;

  setUp(() {
    sink = _RecordingSink();
    exits = <int>[];
    coordinator = AppExitCoordinator(marker: sink, exitProcess: exits.add);
  });

  test('begin 同步写意图（调用返回前已落盘），只认第一次', () {
    expect(coordinator.begin('windowClose'), isTrue);
    expect(sink.events, <String>['requested:windowClose']);
    expect(coordinator.begin('exitApp'), isFalse);
    expect(coordinator.exitReason, 'windowClose');
    expect(sink.events, hasLength(1));
  });

  test('意图先于退出链里第一个 await 落盘', () async {
    final Completer<void> stuck = Completer<void>();
    Future<void> chain() async {
      coordinator.begin('windowClose');
      await coordinator.runStep('exit flush', () => stuck.future);
    }

    final Future<void> running = chain();
    // 链卡在第一步（如同被安装器强杀前的那一刻）：意图与阶段都已落盘。
    expect(sink.events, <String>['requested:windowClose', 'stage:exit flush']);
    stuck.complete();
    await running;
  });

  test('并行步骤记在飞集合；超时 / 异常不外抛', () async {
    coordinator.begin('windowClose');
    final Completer<void> a = Completer<void>();
    final Future<void> both = Future.wait(<Future<void>>[
      coordinator.runStep('a', () => a.future),
      coordinator.runStep(
        'b',
        () => Future<void>.error(TimeoutException('slow')),
      ),
      coordinator.runStep('c', () => Future<void>.error(StateError('boom'))),
    ]);
    expect(sink.events, contains('stage:a+b'));
    expect(sink.events, contains('stage:a+b+c'));
    a.complete();
    await both;
    expect(coordinator.currentStage, isNull);
  });

  test('terminate：先补意图、再标 clean、最后 exit', () {
    coordinator.terminate('exitApp');
    expect(sink.events, <String>['requested:exitApp', 'clean:exitApp']);
    expect(exits, <int>[0]);

    // 进程级单例在测试里会被多次 terminate（假 exit 不真结束）：clean 每次都要写，
    // 否则后一次对新会话标记的 clean 会被前一次「已终止」短路。意图只认第一次。
    final List<int> injected = <int>[];
    coordinator.terminate('again', exitWith: injected.add, code: 3);
    expect(sink.events.last, 'clean:again');
    expect(
      sink.events.where((String e) => e.startsWith('requested')),
      hasLength(1),
    );
    expect(injected, <int>[3], reason: 'exitWith 透传更新交接的测试缝');
  });

  test('terminateVia（移动端插件退出）同样先 clean 后调用', () async {
    final List<String> order = <String>[];
    await coordinator.terminateVia('exitApp', () async {
      order.addAll(sink.events);
    });
    expect(order, <String>['requested:exitApp', 'clean:exitApp']);
  });

  test('看门狗时长 = 串行阶段预算之和 + 余量，并行阶段取最长', () {
    final Duration parallel = AppExitCoordinator.parallelBudget(<Duration>[
      const Duration(milliseconds: 1500),
      const Duration(seconds: 2),
      const Duration(milliseconds: 500),
    ]);
    expect(parallel, const Duration(seconds: 2));
    final Duration watchdog = AppExitCoordinator.watchdogTimeoutFor(<Duration>[
      const Duration(milliseconds: 800),
      parallel,
      const Duration(seconds: 5),
      const Duration(seconds: 3),
    ]);
    expect(
      watchdog,
      const Duration(milliseconds: 800 + 2000 + 5000 + 3000) +
          AppExitCoordinator.watchdogMargin,
    );
  });

  group('真会话标记', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('exit_coord_'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 偶发占用。
      }
    });

    test('意图已写、链被打断 → 下次启动归为 exitInterrupted，不上报', () {
      final File file = File('${tmp.path}/session_marker.json');
      final SessionMarker marker = SessionMarker(file, pid: 7, version: 'v')
        ..start(nowMs: 1);
      marker.recordLifecycle('resumed', nowMs: 2);
      marker.recordExitRequested('windowClose');
      marker.recordLifecycle('inactive', nowMs: 3); // hide 后 Windows 报 inactive
      marker.recordExitStage('database close');
      // 进程在这里被强杀：没有 markCleanExit。

      final PreviousSession? prev = SessionMarker(
        file,
        pid: 8,
        version: 'v',
      ).start(nowMs: 4);
      final ExitReportEntry entry = describeUncleanPreviousSession(prev)!;
      expect(entry.kind, PreviousExitKind.exitInterrupted);
      expect(entry.severe, isFalse);
      expect(entry.text, contains('exitRequested=windowClose'));
      expect(entry.text, contains('exitStage=database close'));
      final PreviousExitVerdict verdict = classifyPreviousExit(
        <ExitReportEntry>[entry],
        version: 'v',
        nowMs: 5,
      )!;
      expect(verdict.worthReporting, isFalse);
    });

    test('看门狗结束 = clean，但留一条带卡住阶段的诊断', () {
      final File file = File('${tmp.path}/session_marker.json');
      final SessionMarker marker = SessionMarker(file, pid: 7, version: 'v')
        ..start(nowMs: 1);
      marker.recordExitRequested('windowClose');
      marker.recordExitStage('book-exit sync drain');
      marker.markCleanExit(nowMs: 9, terminatedBy: kExitTerminatedByWatchdog);

      final PreviousSession? prev = SessionMarker(
        file,
        pid: 8,
        version: 'v',
      ).start(nowMs: 10);
      expect(describeUncleanPreviousSession(prev), isNull);
      final ExitReportEntry forced = describeForcedPreviousExit(prev)!;
      expect(forced.kind, isNull);
      expect(forced.severe, isFalse);
      expect(forced.text, contains('stuckAt=book-exit sync drain'));
    });
  });
}
