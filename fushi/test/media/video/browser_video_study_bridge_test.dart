// 浏览器扩展网页视频沉浸时间 → 学习统计（`BrowserVideoStudyBridge`）。
//
// 桥把扩展 `POST /api/extension/study` 的样本喂给 VideoWatchTracker + StudyClock
// （墙钟计时，2026-11-07 取代「只计首次覆盖」），与本地 / 网页档视频页同一装配。本测
// 用真内存 DB 钉「样本进来 → study_segments 里出现什么」：
//  * 会话存活期间按墙钟累计成一段 media_kind='video' / media_key='web:...' 的时长；
//  * 换 mediaKey 封上一段、开新段（同一时刻只有一条在计时）；ended 停表，之后再来
//    样本开新 tracker；
//  * 重看同一区间照计时长（覆盖并集按 videoWatchCoveragePrefKey 持久化，只管字幕字数）；
//  * 空闲超时没有新样本即停表落库。
// 墙钟经 StudyClock(now:) + tracker.debugNowForTesting 全注入，不靠真实流逝。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/browser_video_study_bridge.dart';
import 'package:fushi/src/media/video/video_study_accrual_arbiter.dart';
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
  BrowserVideoCue? cue,
}) => BrowserVideoSample(
  mediaKey: mediaKey,
  title: title,
  positionMs: positionMs,
  durationMs: durationMs,
  playing: playing,
  speed: speed,
  ended: ended,
  cue: cue,
);

int _totalChars(List<StudySegmentRow> rows, String key) => rows
    .where((StudySegmentRow r) => r.mediaKey == key)
    .fold<int>(0, (int a, StudySegmentRow r) => a + r.chars);

