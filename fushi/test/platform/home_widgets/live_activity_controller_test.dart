import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/home_widgets/home_widget_channel.dart';
import 'package:fushi/src/platform/home_widgets/live_activity_controller.dart';

/// 记下每次原生调用；`start*` 可以挂起（[holdStarts]）来模拟 ActivityKit 慢返回。
class _FakeChannel extends HomeWidgetChannel {
  _FakeChannel();

  final List<String> calls = <String>[];
  final List<Map<String, Object?>?> endFinalStates = <Map<String, Object?>?>[];
  final List<double?> endLingers = <double?>[];
  bool enabled = true;
  bool holdStarts = false;
  final List<Completer<String?>> pendingStarts = <Completer<String?>>[];
  int _nextId = 0;

  Future<String?> _start(String kind) {
    calls.add('start$kind');
    final String id = '$kind${_nextId++}';
    if (!holdStarts) return Future<String?>.value(id);
    final Completer<String?> completer = Completer<String?>();
    pendingStarts.add(completer);
    return completer.future.then((String? value) => value ?? id);
  }

  /// 放行最早挂起的那个 start。
  void releaseStart() => pendingStarts.removeAt(0).complete(null);

  @override
  Future<bool> activitiesEnabled() async => enabled;

  @override
  Future<String?> startPlayback({
    required Map<String, Object?> attributes,
    required Map<String, Object?> state,
  }) => _start('Playback');

  @override
  Future<void> updatePlayback(String id, Map<String, Object?> state) async {
    calls.add('updatePlayback:$id:${state['isPlaying']}:${state['line']}');
  }

  @override
  Future<String?> startTask({
    required Map<String, Object?> attributes,
    required Map<String, Object?> state,
  }) => _start('Task');

  @override
  Future<void> updateTask(String id, Map<String, Object?> state) async {
    calls.add('updateTask:$id:${state['percentLabel']}');
  }

  @override
  Future<void> endActivity(
    String id, {
    double? dismissAfter,
    Map<String, Object?>? finalState,
  }) async {
    calls.add('end:$id');
    endLingers.add(dismissAfter);
    endFinalStates.add(finalState);
  }

  @override
  Future<void> endAllActivities() async => calls.add('endAll');
}

PlaybackActivitySample _playback({
  bool playing = true,
  String line = 'a',
  String kind = 'audiobook',
}) => PlaybackActivitySample(
  kind: kind,
  attributes: <String, Object?>{'kind': kind},
  state: PlaybackActivityState(
    title: 'Book',
    subtitle: 'Author',
    line: line,
    isPlaying: playing,
    progress: 0.1,
    elapsedLabel: '0:01',
    remainingLabel: '-9:59',
  ),
);

TaskActivitySample _task(String jobId, {String percent = '10%'}) =>
    TaskActivitySample(
      jobId: jobId,
      attributes: const <String, Object?>{'kind': 'transcribe'},
      state: TaskActivityState(
        title: 'Generating subtitles',
        detail: jobId,
        progress: 0.1,
        percentLabel: percent,
        finished: false,
      ),
    );

