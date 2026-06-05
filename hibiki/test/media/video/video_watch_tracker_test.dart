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
    test('zero or negative elapsed yields empty', () {
      expect(
          splitWatchTime(
              DateTime(2026, 6, 6, 9, 0, 0), DateTime(2026, 6, 6, 9, 0, 0)),
          isEmpty);
    });
  });

  group('subtitle char counting (monotonic dedup per episode)', () {
    late _FakeSource src;
    late VideoWatchTracker tracker;
    late List<(String, int, int)> recorded;
    setUp(() {
      recorded = <(String, int, int)>[];
      src = _FakeSource();
      tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        addStat: (title, chars, ms) => recorded.add((title, chars, ms)),
        markCompleted: (_) async {},
      )..attach(src);
    });
    tearDown(() => tracker.dispose());

    test('counts a new cue once; re-seek to same cue does not double-count', () {
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
}