/// 一条 0–10s 每 2s 一句的整集轨：页面在 [posMs] 这一刻出的那一句。
BrowserVideoCue? _cueAt(int posMs) {
  const List<String> lines = <String>['こんにちは', '元気ですか', 'ありがとう'];
  final int i = posMs ~/ 2000;
  if (i >= lines.length) return null;
  return BrowserVideoCue(
    index: i,
    startMs: i * 2000,
    endMs: i * 2000 + 2000,
    text: lines[i],
  );
}

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

  static _Rig create({
    Duration idleTimeout = const Duration(seconds: 20),
    VideoStudyAccrualArbiter? arbiter,
  }) {
    _fakeNow = DateTime(2026, 1, 1, 12);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final BrowserVideoStudyBridge bridge = BrowserVideoStudyBridge(
      database: () => db,
      now: () => _fakeNow,
      idleTimeout: idleTimeout,
      // 每个用例独立仲裁，不和进程级实例串味。
      arbiter: arbiter ?? VideoStudyAccrualArbiter(),
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
      bridge.onSample(
        _sample(
          mediaKey: mediaKey,
          title: title,
          positionMs: fromMs + i * 1000,
        ),
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BrowserVideoSample.tryParse 契约', () {
    final BrowserVideoSample? ok = BrowserVideoSample.tryParse(
      <String, dynamic>{
        'mediaKind': 'video',
        'mediaKey': 'web:x',
        'title': 'T',
        'positionMs': 1000,
        'durationMs': 5000.0, // JSON 里带 .0 的整数值也认
        'playing': true,
        'speed': 2,
        'ended': true,
      },
    );
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
      rows.every((StudySegmentRow r) => r.mediaKey == 'web:yt-abc'),
      isTrue,
    );
    expect(rows.first.title, 'Video A');
    expect(_totalMs(rows, 'web:yt-abc'), 5000);
    // 覆盖并集已按视频身份持久化。
    expect(
      await rig.db.getPref(videoWatchCoveragePrefKey('web:yt-abc')),
      isNotNull,
    );
  });

  test('与 app 内视频同时在播：app 持焦时浏览器不入账，app 关掉后恢复（跨面去重）', () async {
    final VideoStudyAccrualArbiter arbiter = VideoStudyAccrualArbiter();
    final VideoStudyAccrualClaim inApp = arbiter.claim(
      surface: VideoStudySurface.inApp,
      settle: () {},
    );
    inApp.update(running: true, foreground: true);
    final _Rig rig = _Rig.create(arbiter: arbiter);
    await rig.open(_sample(positionMs: 0));
    rig.play(fromMs: 0, seconds: 5);
    // app 内视频页关掉：浏览器翻回入账，翻转前按旧结论（不入账）结算掉前 5 秒。
    inApp.release();
    rig.play(fromMs: 5000, seconds: 3);
    await rig.bridge.stopAll();

    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 3000);
  });

  test('RemoteVideoPlaybackSource 播放中按经过墙钟 × 倍速外推位置、暂停不外推、封顶片长', () {
    _fakeNow = DateTime(2026, 1, 1, 12);
    final RemoteVideoPlaybackSource source = RemoteVideoPlaybackSource(
      now: () => _fakeNow,
    );
    source.apply(_sample(positionMs: 1000, speed: 2.0, durationMs: 2500));
    _fakeNow = _fakeNow.add(const Duration(milliseconds: 700));
    expect(source.positionMs, 2400, reason: '1000 + 700 × 2.0');
    _fakeNow = _fakeNow.add(const Duration(milliseconds: 700));
    expect(source.positionMs, 2500, reason: '封顶片长');
    source.apply(_sample(positionMs: 1000, playing: false));
    _fakeNow = _fakeNow.add(const Duration(seconds: 3));
    expect(source.positionMs, 1000, reason: '暂停不外推');
  });

  test('tracker 定时 tick 与扩展样本相位交错时仍按整段墙钟记账', () async {
    // 扩展每 1s 一条样本、tracker 每 1s 一次定时采样，两者相位随机。若播放源只给
    // 静态快照，tick 那一刻位置没变 → 该窗不记，但墙钟基准被挪到 tick 时刻，之后
    // 每窗只剩「tick → 样本」那截被记，期望只记到四成。这里固定相位 0.7s 复现。
    final _Rig rig = _Rig.create();
    await rig.open(_sample(positionMs: 0));
    for (int i = 1; i <= 10; i++) {
      _fakeNow = _fakeNow.add(const Duration(milliseconds: 700));
      rig.trackers.last.debugSampleNow();
      _fakeNow = _fakeNow.add(const Duration(milliseconds: 300));
      rig.bridge.onSample(_sample(positionMs: i * 1000));
    }
    await rig.bridge.stopAll();
    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 10000);
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

  test('ended 停表；之后再来样本开新 tracker，重看同区间照计时长', () async {
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
    // 重看 [0, 4000) + 新内容 [4000, 6000)：时长按实际 6s 计（覆盖只管字幕字数）；
    // ended 到重开之间的 5 分钟不在任何会话里，不计。
    rig.play(fromMs: 0, seconds: 6);
    await rig.bridge.stopAll();
    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 10000);
  });

  test('会话存活期间的暂停照计（查词也是学习时间）；seek 跳变不进覆盖', () async {
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
    expect(_totalMs(await _segments(rig.db), 'web:yt-abc'), 15000);
    expect(
      rig.trackers.single.debugCoverage.ranges.any(
        ((int, int) r) => r.$1 < 60000 && r.$2 > 2000,
      ),
      isFalse,
      reason: '跳过的 2000..60000 不算看过',
    );
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

  // 反馈 jk4rTLHPZ_：内置浏览器里看 YouTube，Fushi 在出字幕、时长照计，chars 恒 0——
  // 样本契约里没有当前句，播放源的 cue 恒空。
  test('样本带当前句：字幕字数按停留门计进同一段，与视频页同口径', () async {
    final _Rig rig = _Rig.create();
    await rig.open(_sample(positionMs: 0, cue: _cueAt(0)));
    for (int i = 1; i <= 6; i++) {
      _fakeNow = _fakeNow.add(const Duration(seconds: 1));
      rig.bridge.onSample(_sample(positionMs: i * 1000, cue: _cueAt(i * 1000)));
    }
    await rig.bridge.stopAll();
    final List<StudySegmentRow> rows = await _segments(rig.db);
    expect(_totalMs(rows, 'web:yt-abc'), 6000);
    // 三句各播满 2s：5 + 5 + 5 字。
    expect(_totalChars(rows, 'web:yt-abc'), 15);
  });

  test('拖进度条掠过的句不计字；没有当前句的样本不计字', () async {
    final _Rig rig = _Rig.create();
    await rig.open(_sample(positionMs: 0));
    rig.play(fromMs: 0, seconds: 3);
    // 拖到第二句中间又立刻拖走：墙钟没走，停留量为 0。
    rig.bridge.onSample(_sample(positionMs: 2500, cue: _cueAt(2500)));
    rig.bridge.onSample(_sample(positionMs: 9000));
    await rig.bridge.stopAll();
    expect(_totalChars(await _segments(rig.db), 'web:yt-abc'), 0);
  });

  test('BrowserVideoSample.tryParse：cue 契约', () {
    Map<String, dynamic> body(Object? cue) => <String, dynamic>{
      'mediaKind': 'video',
      'mediaKey': 'web:yt-x',
      'positionMs': 1200,
      'playing': true,
      'cue': cue,
    };
    final BrowserVideoSample? ok = BrowserVideoSample.tryParse(
      body(<String, dynamic>{
        'index': 3,
        'startMs': 1000,
        'endMs': 2500.0,
        'text': 'こんにちは',
      }),
    );
    expect(ok?.cue?.index, 3);
    expect(ok?.cue?.endMs, 2500);
    expect(ok?.cue?.toAudioCue().text, 'こんにちは');
    expect(BrowserVideoSample.tryParse(body(null))?.cue, isNull);
    // 坏 cue：整条丢弃（与其它字段同一契约）。
    for (final Object bad in <Object>[
      'x',
      <String, dynamic>{'index': 0, 'startMs': 10, 'endMs': 5, 'text': 'a'},
      <String, dynamic>{'index': -1, 'startMs': 0, 'endMs': 5, 'text': 'a'},
      <String, dynamic>{'index': 0, 'startMs': 0, 'endMs': 5},
      <String, dynamic>{
        'index': 0,
        'startMs': 0,
        'endMs': 5,
        'text': 'あ' * (BrowserVideoCue.maxTextLength + 1),
      },
    ]) {
      expect(BrowserVideoSample.tryParse(body(bad)), isNull, reason: '$bad');
    }
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
