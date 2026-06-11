import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_playback_source.dart';
import 'package:hibiki/src/media/video/video_watch_tracker.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

class _FakeSource extends ChangeNotifier implements VideoPlaybackSource {
  @override
  bool isPlaying = false;
  @override
  int currentCueIndex = -1;
  @override
  AudioCue? currentCue;
  @override
  int? positionMs;
  @override
  int? durationMs;
  void emit() => notifyListeners();
}

AudioCue _cue(String text) => AudioCue()..text = text;

void main() {
  group('shouldMarkCompleted', () {
    test('true when >=90% and not yet completed', () {
      expect(shouldMarkCompleted(90, 100, false), isTrue);
      expect(shouldMarkCompleted(95, 100, false), isTrue);
    });
    test('false below 90%', () {
      expect(shouldMarkCompleted(89, 100, false), isFalse);
    });
    test('false when already completed', () {
      expect(shouldMarkCompleted(99, 100, true), isFalse);
    });
    test('false when duration unknown / position null', () {
      expect(shouldMarkCompleted(50, 0, false), isFalse);
      expect(shouldMarkCompleted(50, null, false), isFalse);
      expect(shouldMarkCompleted(null, 100, false), isFalse);
    });
  });

  group('splitWatchTime', () {
    test('same hour single bucket', () {
      final r = splitWatchTime(
          DateTime(2026, 6, 6, 9, 0, 0), DateTime(2026, 6, 6, 9, 0, 30));
      expect(r, [('2026-06-06', 9, 30000)]);
    });
    test('crossing hour splits into two buckets', () {
      final r = splitWatchTime(
          DateTime(2026, 6, 6, 9, 59, 50), DateTime(2026, 6, 6, 10, 0, 10));
      expect(r.length, 2);
      expect(r[0].$1, '2026-06-06');
      expect(r[0].$2, 9);
      expect(r[1].$2, 10);
    });
    test('crossing midnight splits into two days', () {
      final r = splitWatchTime(
          DateTime(2026, 6, 6, 23, 59, 50), DateTime(2026, 6, 7, 0, 0, 10));
      expect(r.length, 2);
      expect(r[0], ('2026-06-06', 23, 10000));
      expect(r[1], ('2026-06-07', 0, 10000));
    });
    test('zero or negative elapsed yields empty', () {
      expect(
          splitWatchTime(
              DateTime(2026, 6, 6, 9, 0, 0), DateTime(2026, 6, 6, 9, 0, 0)),
          isEmpty);
    });
  });

  group('isContinuousWatchGap (clamp anomalous timer gaps)', () {
    test('normal ~60s window is continuous', () {
      expect(
          isContinuousWatchGap(
              DateTime(2026, 6, 6, 9, 0, 0), DateTime(2026, 6, 6, 9, 1, 0)),
          isTrue);
    });
    test('boundary at exactly kMaxWatchGap is still continuous', () {
      final DateTime s = DateTime(2026, 6, 6, 9, 0, 0);
      expect(isContinuousWatchGap(s, s.add(kMaxWatchGap)), isTrue);
    });
    test('gap beyond kMaxWatchGap (suspend/sleep) is discarded', () {
      final DateTime s = DateTime(2026, 6, 6, 9, 0, 0);
      expect(isContinuousWatchGap(s, s.add(const Duration(hours: 3))), isFalse);
      expect(
          isContinuousWatchGap(
              s, s.add(kMaxWatchGap + const Duration(seconds: 1))),
          isFalse);
    });
    test('zero / negative gap is not continuous', () {
      final DateTime s = DateTime(2026, 6, 6, 9, 0, 0);
      expect(isContinuousWatchGap(s, s), isFalse);
      expect(isContinuousWatchGap(s, s.subtract(const Duration(seconds: 5))),
          isFalse);
    });
  });

  group('subtitle char counting (monotonic dedup per episode)', () {
    late _FakeSource src;
    late VideoWatchTracker tracker;
    late List<(String, String, int, int)> recorded;
    setUp(() {
      recorded = <(String, String, int, int)>[];
      src = _FakeSource();
      tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        addStat: (title, dateKey, chars, ms) =>
            recorded.add((title, dateKey, chars, ms)),
        markCompleted: (_) async {},
      )..attach(src);
    });
    tearDown(() => tracker.dispose());

    test('counts a new cue once; re-seek to same cue does not double-count',
        () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう'); // 3
      src.emit();
      src.currentCueIndex = 1;
      src.currentCue = _cue('かきくけ'); // 4
      src.emit();
      src.currentCueIndex = 0; // 回看第一句
      src.currentCue = _cue('あいう');
      src.emit();
      expect(tracker.debugSubtitleChars, 7);
    });

    test('addStat receives a yyyy-MM-dd dateKey for subtitle chars', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう');
      src.emit();
      expect(recorded, hasLength(1));
      expect(recorded.single.$1, 'A'); // title
      expect(recorded.single.$2, matches(r'^\d{4}-\d{2}-\d{2}$')); // dateKey
      expect(recorded.single.$3, 3); // chars
      expect(recorded.single.$4, 0); // watchTimeMs（字幕路径不计时长）
    });

    test('onEpisodeChanged resets dedup set', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あい'); // 2
      src.emit();
      tracker.onEpisodeChanged();
      src.currentCueIndex = 0; // 新集第 0 句
      src.currentCue = _cue('うえお'); // 3
      src.emit();
      expect(tracker.debugSubtitleChars, 5);
    });

    test('gap (index -1) does not count', () {
      src.currentCueIndex = -1;
      src.currentCue = null;
      src.emit();
      expect(tracker.debugSubtitleChars, 0);
    });
  });

  group('exit flush awaits async stat writes (TODO-086/BUG-192)', () {
    test('stop() future completes only after the async stat write commits',
        () async {
      final List<int> committed = <int>[];
      final _FakeSource src = _FakeSource()..isPlaying = true;
      // addStat 模拟异步落库（后台 isolate 写 Drift）：只有当 tracker 真的 await
      // 它，stop() 返回时 committed 才非空。撤掉 _flush/stop 的 await（改回
      // fire-and-forget）会让本断言转红——锁住退出时统计不丢。
      final VideoWatchTracker tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        addStat: (String t, String dateKey, int chars, int ms) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (ms > 0) committed.add(ms); // 只看观看时长写（chars 路径 ms=0）
        },
        markCompleted: (_) async {},
      )..attach(src);

      tracker.start();
      // 制造一段连续播放窗口（>0 且 <= kMaxWatchGap）。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tracker.stop();

      expect(committed, isNotEmpty,
          reason: 'stop() 必须 await 异步统计写——否则 exit(0) 丢观看时长');
      expect(committed.first, greaterThan(0));
    });
  });
}
