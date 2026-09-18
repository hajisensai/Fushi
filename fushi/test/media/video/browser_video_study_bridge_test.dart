// 浏览器扩展网页视频沉浸时间 → 学习统计（`BrowserVideoStudyBridge`）。
//
// 桥把扩展 `POST /api/extension/study` 的样本喂给 VideoWatchTracker + StudyClock
// （StudyAccrual.explicit、只计首次覆盖），与本地 / 网页档视频页同一装配。本测用真
// 内存 DB 钉「样本进来 → study_segments 里出现什么」：
//  * 连续播放样本累计成一段 media_kind='video' / media_key='web:...' 的时长；
//  * 换 mediaKey 封上一段、开新段；ended 停表，之后再来样本开新 tracker；
//  * 重看同一区间不再计（覆盖并集按 videoWatchCoveragePrefKey 持久化）；
//  * 空闲超时没有新样本即停表落库。
// 墙钟经 StudyClock(now:) + tracker.debugNowForTesting 全注入，不靠真实流逝。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/browser_video_study_bridge.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi_core/fushi_core.dart';

DateTime _fakeNow = DateTime(2026, 1, 1, 12);

BrowserVideoSample _sample({
  String mediaKey = 'web:yt-abc',
  String title = 'Video A',
  required int positionMs,
  int? durationMs = 600000,
  bool playing = true,
  double speed = 1.0,
  bool ended = false,
}) =>
    BrowserVideoSample(
      mediaKey: mediaKey,
      title: title,
      positionMs: positionMs,
      durationMs: durationMs,
      playing: playing,
      speed: speed,
      ended: ended,
    );

Future<List<StudySegmentRow>> _segments(FushiDatabase db) async =>
    (await db.select(db.studySegments).get())
        .where((StudySegmentRow r) => r.mediaKind == kActivityMediaVideo)
        .toList();

int _totalMs(List<StudySegmentRow> rows, String key) => rows
    .where((StudySegmentRow r) => r.mediaKey == key)
    .fold<int>(0, (int a, StudySegmentRow r) => a + r.durationMs);

class _Rig {
  _Rig(this.db, this.bridge);

  final FushiDatabase db;
  final BrowserVideoStudyBridge bridge;
  final List<VideoWatchTracker> trackers = <VideoWatchTracker>[];

  static _Rig create({Duration idleTimeout = const Duration(seconds: 20)}) {
    _fakeNow = DateTime(2026, 1, 1, 12);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final BrowserVideoStudyBridge bridge = BrowserVideoStudyBridge(
      database: () => db,
      now: () => _fakeNow,
      idleTimeout: idleTimeout,
    );
    final _Rig rig = _Rig(db, bridge);
    bridge.debugOnTrackerCreated = (VideoWatchTracker t) {
      t.debugNowForTesting = () => _fakeNow;
      rig.trackers.add(t);
    };
    addTearDown(bridge.stopAll);
    return rig;
  }

  /// 首条样本开 tracker；等它把覆盖并集从偏好表读完（读完前的采样不计）。
  Future<void> open(BrowserVideoSample first) async {
    bridge.onSample(first);
    await trackers.last.debugCoverageLoaded;
    // 覆盖就绪后再采一次，作为后续窗口的起点。
    bridge.onSample(first);
  }

  /// 连续播放：每秒一条样本，位置 +1000、墙钟 +1000。
  void play({
    required int fromMs,
    required int seconds,
    String mediaKey = 'web:yt-abc',
    String title = 'Video A',
  }) {
    for (int i = 1; i <= seconds; i++) {
      _fakeNow = _fakeNow.add(const Duration(seconds: 1));
      bridge.onSample(_sample(
        mediaKey: mediaKey,
        title: title,
        positionMs: fromMs + i * 1000,
      ));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BrowserVideoSample.tryParse 契约', () {
    final BrowserVideoSample? ok =
        BrowserVideoSample.tryParse(<String, dynamic>{
      'mediaKind': 'video',
      'mediaKey': 'web:x',
      'title': 'T',
      'positionMs': 1000,
      'durationMs': 5000.0, // JSON 里带 .0 的整数值也认
      'playing': true,
      'speed': 2,
      'ended': true,
    });
    expect(ok, isNotNull);
    expect(ok!.durationMs, 5000);
    expect(ok.speed, 2.0);
    expect(ok.ended, isTrue);
    expect(
      BrowserVideoSample.tryParse(<String, dynamic>{
        'mediaKind': 'video',
        'mediaKey': 'web:x',
        'positionMs': 0,
        'playing': false,
      })?.displayTitle,
      'web:x',
    );
    expect(
      BrowserVideoSample.tryParse(<String, dynamic>{
        'mediaKind': 'video',
        'mediaKey': 'web:x',
        'positionMs': 1.5,
        'playing': false,
      }),
      isNull,
    );
    expect(
      BrowserVideoSample.tryParse(<String, dynamic>{
        'mediaKind': 'manga',
        'mediaKey': 'web:x',
        'positionMs': 0,
        'playing': false,
      }),
      isNull,
    );
  });

