import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

// v92 统计域重构：观看时长不再由 VideoWatchTracker 自己计时 / 自己写活动行，而是
// 交给注入的 [StudyClock]（活跃态 = 正在播放），字幕字数经 `clock.addChars` 记到
// 同一段。因此本文件只剩三类断言：完成判定纯函数、字幕停留门（BUG-1763）、以及
// tracker 与时钟的接线（stop 落库 / 幂等 / 不播放不计时）。
//
// 已删除的用例（被测对象不存在了）：
//  * `splitWatchTime` / `isContinuousWatchGap` / `kMaxWatchGap` 两组纯函数——视频侧
//    现在直接用 fushi_audio 的 `splitReadingTime` / `isContinuousReadingGap` /
//    `kMaxReadingGap`，已由 `test/media/audiobook/study_clock_gap_test.dart` 覆盖；
//  * 「活动事件 dateKey 取 stop 时刻」——段的 dateKey 由段起点决定（跨小时 / 跨天
//    切段），语义已在 `study_clock_test.dart`「段边界与量纲」组覆盖。

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

/// 受控墙钟。停留量要与真实流逝时间对账（拖进度条时媒体时间猛进而墙钟不动，正是
/// 靠这个区分开的），所以测试必须显式决定墙钟走不走，不能借用真实时间。
DateTime _fakeNow = DateTime(2026, 1, 1, 12);
void _advanceWall(int ms) =>
    _fakeNow = _fakeNow.add(Duration(milliseconds: ms));

/// 模拟真实播放推进：isPlaying=true，位置逐步前进并通知，**墙钟同步走**。
void _playThrough(_FakeSource src,
    {required int fromMs, required int toMs, int stepMs = 500}) {
  src.isPlaying = true;
  for (int pos = fromMs; pos <= toMs; pos += stepMs) {
    if (pos > fromMs) _advanceWall(stepMs);
    src.positionMs = pos;
    src.emit();
  }
}

/// 模拟**生产真实通知节奏**：VideoPlayerController 的契约规定命中下标不变时不重复
/// notifyListeners（源码注释：「避免每 125ms tick 无谓 notifyListeners」），所以一句
/// cue 从进到出只有两次通知——进句一次、换句一次。中间墙钟与媒体时间照常流逝。
void _playCueProductionCadence(
  _FakeSource src, {
  required int index,
  required AudioCue cue,
  required int enterPosMs,
  required int watchedMs,
}) {
  src.isPlaying = true;
  src.currentCueIndex = index;
  src.currentCue = cue;
  src.positionMs = enterPosMs;
  src.emit(); // 进句：唯一一次
  _advanceWall(watchedMs);
  src.positionMs = enterPosMs + watchedMs;
  // 换句才会再通知一次；本函数只负责走完这一句，换句由调用方发起。
}

/// 注入给 [StudyClock] 的落库替身：记录每次绝对值写；可注入延迟模拟后台 isolate
/// 写 Drift（stop 是否真的 await 了写链只有这样才测得出来）。
class _Sink {
  _Sink({this.delay = Duration.zero});

  final Duration delay;
  final List<StudySegmentsCompanion> writes = <StudySegmentsCompanion>[];

  Future<void> call(StudySegmentsCompanion row) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    writes.add(row);
  }
}

