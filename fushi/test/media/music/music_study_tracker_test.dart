import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/music_study_tracker.dart';
import 'package:fushi_audio/fushi_audio.dart' show StudyClock;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/study_char_count.dart';
import 'package:fushi_music/fushi_music.dart'
    show LyricLine, LyricSyllable, LyricTimeline;
import 'package:fushi/src/stats/interval_coverage.dart';

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
    Duration startAt = Duration.zero,
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
    final Map<String, LyricTimeline> lyrics = <String, LyricTimeline>{};
    final List<bool> lyricsWanted = <bool>[];

    MusicStudyTracker tracker() => MusicStudyTracker(
      engine: engine,
      database: () => db,
      listeningCountsAsStudy: () => counts,
      idleTimeout: () => const Duration(minutes: 10),
      lyricsFor: (String uid) => lyrics[uid],
      setLyricsWanted: lyricsWanted.add,
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
      lyrics.clear();
      lyricsWanted.clear();
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

    /// 推进一次位置：墙钟走 [wallMs]，后端报位置 [ms]。
    void at(int ms, {int wallMs = 500}) {
      clockNow = clockNow.add(Duration(milliseconds: wallMs));
      backend.controller.add(
        MusicBackendPosition(Duration(milliseconds: ms), null),
      );
    }

    /// 从 [fromMs] 连续播放到 [toMs]（每 500 ms 一个位置事件）。
    void playTo(int fromMs, int toMs) {
      for (int ms = fromMs + 500; ms <= toMs; ms += 500) {
        at(ms);
      }
    }

    Future<int> totalChars() async {
      for (final StudyClock c in clocks) {
        await c.stop();
      }
      int sum = 0;
      for (final StudySegmentRow s in await db.getStudySegments()) {
        sum += s.chars;
      }
      return sum;
    }

    test('歌词字数（决策 qQTh1Q3G9U a）：播走一句计一句；擦过去不计；每首每句跨会话只计一次', () async {
      counts = true;
      final int c0 = countStudyChars('ねえ、まだ起きてる？');
      final int c1 = countStudyChars('うん、眠れなくて。');
      final int c2 = countStudyChars('じゃあ話そう');
      lyrics['a'] = LyricTimeline(
        format: 'lrc',
        lines: <LyricLine>[
          _line(0, 3000, 'ねえ、まだ起きてる？'),
          _line(3000, 6000, 'うん、眠れなくて。'),
          _line(6000, 7000, 'じゃあ話そう'),
        ],
      );
      MusicStudyTracker t = tracker();
      await engine.playQueue(<MusicPlayItem>[_item('a')]);
      expect(lyricsWanted.last, isTrue, reason: '时钟可能走：请后台解析歌词');
      await t.debugCoverageLoaded;
      at(0, wallMs: 0);

      playTo(0, 3000); // 第 0 句播完，进第 1 句
      at(6000, wallMs: 50); // 拖进度：第 1 句只停了一下，不计
      playTo(6000, 7000);
      at(1000, wallMs: 50); // 往回拖：第 2 句（1 s 长）已播满，计
      playTo(1000, 3000); // 第 0 句重听：已计过，不再计
      t.dispose();

      final IntervalCoverage saved = IntervalCoverage.fromJson(
        await db.getPref(musicLyricCoveragePrefKey('a')),
      );
      expect(saved.ranges, <(int, int)>[(0, 3000), (6000, 7000)]);

      // 下一次会话：第 0 句仍不计，第 1 句第一次播完才计。
      t = tracker();
      addTearDown(t.dispose);
      at(0, wallMs: 50);
      await t.debugCoverageLoaded;
      playTo(0, 6000);
      expect(await totalChars(), c0 + c2 + c1);
    });

    test('歌词字数跟着时长走：时长不计时字数不计、也不记成已计', () async {
      lyrics['a'] = LyricTimeline(
        format: 'lrc',
        lines: <LyricLine>[
          _line(0, 3000, 'ねえ、まだ起きてる？'),
          _line(3000, 6000, 'うん、眠れなくて。'),
          _line(6000, 9000, 'じゃあ話そう'),
        ],
      );
      final MusicStudyTracker t = tracker();
      addTearDown(t.dispose);
      await engine.playQueue(<MusicPlayItem>[_item('a')]);
      expect(lyricsWanted.single, isFalse, reason: 'D4 默认：光听不计，不必解析歌词');
      at(0, wallMs: 0);
      playTo(0, 3500);
      expect(built, isEmpty, reason: '没有学习动作，不建钟');

      t.noteLearningAction();
      expect(lyricsWanted.last, isTrue);
      await t.debugCoverageLoaded;
      playTo(3500, 6000); // 第 1 句播走：此时在计时，计
      playTo(6000, 8000);
      await engine.pause();
      at(1000, wallMs: 50); // 暂停中拖走第 2 句：停表，不计
      expect(await totalChars(), countStudyChars('うん、眠れなくて。'));
      final IntervalCoverage saved = IntervalCoverage.fromJson(
        await db.getPref(musicLyricCoveragePrefKey('a')),
      );
      expect(saved.ranges, <(int, int)>[(3000, 6000)]);
    });
  });

  test('判据：一句的时间窗过半已计过才算计过', () {
    final IntervalCoverage counted = IntervalCoverage(<(int, int)>[(0, 3000)]);
    expect(musicLyricLineAlreadyCounted(counted, 0, 3000), isTrue);
    expect(
      musicLyricLineAlreadyCounted(counted, 200, 3200),
      isTrue,
      reason: '换来源 / 调偏移的轴抖动',
    );
    expect(musicLyricLineAlreadyCounted(counted, 2000, 5000), isFalse);
    expect(musicLyricLineAlreadyCounted(counted, 3000, 3000), isFalse);
    expect(counted.ranges, <(int, int)>[(0, 3000)], reason: '判据不改并集');
  });

  test('判据：停留量只算连续播放；换曲时句尾播得完才补', () {
    expect(
      musicLyricLinePlayedDelta(
        fromMs: 1000,
        toMs: 1500,
        lineEndMs: 3000,
        wallMs: 500,
        speed: 1,
        playing: true,
      ),
      500,
    );
    expect(
      musicLyricLinePlayedDelta(
        fromMs: 1000,
        toMs: 1500,
        lineEndMs: 3000,
        wallMs: 500,
        speed: 1,
        playing: false,
      ),
      0,
      reason: '暂停',
    );
    expect(
      musicLyricLinePlayedDelta(
        fromMs: 1000,
        toMs: 8000,
        lineEndMs: 3000,
        wallMs: 50,
        speed: 1,
        playing: true,
      ),
      0,
      reason: '拖进度跳变',
    );
    expect(
      musicLyricLinePlayedDelta(
        fromMs: 2800,
        toMs: 3300,
        lineEndMs: 3000,
        wallMs: 500,
        speed: 1,
        playing: true,
      ),
      200,
      reason: '截在句尾',
    );
    expect(
      musicLyricLinePlayedDelta(
        fromMs: 2800,
        toMs: null,
        lineEndMs: 3000,
        wallMs: 300,
        speed: 1,
        playing: true,
      ),
      200,
      reason: '换曲：旧曲播到头，补句尾',
    );
    expect(
      musicLyricLinePlayedDelta(
        fromMs: 1000,
        toMs: null,
        lineEndMs: 30000,
        wallMs: 300,
        speed: 1,
        playing: true,
      ),
      0,
      reason: '手动切歌：句尾还长，不补',
    );
  });
}

LyricLine _line(int startMs, int endMs, String text) => LyricLine(
  startMs: startMs,
  endMs: endMs,
  syllables: <LyricSyllable>[
    LyricSyllable(text: text, startMs: startMs, endMs: endMs),
  ],
);
