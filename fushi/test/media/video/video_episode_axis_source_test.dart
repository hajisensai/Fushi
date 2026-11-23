// BUG-5340：原盘菜单「全部播放」播的是被扫描切成集的整条播放列表，库身份随播放头
// 在各集之间换。观看采集器（完成判定 / 覆盖并集 / 字幕停留）必须看这一集自己的时间轴：
// 直接读播放器时间时，第 1、2 集永远到不了「整条的 90%」、末集刚过一大半就报看完，
// 覆盖并集按集键存的却是整条播放列表的时间。
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_episode_axis_source.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

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
  @override
  double speed = 1.0;
  @override
  int subtitleDelayMs = 0;
  void emit() => notifyListeners();
}

AudioCue _cue(String text, int startMs, int endMs) => AudioCue()
  ..text = text
  ..startMs = startMs
  ..endMs = endMs;

/// 与 `bluray_menu_title_binding_test` 同一张盘：两集 1442 秒 + 1422 秒。
const int _ep1Start = 0;
const int _ep1Length = 1442000;
const int _ep2Start = 1442000;
const int _ep2Length = 1422000;
const int _playlistLength = _ep1Length + _ep2Length;

DateTime _now = DateTime(2026, 1, 1, 12);

StudyClock _clock() {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  int seq = 0;
  return StudyClock(
    database: db,
    mediaKind: kActivityMediaVideo,
    mediaKey: 'ep',
    title: 'BOCCHI',
    sink: (StudySegmentsCompanion _) async {},
    deviceId: () async => 'dev',
    now: () => _now,
    uidFactory: () => 'seg${++seq}',
  );
}

typedef _EpisodeTracker = ({
  VideoWatchTracker tracker,
  List<int> completed,
  List<String> saved,
});

/// 一个按 [startMs] / [lengthMs] 看这一集的采集器（与播放页 `_ensureWatchTracker`
/// 的接法相同），完成回调计数进 [completed]。
_EpisodeTracker _episodeTracker(
  _FakeSource src, {
  required int startMs,
  required int lengthMs,
}) {
  final List<int> completed = <int>[];
  final List<String> saved = <String>[];
  final VideoWatchTracker tracker =
      VideoWatchTracker(
          bookUid: 'ep@$startMs',
          clock: _clock(),
          onEpisodeCompleted: () => completed.add(startMs),
          loadCoverage: () async => null,
          saveCoverage: (String json) async => saved.add(json),
        )
        ..debugNowForTesting = (() => _now)
        ..attach(
          EpisodeAxisPlaybackSource(src, startMs: startMs, lengthMs: lengthMs),
        );
  return (tracker: tracker, completed: completed, saved: saved);
}

