import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart'
    show MusicServerLocalCopy;
import 'package:fushi/src/media/music/server/music_server_playback_reporter.dart';
import 'package:fushi/src/media/music/server/music_server_track_ref.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';

/// 引擎只读那几项状态（播放上报只读不写）。
class _FakeEngine extends Fake implements MusicPlayerEngine {
  MusicPlayItem? started;
  bool playing = true;
  Duration pos = Duration.zero;
  Duration? dur;
  Duration? before;

  @override
  MusicPlayItem? get startedItem => started;
  @override
  bool get isPlaying => playing;
  @override
  Duration get position => pos;
  @override
  Duration? get duration => dur;
  @override
  Duration? get listenedBeforeStart => before;
}

/// 能补记播放的服务器（Jellyfin：开播即计次 / Subsonic：停止时计次）。
class _MarkingServer extends _FakeServer implements MusicServerPlayMarking {
  _MarkingServer(super.serverId, {required this.countsPlayOnStart});

  @override
  final bool countsPlayOnStart;

  @override
  Future<void> markPlayed(String trackId, DateTime playedAt) async =>
      calls.add('mark $trackId');
}

/// 一台记录上报的服务器（流地址形如 `http://srv/<id>`）。
class _FakeServer extends Fake
    implements MusicServerBrowser, MusicServerPlaybackReporting {
  _FakeServer(this.serverId);

  @override
  final String serverId;
  @override
  MusicServerKind get kind => MusicServerKind.jellyfin;
  final List<String> calls = <String>[];
  bool failStart = false;
  Exception? startError;

  @override
  MusicServerStreamRef? streamRefOf(Uri uri) => uri.host == 'srv'
      ? MusicServerStreamRef(
          trackId: uri.pathSegments.last,
          transcoded: uri.queryParameters['t'] == '1',
        )
      : null;

  @override
  Future<void> reportPlaybackStarted(MusicServerPlaybackReport r) async {
    calls.add('start ${r.trackId} ${r.positionMs} ${r.playSessionId}');
    if (failStart) throw startError ?? Exception('401');
  }

  @override
  Future<void> reportPlaybackProgress(
    MusicServerPlaybackReport r, {
    MusicServerPlaybackEvent? event,
  }) async =>
      calls.add('progress ${r.trackId} ${r.positionMs} ${event?.name ?? '-'}');

  @override
  Future<void> reportPlaybackStopped(MusicServerPlaybackReport r) async =>
      calls.add('stop ${r.trackId} ${r.positionMs}');
}

MusicPlayItem _item(String serverId, String id, {int? durationMs}) =>
    MusicPlayItem(
      trackUid: musicServerTrackUid(serverId, id),
      path: 'http://srv/$id',
      title: id,
      durationMs: durationMs,
    );