  test('连续播放样本 → study_segments 出现 video / web: 段且时长累计', () async {
    final _Rig rig = _Rig.create();
    await rig.open(_sample(positionMs: 0));
    rig.play(fromMs: 0, seconds: 5);
    await rig.bridge.stopAll();

    final List<StudySegmentRow> rows = await _segments(rig.db);
    expect(rows, isNotEmpty);
    expect(
        rows.every((StudySegmentRow r) => r.mediaKey == 'web:yt-abc'), isTrue);
    expect(rows.first.title, 'Video A');
    expect(_totalMs(rows, 'web:yt-abc'), 5000);
    // 覆盖并集已按视频身份持久化。
    expect(await rig.db.getPref(videoWatchCoveragePrefKey('web:yt-abc')),
        isNotNull);
  });

  test('换 mediaKey 封上一段、开新段；两段各记各的', () async {
    final _Rig rig = _Rig.create();
    await rig.open(_sample(positionMs: 0));
    rig.play(fromMs: 0, seconds: 3);
    expect(rig.bridge.debugActiveMediaKey, 'web:yt-abc');

    // 换视频：首条样本换 key。
    await rig.open(_sample(mediaKey: 'web:yt-def', title: 'B', positionMs: 0));
    expect(rig.bridge.debugActiveMediaKey, 'web:yt-def');
    expect(rig.trackers, hasLength(2));
    rig.play(fromMs: 0, seconds: 4, mediaKey: 'web:yt-def', title: 'B');
    await rig.bridge.stopAll();

    final List<StudySegmentRow> rows = await _segments(rig.db);
    expect(_totalMs(rows, 'web:yt-abc'), 3000);
    expect(_totalMs(rows, 'web:yt-def'), 4000);
    expect(
      rows.firstWhere((StudySegmentRow r) => r.mediaKey == 'web:yt-def').title,
      'B',
    );
  });

  test('ended 停表；之后再来样本开新 tracker，重看同区间不再计', () async {
    final _Rig rig = _Rig.create();
    await rig.open(_sample(positionMs: 0));
    rig.play(fromMs: 0, seconds: 4);
    rig.bridge.onSample(_sample(positionMs: 4000, ended: true));
    expect(rig.bridge.debugActiveMediaKey, isNull);
    await rig.bridge.stopAll();
    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 4000);

    // 页面重开：新 tracker，从偏好表读回覆盖并集。
    _fakeNow = _fakeNow.add(const Duration(minutes: 5));
    await rig.open(_sample(positionMs: 0));
    expect(rig.trackers, hasLength(2));
    // 重看 [0, 4000)：已覆盖，不计；再往前看 [4000, 6000) 是新内容，计 2s。
    rig.play(fromMs: 0, seconds: 6);
    await rig.bridge.stopAll();
    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 6000);
  });

  test('暂停样本之间不计；seek 跳变不计', () async {
    final _Rig rig = _Rig.create();
    await rig.open(_sample(positionMs: 0));
    rig.play(fromMs: 0, seconds: 2);
    // 暂停 10s：位置不动、playing=false。
    _fakeNow = _fakeNow.add(const Duration(seconds: 10));
    rig.bridge.onSample(_sample(positionMs: 2000, playing: false));
    // 拖到 60s：墙钟没走、位置猛进 → 跳变不计。
    rig.bridge.onSample(_sample(positionMs: 60000));
    rig.play(fromMs: 60000, seconds: 3);
    await rig.bridge.stopAll();
    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 5000);
  });

  test('空闲超时没有新样本 → 停表落库、释放', () async {
    final _Rig rig = _Rig.create(idleTimeout: const Duration(milliseconds: 40));
    await rig.open(_sample(positionMs: 0));
    rig.play(fromMs: 0, seconds: 3);
    expect(rig.bridge.debugActiveMediaKey, 'web:yt-abc');
    // 空闲 Timer 是真定时器（生产里就是它兜「页面被关没发 ended」）；40ms 到点即停。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(rig.bridge.debugActiveMediaKey, isNull);
    await rig.bridge.stopAll();
    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 3000);
  });

  test('没开过的 ended 不建段', () async {
    final _Rig rig = _Rig.create();
    rig.bridge.onSample(_sample(positionMs: 0, ended: true));
    expect(rig.bridge.debugActiveMediaKey, isNull);
    expect(rig.trackers, isEmpty);
    await rig.bridge.stopAll();
    expect(await _segments(rig.db), isEmpty);
  });
}