void main() {
  setUp(() => _now = DateTime(2026, 1, 1, 12));

  group('EpisodeAxisPlaybackSource', () {
    test('位置 / 时长换到这一集的时间轴，越界夹在集长内', () {
      final _FakeSource src = _FakeSource()
        ..durationMs = _playlistLength
        ..positionMs = _ep2Start + 11000;
      final EpisodeAxisPlaybackSource ep2 = EpisodeAxisPlaybackSource(
        src,
        startMs: _ep2Start,
        lengthMs: _ep2Length,
      );
      expect(ep2.positionMs, 11000);
      expect(ep2.durationMs, _ep2Length);
      src.positionMs = _ep2Start - 5000; // 播放头还在上一集
      expect(ep2.positionMs, 0);
      src.positionMs = _playlistLength + 9000; // 片尾空白
      expect(ep2.positionMs, _ep2Length);
      src.positionMs = null;
      expect(ep2.positionMs, isNull);
    });

    test('当前句平移到这一集的时间轴；同一句只平移一次，调轴与播放态照传', () {
      final AudioCue cue = _cue('ぼっち', _ep2Start + 20000, _ep2Start + 23000);
      final _FakeSource src = _FakeSource()
        ..currentCue = cue
        ..currentCueIndex = 7
        ..subtitleDelayMs = 300
        ..isPlaying = true
        ..speed = 1.5;
      final EpisodeAxisPlaybackSource ep2 = EpisodeAxisPlaybackSource(
        src,
        startMs: _ep2Start,
        lengthMs: _ep2Length,
      );
      final AudioCue shifted = ep2.currentCue!;
      expect(
        (shifted.startMs, shifted.endMs, shifted.text),
        (20000, 23000, 'ぼっち'),
      );
      expect(identical(ep2.currentCue, shifted), isTrue);
      expect(cue.startMs, _ep2Start + 20000, reason: '原句不被改写');
      expect(ep2.currentCueIndex, 7);
      expect(ep2.subtitleDelayMs, 300);
      expect(ep2.isPlaying, isTrue);
      expect(ep2.speed, 1.5);
      src.currentCue = null;
      expect(ep2.currentCue, isNull);
    });

    test('监听直接挂在底层播放源上', () {
      final _FakeSource src = _FakeSource();
      final EpisodeAxisPlaybackSource view = EpisodeAxisPlaybackSource(
        src,
        startMs: 0,
        lengthMs: 1000,
      );
      int calls = 0;
      void listener() => calls++;
      view.addListener(listener);
      src.emit();
      view.removeListener(listener);
      src.emit();
      expect(calls, 1);
    });
  });

  group('各集看完判定按集长（BUG-5340）', () {
    test('第 1 集播到集长 90% 就报看完（整条播放列表才 45%）', () async {
      final _FakeSource src = _FakeSource()
        ..durationMs = _playlistLength
        ..isPlaying = true
        ..positionMs = 1300000;
      expect(1300000 / _playlistLength, lessThan(0.9));
      final _EpisodeTracker s = _episodeTracker(
        src,
        startMs: _ep1Start,
        lengthMs: _ep1Length,
      );
      s.tracker.start();
      await s.tracker.stop();
      expect(s.completed, <int>[_ep1Start]);
    });

    test('末集过了整条的 90% 但只到集长 81%：不报看完', () async {
      final _FakeSource src = _FakeSource()
        ..durationMs = _playlistLength
        ..isPlaying = true
        ..positionMs = 2600000;
      expect(2600000 / _playlistLength, greaterThan(0.9));
      final _EpisodeTracker s = _episodeTracker(
        src,
        startMs: _ep2Start,
        lengthMs: _ep2Length,
      );
      s.tracker.start();
      await s.tracker.stop();
      expect(s.completed, isEmpty);
    });

    test('播放头已跨进下一集时旧采集器离开：按旧集区间结算 = 看完', () async {
      final _FakeSource src = _FakeSource()
        ..durationMs = _playlistLength
        ..isPlaying = false
        ..positionMs = 1000000;
      final _EpisodeTracker s = _episodeTracker(
        src,
        startMs: _ep1Start,
        lengthMs: _ep1Length,
      );
      s.tracker.start();
      // 宿主在跨集那一刻（播放头已在第 2 集第 3 秒）封旧采集器。
      src.positionMs = _ep2Start + 3000;
      await s.tracker.close();
      expect(s.completed, <int>[_ep1Start]);
    });
  });

  test('覆盖并集按集的时间轴存（与直接打开这一集同轴）', () async {
    final _FakeSource src = _FakeSource()
      ..durationMs = _playlistLength
      ..isPlaying = true
      ..positionMs = _ep2Start + 10000;
    final _EpisodeTracker s = _episodeTracker(
      src,
      startMs: _ep2Start,
      lengthMs: _ep2Length,
    );
    await s.tracker.debugCoverageLoaded;
    s.tracker.start();
    for (int pos = _ep2Start + 11000; pos <= _ep2Start + 20000; pos += 1000) {
      _now = _now.add(const Duration(seconds: 1));
      src.positionMs = pos;
      src.emit();
    }
    await s.tracker.stop();
    expect(s.tracker.debugCoverage.ranges, <(int, int)>[(10000, 20000)]);
    expect(s.saved.last, '[[10000,20000]]');
  });
}
