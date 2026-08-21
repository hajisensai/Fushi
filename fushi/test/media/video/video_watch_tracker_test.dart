import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi_audio/fushi_audio.dart';

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

AudioCue _cue(String text, {int startMs = 0, int endMs = 10000}) => AudioCue()
  ..text = text
  ..startMs = startMs
  ..endMs = endMs;

/// 模拟真实播放推进：isPlaying=true，位置按 [stepMs]（≤ 观察封顶）逐步前进并通知。
void _playThrough(_FakeSource src,
    {required int fromMs, required int toMs, int stepMs = 500}) {
  src.isPlaying = true;
  for (int pos = fromMs; pos <= toMs; pos += stepMs) {
    src.positionMs = pos;
    src.emit();
  }
}

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

  group('subtitle char counting (dwell gate + monotonic dedup, BUG-1763)', () {
    late _FakeSource src;
    late VideoWatchTracker tracker;
    late List<(String, int)> recorded;
    setUp(() {
      recorded = <(String, int)>[];
      src = _FakeSource();
      tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        recordFlush: (List<(String, int, int)> buckets) {},
        addSubtitleChars: (String dateKey, int chars) =>
            recorded.add((dateKey, chars)),
        markCompleted: (_) async {},
      )..attach(src);
    });
    tearDown(() => tracker.dispose());

    test('真实播放停留 ≥ 门槛才计；回看已计的句不重复计', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう'); // 3
      _playThrough(src, fromMs: 0, toMs: 2000); // ≥ kCueDwellMs → 计
      expect(tracker.debugSubtitleChars, 3);
      src.currentCueIndex = 1;
      src.currentCue = _cue('かきくけ'); // 4
      _playThrough(src, fromMs: 2000, toMs: 4000);
      src.currentCueIndex = 0; // 回看第一句并再次真实停留
      src.currentCue = _cue('あいう');
      _playThrough(src, fromMs: 0, toMs: 2000);
      expect(tracker.debugSubtitleChars, 7, reason: '去重集挡重复入账');
    });

    test('暂停态拖进度条落点命中 cue 不计（位置进入 ≠ 看过）', () {
      src.isPlaying = false;
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいうえお');
      for (final int pos in <int>[100, 3000, 6000, 9000]) {
        src.positionMs = pos;
        src.emit();
      }
      src.currentCueIndex = 1; // 离开该句：候选未攒到任何播放推进 → 丢弃
      src.currentCue = _cue('か');
      src.emit();
      expect(tracker.debugSubtitleChars, 0);
      expect(recorded, isEmpty);
    });

    test('播放中快速掠过（停留 < 门槛）不计', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう', endMs: 5000); // 门槛 = 1500
      _playThrough(src, fromMs: 0, toMs: 1000); // 只推进 1000ms
      src.currentCueIndex = 1;
      src.currentCue = _cue('か', startMs: 5000, endMs: 20000);
      src.emit();
      expect(tracker.debugSubtitleChars, 0);
    });

    test('短 cue 以自身时长为门（否则永远不计）', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あい', endMs: 800); // 门槛 = 800
      _playThrough(src, fromMs: 0, toMs: 800, stepMs: 200);
      expect(tracker.debugSubtitleChars, 2);
    });

    test('cue 内 seek 的位置跳变不算停留（单次观察封顶）', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう');
      src.isPlaying = true;
      src.positionMs = 0;
      src.emit(); // 进入观察窗
      src.positionMs = 5000; // 一次跳 5s：非真实播放推进，封顶后不足门槛
      src.emit();
      src.currentCueIndex = -1; // 离开：未达门槛 → 丢弃
      src.currentCue = null;
      src.emit();
      expect(tracker.debugSubtitleChars, 0);
    });

    test('addSubtitleChars 收到 yyyy-MM-dd dateKey', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう');
      _playThrough(src, fromMs: 0, toMs: 2000);
      expect(recorded, hasLength(1));
      expect(recorded.single.$1, matches(r'^\d{4}-\d{2}-\d{2}$')); // dateKey
      expect(recorded.single.$2, 3); // chars
    });

    test('onEpisodeChanged resets dedup set', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あい'); // 2
      _playThrough(src, fromMs: 0, toMs: 2000);
      tracker.onEpisodeChanged();
      src.currentCueIndex = 0; // 新集第 0 句
      src.currentCue = _cue('うえお'); // 3
      _playThrough(src, fromMs: 0, toMs: 2000);
      expect(tracker.debugSubtitleChars, 5);
    });

    test('gap (index -1) does not count', () {
      src.currentCueIndex = -1;
      src.currentCue = null;
      src.emit();
      expect(tracker.debugSubtitleChars, 0);
    });
  });

  group('shouldCountCueDwell（纯谓词）', () {
    test('长 cue 固定门槛 kCueDwellMs', () {
      expect(
          shouldCountCueDwell(playedMs: 1499, cueStartMs: 0, cueEndMs: 10000),
          isFalse);
      expect(
          shouldCountCueDwell(playedMs: 1500, cueStartMs: 0, cueEndMs: 10000),
          isTrue);
    });
    test('短 cue 门槛 = 自身时长', () {
      expect(shouldCountCueDwell(playedMs: 799, cueStartMs: 0, cueEndMs: 800),
          isFalse);
      expect(shouldCountCueDwell(playedMs: 800, cueStartMs: 0, cueEndMs: 800),
          isTrue);
    });
    test('起止时刻缺失/非法回退固定门槛', () {
      expect(
          shouldCountCueDwell(playedMs: 1500, cueStartMs: null, cueEndMs: null),
          isTrue);
      expect(shouldCountCueDwell(playedMs: 1499, cueStartMs: 500, cueEndMs: 0),
          isFalse);
    });
  });

  group('exit flush awaits async stat writes (TODO-086/BUG-192)', () {
    test('stop() future completes only after the async flush write commits',
        () async {
      final List<int> committed = <int>[];
      final _FakeSource src = _FakeSource()..isPlaying = true;
      // recordFlush 模拟异步落库（后台 isolate 写 Drift）：只有当 tracker 真的
      // await 它，stop() 返回时 committed 才非空。撤掉 _flush/stop 的 await（改回
      // fire-and-forget）会让本断言转红——锁住退出时统计不丢。
      final VideoWatchTracker tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        recordFlush: (List<(String, int, int)> buckets) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          for (final (_, _, int ms) in buckets) {
            if (ms > 0) committed.add(ms);
          }
        },
        addSubtitleChars: (String dateKey, int chars) {},
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

  group('external episode completion callback', () {
    test('fires once at 90% and resets only when the episode changes',
        () async {
      int completed = 0;
      final _FakeSource src = _FakeSource()
        ..positionMs = 90
        ..durationMs = 100;
      final VideoWatchTracker tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        recordFlush: (List<(String, int, int)> buckets) {},
        addSubtitleChars: (String dateKey, int chars) {},
        markCompleted: (_) async {},
        onEpisodeCompleted: () => completed++,
      )..attach(src);

      tracker.start();
      await tracker.stop();
      tracker.start();
      await tracker.stop();
      expect(completed, 1);

      tracker.onEpisodeChanged();
      tracker.start();
      await tracker.stop();
      expect(completed, 2);
      tracker.dispose();
    });
  });

  group('recordActivity (v49 首页 Activity 事件流)', () {
    test('一次观看 session 结束落一条活动事件，携带累积净观看时长', () async {
      final List<(String, String, int, int)> events =
          <(String, String, int, int)>[];
      final _FakeSource src = _FakeSource()..isPlaying = true;
      final VideoWatchTracker tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        recordFlush: (List<(String, int, int)> buckets) async {},
        addSubtitleChars: (String dateKey, int chars) {},
        markCompleted: (_) async {},
        recordActivity: (String t, String uid, String dateKey, int timestampMs,
            int durationMs, int chars) {
          events.add((t, uid, durationMs, chars));
        },
      )..attach(src);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tracker.stop();

      expect(events, hasLength(1));
      expect(events.single.$1, 'A');
      expect(events.single.$2, 'u1');
      expect(events.single.$3, greaterThan(0)); // 净观看时长
    });

    test('二次 stop 幂等：不重复写活动事件（累积已清零）', () async {
      final List<int> durations = <int>[];
      final _FakeSource src = _FakeSource()..isPlaying = true;
      final VideoWatchTracker tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        recordFlush: (List<(String, int, int)> buckets) async {},
        addSubtitleChars: (String dateKey, int chars) {},
        markCompleted: (_) async {},
        recordActivity: (String t, String uid, String dateKey, int timestampMs,
                int durationMs, int chars) =>
            durations.add(durationMs),
      )..attach(src);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tracker.stop();
      await tracker.stop(); // 第二次不应再写（会话累积已清零）
      expect(durations, hasLength(1));
    });

    test('从未播放（无净时长）不落活动事件', () async {
      final List<int> durations = <int>[];
      final _FakeSource src = _FakeSource()..isPlaying = false;
      final VideoWatchTracker tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        recordFlush: (List<(String, int, int)> buckets) async {},
        addSubtitleChars: (String dateKey, int chars) {},
        markCompleted: (_) async {},
        recordActivity: (String t, String uid, String dateKey, int timestampMs,
                int durationMs, int chars) =>
            durations.add(durationMs),
      )..attach(src);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tracker.stop();
      expect(durations, isEmpty);
    });

    test('活动事件 dateKey 取 stop 时刻（session 语义，刻意区别于桶归属）', () async {
      // 防「顺手统一」：activity 行是 session 事件（stop 时刻 dateKey + 总量），
      // 桶（recordFlush）各归各日。这里锁 activity 的 dateKey 形状与「= stop 当日」。
      String? activityDateKey;
      final _FakeSource src = _FakeSource()..isPlaying = true;
      final VideoWatchTracker tracker = VideoWatchTracker(
        title: 'A',
        bookUid: 'u1',
        recordFlush: (List<(String, int, int)> buckets) async {},
        addSubtitleChars: (String dateKey, int chars) {},
        markCompleted: (_) async {},
        recordActivity: (String t, String uid, String dateKey, int timestampMs,
                int durationMs, int chars) =>
            activityDateKey = dateKey,
      )..attach(src);

      tracker.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final DateTime beforeStop = DateTime.now();
      await tracker.stop();
      final DateTime afterStop = DateTime.now();

      expect(activityDateKey, isNotNull);
      // stop 前后取到的「当日」至少有一个等于 activity 的 dateKey（测试恰跨午夜时
      // 两者取其一），锁住「activity dateKey = stop 时刻当日」的语义。
      final Set<String> stopDays = <String>{
        '${beforeStop.year}-${beforeStop.month.toString().padLeft(2, '0')}-'
            '${beforeStop.day.toString().padLeft(2, '0')}',
        '${afterStop.year}-${afterStop.month.toString().padLeft(2, '0')}-'
            '${afterStop.day.toString().padLeft(2, '0')}',
      };
      expect(stopDays, contains(activityDateKey));
    });
  });
}