void main() {
  late _FakeChannel channel;
  PlaybackActivitySample? playback;
  TaskActivitySample? running;
  final Map<String, TaskActivitySample> finished =
      <String, TaskActivitySample>{};

  LiveActivityController controller({
    Duration pauseTimeout = const Duration(minutes: 10),
  }) => LiveActivityController(
    channel: channel,
    readPlayback: () => playback,
    readRunningTask: () => running,
    readFinishedTask: (String id) => finished[id],
    pauseTimeout: pauseTimeout,
  );

  setUp(() {
    channel = _FakeChannel();
    playback = null;
    running = null;
    finished.clear();
  });

  group('playback', () {
    test('starts once when playing, updates only on a real change', () async {
      final LiveActivityController c = controller();
      playback = _playback();
      await c.syncPlayback();
      await c.syncPlayback();
      playback = _playback(line: 'b');
      await c.syncPlayback();
      expect(channel.calls, <String>[
        'startPlayback',
        'updatePlayback:Playback0:true:b',
      ]);
    });

    test('a paused session never starts an activity', () async {
      final LiveActivityController c = controller();
      playback = _playback(playing: false);
      await c.syncPlayback();
      expect(channel.calls, isEmpty);
    });

    test(
      'changes while start is in flight converge after it returns',
      () async {
        final LiveActivityController c = controller();
        channel.holdStarts = true;
        playback = _playback();
        final Future<void> first = c.syncPlayback();
        await pumpEventQueue();
        // start 还没回：用户暂停并换了句。
        playback = _playback(playing: false, line: 'b');
        final Future<void> second = c.syncPlayback();
        await pumpEventQueue();
        expect(channel.calls, <String>['startPlayback']);
        channel.releaseStart();
        await Future.wait(<Future<void>>[first, second]);
        expect(channel.calls, <String>[
          'startPlayback',
          'updatePlayback:Playback0:false:b',
        ]);
      },
    );

    test(
      'session ending while start is in flight ends the new activity',
      () async {
        final LiveActivityController c = controller();
        channel.holdStarts = true;
        playback = _playback();
        final Future<void> first = c.syncPlayback();
        await pumpEventQueue();
        playback = null;
        unawaited(c.syncPlayback());
        channel.releaseStart();
        await first;
        expect(channel.calls, <String>['startPlayback', 'end:Playback0']);
        expect(c.playbackId, isNull);
      },
    );

    test('concurrent syncs never start two activities', () async {
      final LiveActivityController c = controller();
      channel.holdStarts = true;
      playback = _playback();
      final Future<void> first = c.syncPlayback();
      for (int i = 0; i < 5; i++) {
        unawaited(c.syncPlayback());
      }
      await pumpEventQueue();
      channel.releaseStart();
      await first;
      expect(
        channel.calls.where((String s) => s == 'startPlayback'),
        hasLength(1),
      );
    });

    test(
      'switching kind ends the old activity before starting a new one',
      () async {
        final LiveActivityController c = controller();
        playback = _playback();
        await c.syncPlayback();
        playback = _playback(kind: 'music');
        await c.syncPlayback();
        expect(channel.calls, <String>[
          'startPlayback',
          'end:Playback0',
          'startPlayback',
        ]);
        expect(c.playbackKind, 'music');
      },
    );

    test('pausing longer than the timeout ends the activity', () {
      fakeAsync((FakeAsync async) {
        final LiveActivityController c = controller(
          pauseTimeout: const Duration(minutes: 10),
        );
        playback = _playback();
        unawaited(c.syncPlayback());
        async.flushMicrotasks();
        playback = _playback(playing: false);
        unawaited(c.syncPlayback());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 9));
        expect(channel.calls.where((String s) => s.startsWith('end')), isEmpty);
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();
        expect(channel.calls.last, 'end:Playback0');
        // 继续暂停着：不会再起。
        unawaited(c.syncPlayback());
        async.flushMicrotasks();
        expect(channel.calls.last, 'end:Playback0');
        // 重新播放：起一个新的。
        playback = _playback();
        unawaited(c.syncPlayback());
        async.flushMicrotasks();
        expect(channel.calls.last, 'startPlayback');
      });
    });

    test('nothing starts when Live Activities are switched off', () async {
      final LiveActivityController c = controller();
      channel.enabled = false;
      playback = _playback();
      await c.syncPlayback();
      expect(channel.calls, isEmpty);
    });
  });

  group('transcription task', () {
    test('concurrent progress notifications start only one activity', () async {
      final LiveActivityController c = controller();
      channel.holdStarts = true;
      running = _task('job1');
      final Future<void> first = c.syncTask();
      running = _task('job1', percent: '11%');
      unawaited(c.syncTask());
      running = _task('job1', percent: '12%');
      unawaited(c.syncTask());
      await pumpEventQueue();
      channel.releaseStart();
      await first;
      expect(channel.calls, <String>['startTask', 'updateTask:Task0:12%']);
      expect(c.taskId, 'Task0');
    });

    test('finishing ends in one call carrying the final state', () async {
      final LiveActivityController c = controller();
      running = _task('job1');
      await c.syncTask();
      running = null;
      finished['job1'] = TaskActivitySample(
        jobId: 'job1',
        attributes: const <String, Object?>{},
        state: const TaskActivityState(
          title: 'Subtitles ready',
          detail: 'job1',
          progress: 1,
          percentLabel: '100%',
          finished: true,
        ),
      );
      await c.syncTask();
      expect(channel.calls, <String>['startTask', 'end:Task0']);
      expect(channel.endLingers.single, 30 * 60);
      expect(channel.endFinalStates.single?['finished'], isTrue);
      expect(channel.endFinalStates.single?['percentLabel'], '100%');
    });

    test(
      'a failed / removed job ends immediately without a final state',
      () async {
        final LiveActivityController c = controller();
        running = _task('job1');
        await c.syncTask();
        running = null;
        await c.syncTask();
        expect(channel.calls, <String>['startTask', 'end:Task0']);
        expect(channel.endLingers.single, isNull);
        expect(channel.endFinalStates.single, isNull);
      },
    );

    test('a different job replaces the activity', () async {
      final LiveActivityController c = controller();
      running = _task('job1');
      await c.syncTask();
      running = _task('job2');
      await c.syncTask();
      expect(channel.calls, <String>['startTask', 'end:Task0', 'startTask']);
      expect(c.taskId, 'Task1');
    });
  });

  test('dispose ends what this controller started', () async {
    final LiveActivityController c = controller();
    playback = _playback();
    running = _task('job1');
    await c.syncPlayback();
    await c.syncTask();
    c.dispose();
    expect(channel.calls, containsAll(<String>['end:Playback0', 'end:Task1']));
    await c.syncPlayback();
    expect(
      channel.calls.where((String s) => s == 'startPlayback'),
      hasLength(1),
    );
  });

  test('formatPlaybackClock / playbackWallClock', () {
    expect(formatPlaybackClock(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(
      formatPlaybackClock(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
    expect(formatPlaybackClock(const Duration(seconds: -3)), '0:00');
    final ({double startedAt, double endsAt})? clock = playbackWallClock(
      position: const Duration(seconds: 10),
      duration: const Duration(seconds: 100),
      speed: 2,
      now: DateTime.fromMillisecondsSinceEpoch(1000000),
    );
    expect(clock!.startedAt, 1000 - 5);
    expect(clock.endsAt, 1000 - 5 + 50);
    expect(
      playbackWallClock(
        position: Duration.zero,
        duration: Duration.zero,
        speed: 1,
        now: DateTime.now(),
      ),
      isNull,
    );
  });
}