void main() {
  late _FakeEngine engine;
  late _FakeServer server;
  late DateTime now;
  late int lookups;
  late int failures;
  late List<Object> errors;
  late MusicServerPlaybackReporter reporter;

  /// 离线副本索引（uid → 副本）。
  late Map<String, MusicServerLocalCopy> copies;

  setUp(() {
    engine = _FakeEngine();
    server = _FakeServer('jf1');
    now = DateTime(2026, 11, 22, 12);
    lookups = 0;
    failures = 0;
    errors = <Object>[];
    copies = <String, MusicServerLocalCopy>{};
    final MusicServerTrackResolver resolver = MusicServerTrackResolver(
      () async {
        lookups++;
        return <MusicServerBrowser>[server];
      },
      localCopies: (String uid) => copies[uid],
    );
    int session = 0;
    reporter = MusicServerPlaybackReporter(
      engine: engine,
      lookup: resolver.resolveItem,
      onTargetFailure: () => failures++,
      onError: (Object e, StackTrace _) => errors.add(e),
      now: () => now,
      sessionIds: () => 'sess${session++}',
    );
  });

  void start(MusicPlayItem item) {
    engine.started = item;
    engine.pos = Duration.zero;
    reporter.trackStarted(item);
  }

  void tick(Duration pos, {Duration advance = const Duration(seconds: 1)}) {
    now = now.add(advance);
    engine.pos = pos;
    reporter.engineChanged();
  }

  test('开播 → 节流进度 → 暂停 / 继续 → 换下报停止', () async {
    final MusicPlayItem a = _item('jf1', 'a', durationMs: 300000);
    start(a);
    await reporter.idle;
    expect(server.calls, <String>['start a 0 sess0']);
    // 10 秒内的位置推送不报；到 10 秒报一次。
    tick(const Duration(seconds: 1));
    tick(const Duration(seconds: 5), advance: const Duration(seconds: 4));
    await reporter.idle;
    expect(server.calls.length, 1);
    tick(const Duration(seconds: 12), advance: const Duration(seconds: 7));
    await reporter.idle;
    expect(server.calls.last, 'progress a 12000 -');
    // 暂停 / 继续各报一次，暂停期间不报心跳。
    engine.playing = false;
    tick(const Duration(seconds: 13));
    tick(const Duration(seconds: 13), advance: const Duration(seconds: 30));
    await reporter.idle;
    expect(server.calls.last, 'progress a 13000 pause');
    final int count = server.calls.length;
    engine.playing = true;
    tick(const Duration(seconds: 13));
    await reporter.idle;
    expect(server.calls.length, count + 1);
    expect(server.calls.last, 'progress a 13000 unpause');
    reporter.trackLeft(
      MusicTrackLeave(
        item: a,
        position: const Duration(seconds: 20),
        duration: const Duration(minutes: 5),
        restoring: false,
      ),
    );
    await reporter.idle;
    expect(server.calls.last, 'stop a 20000');
  });

  test('自然推进（听完）按曲长报停止；下一首新会话', () async {
    final MusicPlayItem a = _item('jf1', 'a');
    final MusicPlayItem b = _item('jf1', 'b');
    start(a);
    reporter.trackLeft(
      MusicTrackLeave(
        item: a,
        position: const Duration(seconds: 288),
        duration: const Duration(seconds: 300),
        restoring: false,
        completed: true,
      ),
    );
    start(b);
    await reporter.idle;
    expect(server.calls, <String>[
      'start a 0 sess0',
      'stop a 300000',
      'start b 0 sess1',
    ]);
    expect(lookups, 1, reason: '服务器列表缓存复用');
  });

  test('单曲循环同一首重播也算新一次播放', () async {
    final MusicPlayItem a = _item('jf1', 'a');
    start(a);
    reporter.trackLeft(
      MusicTrackLeave(
        item: a,
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 30),
        restoring: false,
        completed: true,
      ),
    );
    start(a);
    await reporter.idle;
    expect(server.calls.where((String c) => c.startsWith('start')).length, 2);
  });

  test('非服务器曲目什么都不发、不读服务器配置', () async {
    start(
      const MusicPlayItem(trackUid: 'local1', path: 'C:/m/a.flac', title: 'a'),
    );
    start(
      MusicPlayItem(
        trackUid: musicServerTrackUid('youtube', 'v'),
        path: 'fushi-music-youtube://v',
        title: 'v',
      ),
    );
    tick(const Duration(seconds: 30), advance: const Duration(seconds: 30));
    await reporter.idle;
    expect(server.calls, isEmpty);
    expect(lookups, 0);
  });

  test('别的服务器的同形地址（uid 对不上）不认', () async {
    start(_item('other', 'a'));
    await reporter.idle;
    expect(server.calls, isEmpty);
  });

  test('开播上报失败：记一次错、之后不再发、让解析器重读配置', () async {
    server.failStart = true;
    final MusicPlayItem a = _item('jf1', 'a');
    start(a);
    tick(const Duration(seconds: 15), advance: const Duration(seconds: 15));
    tick(const Duration(seconds: 30), advance: const Duration(seconds: 15));
    reporter.trackLeft(
      MusicTrackLeave(
        item: a,
        position: const Duration(seconds: 30),
        duration: null,
        restoring: false,
      ),
    );
    await reporter.idle;
    expect(server.calls, <String>['start a 0 sess0']);
    expect(errors.length, 1);
    expect(failures, 1);
  });

  test('退出时 flush 把正在播的报停止', () async {
    start(_item('jf1', 'a'));
    engine.pos = const Duration(seconds: 42);
    await reporter.flush();
    expect(server.calls.last, 'stop a 42000');
  });

  test('musicServerResolveTrack：两台同类服务器靠 uid 区分', () {
    final _FakeServer other = _FakeServer('jf2');
    final MusicServerResolvedTrack? ref = musicServerResolveTrack(
      trackUid: musicServerTrackUid('jf2', 'x'),
      path: 'http://srv/x?t=1',
      browsers: <MusicServerBrowser>[server, other],
      localCopies: (_) => null,
    );
    expect(ref?.browser, same(other));
    expect(ref?.trackId, 'x');
    expect(ref?.ref.serverId, 'jf2');
    expect(ref?.transcoded, isTrue);
  });

  test('播放项自带的服务器身份优先，uid 对不上不认', () {
    const MusicServerTrackRef ref = MusicServerTrackRef(
      kind: MusicServerKind.jellyfin,
      serverId: 'jf1',
      trackId: 'z',
    );
    final MusicServerResolvedTrack? hit = musicServerResolveTrack(
      trackUid: musicServerTrackUid('jf1', 'z'),
      path: 'C:/music/z.flac',
      serverTrack: ref,
      browsers: <MusicServerBrowser>[server],
      localCopies: (_) => null,
    );
    expect(hit?.browser, same(server));
    expect(hit?.ref, ref);
    expect(hit?.transcoded, isFalse);
    expect(
      musicServerResolveTrack(
        trackUid: musicServerTrackUid('jf1', 'other'),
        path: 'C:/music/z.flac',
        serverTrack: ref,
        browsers: <MusicServerBrowser>[server],
        localCopies: (_) => null,
      ),
      isNull,
    );
  });

  MusicPlayItem localCopy(String id) {
    final String uid = musicServerTrackUid('jf1', id);
    copies[uid] = (
      path: 'C:/music/$id.flac',
      coverPath: null,
      codec: 'flac',
      serverId: 'jf1',
      trackId: id,
      serverKind: MusicServerKind.jellyfin,
      loudness: null,
      measuredLoudness: null,
    );
    return MusicPlayItem(trackUid: uid, path: 'C:/music/$id.flac', title: id);
  }

  test('离线副本（本机文件、没带身份）经副本索引认回，照样上报', () async {
    final MusicPlayItem a = localCopy('d');
    start(a);
    engine.pos = const Duration(seconds: 5);
    await reporter.flush();
    expect(server.calls, <String>['start d 0 sess0', 'stop d 5000']);
  });

  test('离线副本服务器连不上：静默跳过（不记错、不重读配置）', () async {
    server.failStart = true;
    server.startError = const SocketException('unreachable');
    start(localCopy('d'));
    await reporter.idle;
    expect(errors, isEmpty);
    expect(failures, 0);
  });

  test('串流时服务器连不上照常记错', () async {
    server.failStart = true;
    server.startError = const SocketException('unreachable');
    start(_item('jf1', 'a'));
    await reporter.idle;
    expect(errors.length, 1);
    expect(failures, 1);
  });

  group('没送达的播放进离线队列', () {
    late List<String> queued;
    late List<MusicServerBrowser> configured;
    late List<String> delivered;

    MusicServerPlaybackReporter build() {
      queued = <String>[];
      delivered = <String>[];
      return MusicServerPlaybackReporter(
        engine: engine,
        lookup: MusicServerTrackResolver(
          () async => configured,
          localCopies: (String uid) => copies[uid],
        ).resolveItem,
        onError: (Object e, StackTrace _) => errors.add(e),
        now: () => now,
        onUndelivered: (MusicServerTrackRef ref, int at) async =>
            queued.add('${ref.kind.wire} ${ref.serverId} ${ref.trackId} $at'),
        onDelivered: (MusicServerBrowser b) => delivered.add(b.serverId),
      );
    }

    MusicPlayItem offlineCopy(String id, {int durationMs = 200000}) {
      final MusicPlayItem base = localCopy(id);
      return MusicPlayItem(
        trackUid: base.trackUid,
        path: base.path,
        title: id,
        durationMs: durationMs,
        serverTrack: MusicServerTrackRef(
          kind: MusicServerKind.jellyfin,
          serverId: 'jf1',
          trackId: id,
        ),
      );
    }

    test('配置删了（认不出服务器）：听够门槛的播放按开播时刻入队', () async {
      configured = <MusicServerBrowser>[];
      final MusicServerPlaybackReporter r = build();
      final MusicPlayItem a = offlineCopy('d');
      engine.started = a;
      r.trackStarted(a);
      r.trackLeft(
        MusicTrackLeave(
          item: a,
          position: const Duration(seconds: 150),
          duration: const Duration(seconds: 200),
          restoring: false,
        ),
      );
      await r.idle;
      expect(queued, <String>[
        'jellyfin jf1 d ${DateTime(2026, 11, 22, 12).millisecondsSinceEpoch}',
      ]);
      expect(errors, isEmpty);
    });

    test('没听够门槛的不入队', () async {
      configured = <MusicServerBrowser>[];
      final MusicServerPlaybackReporter r = build();
      final MusicPlayItem a = offlineCopy('d');
      r.trackStarted(a);
      r.trackLeft(
        MusicTrackLeave(
          item: a,
          position: const Duration(seconds: 20),
          duration: const Duration(seconds: 200),
          restoring: false,
        ),
      );
      await r.idle;
      expect(queued, isEmpty);
    });

    test('Jellyfin 开播已送达（开播即计次）：停止时连不上也不入队', () async {
      final _MarkingServer jf = _MarkingServer('jf1', countsPlayOnStart: true);
      configured = <MusicServerBrowser>[jf];
      final MusicServerPlaybackReporter r = build();
      final MusicPlayItem a = offlineCopy('d');
      r.trackStarted(a);
      await r.idle;
      jf.failStart = false;
      r.trackLeft(
        MusicTrackLeave(
          item: a,
          position: const Duration(seconds: 200),
          duration: const Duration(seconds: 200),
          restoring: false,
          completed: true,
        ),
      );
      await r.idle;
      expect(jf.calls.first, startsWith('start d'));
      expect(queued, isEmpty);
      expect(delivered, <String>['jf1']);
    });

    test('服务器连不上：开播没送达、听完 → 入队、不记错', () async {
      final _MarkingServer jf = _MarkingServer('jf1', countsPlayOnStart: true)
        ..failStart = true
        ..startError = const SocketException('down');
      configured = <MusicServerBrowser>[jf];
      final MusicServerPlaybackReporter r = build();
      final MusicPlayItem a = offlineCopy('d');
      r.trackStarted(a);
      r.trackLeft(
        MusicTrackLeave(
          item: a,
          position: const Duration(seconds: 200),
          duration: const Duration(seconds: 200),
          restoring: false,
          completed: true,
        ),
      );
      await r.idle;
      expect(queued, hasLength(1));
      expect(errors, isEmpty);
      expect(delivered, isEmpty);
    });

    test('服务器回了别的错（不是连不上）：不入队、记错', () async {
      final _MarkingServer jf = _MarkingServer('jf1', countsPlayOnStart: true)
        ..failStart = true;
      configured = <MusicServerBrowser>[jf];
      final MusicServerPlaybackReporter r = build();
      final MusicPlayItem a = offlineCopy('d');
      r.trackStarted(a);
      r.trackLeft(
        MusicTrackLeave(
          item: a,
          position: const Duration(seconds: 200),
          duration: const Duration(seconds: 200),
          restoring: false,
          completed: true,
        ),
      );
      await r.idle;
      expect(queued, isEmpty);
      expect(errors, hasLength(1));
    });
  });
}
