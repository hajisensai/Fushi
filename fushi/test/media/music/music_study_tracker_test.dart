import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/music_study_tracker.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;
import 'package:fushi_core/fushi_core.dart';

class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _item(String uid) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: 'Song $uid',
  durationMs: 240000,
);

void main() {
  test('判据：没在播不计；开关开着在播就计；关着只在学习动作后的空闲窗口内计', () {
    final DateTime now = DateTime(2026, 10, 24, 12);
    const Duration idle = Duration(minutes: 10);
    expect(
      musicStudyClockMayRun(
        playing: false,
        listeningCountsAsStudy: true,
        lastLearningActionAt: now,
        now: now,
        idleTimeout: idle,
      ),
      isFalse,
    );
    expect(
      musicStudyClockMayRun(
        playing: true,
        listeningCountsAsStudy: true,
        lastLearningActionAt: null,
        now: now,
        idleTimeout: idle,
      ),
      isTrue,
    );
    expect(
      musicStudyClockMayRun(
        playing: true,
        listeningCountsAsStudy: false,
        lastLearningActionAt: null,
        now: now,
        idleTimeout: idle,
      ),
      isFalse,
      reason: 'D4：没有学习动作，光听不计',
    );
    expect(
      musicStudyClockMayRun(
        playing: true,
        listeningCountsAsStudy: false,
        lastLearningActionAt: now.subtract(const Duration(minutes: 9)),
        now: now,
        idleTimeout: idle,
      ),
      isTrue,
    );
    expect(
      musicStudyClockMayRun(
        playing: true,
        listeningCountsAsStudy: false,
        lastLearningActionAt: now.subtract(const Duration(minutes: 11)),
        now: now,
        idleTimeout: idle,
      ),
      isFalse,
    );
  });

  group('写入面', () {
    late FushiDatabase db;
    late _Backend backend;
    late MusicPlayerEngine engine;
    late bool counts;
    late DateTime clockNow;
    final List<({String mediaKey, String title, Duration? idle})> built =
        <({String mediaKey, String title, Duration? idle})>[];
    final List<StudyClock> clocks = <StudyClock>[];

    MusicStudyTracker tracker() => MusicStudyTracker(
      engine: engine,
      database: () => db,
      listeningCountsAsStudy: () => counts,
      idleTimeout: () => const Duration(minutes: 10),
      now: () => clockNow,
      clockFactory:
          ({
            required FushiDatabase database,
            required MusicPlayItem item,
            required Duration? idleTimeout,
          }) {
            built.add((
              mediaKey: item.trackUid,
              title: item.title,
              idle: idleTimeout,
            ));
            final StudyClock c = StudyClock(
              database: database,
              mediaKind: kActivityMediaMusic,
              mediaKey: item.trackUid,
              title: item.title,
              idleTimeout: idleTimeout,
              deviceId: () async => 'dev',
              now: () => clockNow,
              tick: const Duration(days: 1),
            );
            clocks.add(c);
            return c;
          },
    );

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      backend = _Backend();
      engine = MusicPlayerEngine(backendFactory: () => backend);
      counts = false;
      clockNow = DateTime(2026, 10, 24, 12);
      built.clear();
      clocks.clear();
    });

    tearDown(() async {
      engine.dispose();
      await db.close();
    });

    test('开关关着：光听不起表；学习动作后起表；换曲封段、清掉「已投入」', () async {
      final MusicStudyTracker t = tracker();
      addTearDown(t.dispose);
      await engine.playQueue(<MusicPlayItem>[_item('a'), _item('b')]);
      expect(t.isRunning, isFalse, reason: '没有学习动作');

      t.noteLearningAction();
      expect(t.isRunning, isTrue);
      expect(built.single.mediaKey, 'a');
      expect(built.single.idle, const Duration(minutes: 10));

      // 断档守卫 120 s：一个窗口内推进 90 s。
      clockNow = clockNow.add(const Duration(seconds: 90));
      await engine.pause();
      expect(t.isRunning, isFalse, reason: '暂停停表');
      await clocks.single.stop(); // 等停表那次落库写完（stop 幂等，第二次只等写链）
      final List<StudySegmentRow> segs = await db.getStudySegments();
      expect(segs.single.mediaKind, kActivityMediaMusic);
      expect(segs.single.mediaKey, 'a');
      expect(segs.single.title, 'Song a');
      expect(
        segs.single.durationMs,
        const Duration(seconds: 90).inMilliseconds,
      );

      await engine.play();
      expect(t.isRunning, isTrue, reason: '空闲窗口内续表');
      await engine.skipNext();
      expect(t.isRunning, isFalse, reason: '换曲：b 还没有学习动作');
    });

    test('开关开着：在播就计，不设空闲门；改开关按新口径重建时钟', () async {
      counts = true;
      final MusicStudyTracker t = tracker();
      addTearDown(t.dispose);
      await engine.playQueue(<MusicPlayItem>[_item('a')]);
      expect(t.isRunning, isTrue);
      expect(built.single.idle, isNull);

      counts = false;
      t.onSettingChanged();
      expect(t.isRunning, isFalse, reason: '关掉开关且没有学习动作：停表');
      expect(clocks.single.isRunning, isFalse);
    });
  });
}