/// 建一个全注入的时钟：DB 只是构造签名要求（sink / deviceId / uid 全部替身，
/// 不会碰它）；`now` 不注入时走真实墙钟——接线用例靠真实 delay 制造窗口。
StudyClock _clock(_Sink sink, {DateTime Function()? now}) {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  int seq = 0;
  return StudyClock(
    database: db,
    mediaKind: kActivityMediaVideo,
    mediaKey: 'u1',
    title: 'A',
    sink: sink.call,
    deviceId: () async => 'dev',
    now: now,
    uidFactory: () => 'seg${++seq}',
  );
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

  group('subtitle char counting (dwell gate + monotonic dedup, BUG-1763)', () {
    late _FakeSource src;
    late _Sink sink;
    late StudyClock clock;
    late VideoWatchTracker tracker;
    setUp(() {
      src = _FakeSource();
      sink = _Sink();
      clock = _clock(sink);
      tracker = VideoWatchTracker(
        bookUid: 'u1',
        clock: clock,
        markCompleted: (_) async {},
      )..attach(src);
      _fakeNow = DateTime(2026, 1, 1, 12);
      tracker.debugNowForTesting = () => _fakeNow;
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
      expect(clock.debugOpenTotals, isNull, reason: '没有字数就不会开段');
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

    test('cue 内 seek 的位置跳变不算停留（墙钟没走）', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう');
      src.isPlaying = true;
      src.positionMs = 0;
      src.emit(); // 进入观察窗
      // 墙钟**不推进**：媒体时间一次跳 5s 而现实只过了一瞬 = seek，不是停留。
      src.positionMs = 5000;
      src.emit();
      src.currentCueIndex = -1; // 离开：未达门槛 → 丢弃
      src.currentCue = null;
      src.emit();
      expect(tracker.debugSubtitleChars, 0);
    });

    // 回归锚：旧实现按「同句 tick」累加停留量，而生产端明确抑制同句 tick 通知，
    // 于是这条路径在真机上恒为 0 —— 字幕字数永远计不上，而每 500ms emit 一次的假源
    // 测试照样全绿。这条用例按生产真实节奏驱动：一句只通知两次。
    test('生产通知节奏（一句只通知两次）下仍能计入字幕字数', () {
      _playCueProductionCadence(src,
          index: 0, cue: _cue('あいう'), enterPosMs: 0, watchedMs: 2000);
      // 换句：这是上一句能收到的最后一次通知，停留量在此结算。
      src.currentCueIndex = 1;
      src.currentCue = _cue('か', startMs: 10000, endMs: 20000);
      src.emit();
      expect(tracker.debugSubtitleChars, 3,
          reason: '一句只通知两次时也必须计入，否则真机上字幕字数恒 0');
    });

    test('生产节奏下拖进度条掠过整句仍不计（墙钟没走）', () {
      src.isPlaying = true;
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいうえお');
      src.positionMs = 0;
      src.emit();
      // 媒体时间瞬间推进 9s，墙钟一动不动 = 拖条，不是看。
      src.positionMs = 9000;
      src.currentCueIndex = 1;
      src.currentCue = _cue('か', startMs: 10000, endMs: 20000);
      src.emit();
      expect(tracker.debugSubtitleChars, 0);
      expect(clock.debugOpenTotals, isNull);
    });

    test('达标的字幕字数记进时钟当前段（与观看时长同一段）', () {
      src.currentCueIndex = 0;
      src.currentCue = _cue('あいう');
      _playThrough(src, fromMs: 0, toMs: 2000);
      expect(clock.debugOpenTotals, isNotNull);
      expect(clock.debugOpenTotals!.chars, 3);
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
    test('stop() future completes only after the async segment write commits',
        () async {
      // sink 模拟异步落库（后台 isolate 写 Drift）：只有当 tracker.stop 真的
      // await 了时钟写链，stop() 返回时 writes 才非空。撤掉 stop 的 await（改回
      // fire-and-forget）会让本断言转红——锁住退出时统计不丢。
      final _Sink sink = _Sink(delay: const Duration(milliseconds: 20));
      final _FakeSource src = _FakeSource()..isPlaying = true;
      // 段时长走注入时钟，不靠墙钟：落库门槛是「≥1 秒或有内容账」，等 30ms 真实
      // 时间造出来的段过不了门槛，测的就成了墙钟而不是接线。
      DateTime now = DateTime(2026, 1, 1, 12);
      final VideoWatchTracker tracker = VideoWatchTracker(
        bookUid: 'u1',
        clock: _clock(sink, now: () => now),
        markCompleted: (_) async {},
      )..attach(src);

      tracker.start();
      // 制造一段连续播放窗口（>0 且 <= kMaxReadingGap）。
      now = now.add(const Duration(seconds: 30));
      await tracker.stop();

      expect(sink.writes, isNotEmpty,
          reason: 'stop() 必须 await 异步统计写——否则 exit(0) 丢观看时长');
      expect(sink.writes.first.durationMs.value, greaterThan(0));
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
        bookUid: 'u1',
        clock: _clock(_Sink()),
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

  group('观看时长接线（v92：经 StudyClock 落段，取代 recordActivity 活动行）', () {
    test('一次观看 session 结束落一条段，携带净观看时长', () async {
      final _Sink sink = _Sink();
      final _FakeSource src = _FakeSource()..isPlaying = true;
      DateTime now = DateTime(2026, 1, 1, 12);
      final VideoWatchTracker tracker = VideoWatchTracker(
        bookUid: 'u1',
        clock: _clock(sink, now: () => now),
        markCompleted: (_) async {},
      )..attach(src);

      tracker.start();
      now = now.add(const Duration(seconds: 30));
      await tracker.stop();

      expect(sink.writes, hasLength(1));
      expect(sink.writes.single.mediaKind.value, kActivityMediaVideo);
      expect(sink.writes.single.mediaKey.value, 'u1');
      expect(sink.writes.single.title.value, 'A');
      expect(sink.writes.single.durationMs.value, greaterThan(0)); // 净观看时长
    });

    test('二次 stop 幂等：不重复写段（时钟已封段、无累计器可再结算）', () async {
      final _Sink sink = _Sink();
      final _FakeSource src = _FakeSource()..isPlaying = true;
      DateTime now = DateTime(2026, 1, 1, 12);
      final VideoWatchTracker tracker = VideoWatchTracker(
        bookUid: 'u1',
        clock: _clock(sink, now: () => now),
        markCompleted: (_) async {},
      )..attach(src);

      tracker.start();
      now = now.add(const Duration(seconds: 30));
      await tracker.stop();
      await tracker.stop(); // 第二次不应再写（段已封、时钟已停）
      expect(sink.writes, hasLength(1));
    });

    test('从未播放（isPlaying=false，无净时长）不落段', () async {
      final _Sink sink = _Sink();
      final _FakeSource src = _FakeSource()..isPlaying = false;
      // 同样推过 1 秒门槛：不推的话「没到门槛」也会让断言绿，这条就分不清是
      // 活跃态守卫在起作用还是段太短，等于没测。
      DateTime now = DateTime(2026, 1, 1, 12);
      final VideoWatchTracker tracker = VideoWatchTracker(
        bookUid: 'u1',
        clock: _clock(sink, now: () => now),
        markCompleted: (_) async {},
      )..attach(src);

      tracker.start();
      now = now.add(const Duration(seconds: 30));
      await tracker.stop();
      expect(sink.writes, isEmpty,
          reason: '活跃态守卫（isPlaying）拒绝的窗口整窗丢弃，不开段不写');
    });
  });
}
