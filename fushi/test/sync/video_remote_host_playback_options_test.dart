import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 视频遥控的选集 / 音量 / 字幕轨（反馈 SS9coDLqrd）：协议层（假播放器绑定）。
///
/// 旧绑定（不提供这三组回调）必须在快照里不声明能力、收到新命令时明确回
/// `action_unsupported`；新绑定按能力声明、参数校验、会话校验执行。
void main() {
  late FushiDatabase db;
  late VideoRemoteHost host;
  late Map<String, Object?> snapshot;
  int serial = 0;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    host = VideoRemoteHost(
      favorites: () => FavoriteSentenceRepository(db),
      now: () => DateTime(2026, 10, 16),
    );
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
  });

  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) => host.handle(operation, <String, dynamic>{
    'sessionId': snapshot['sessionId'],
    'subtitleVersion': snapshot['subtitleVersion'],
    'requestId': 'request_${++serial}',
    ...data,
  }, 'phone');

  Future<void> connect(_FakePlayer player) async {
    host.register(player.binding(full: player.full));
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
  }

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  group('旧播放器绑定（无新回调）', () {
    test('快照不声明能力，新命令明确回 action_unsupported', () async {
      final _FakePlayer player = _FakePlayer(full: false);
      await connect(player);
      expect(snapshot['capabilities'], isEmpty);
      for (final Map<String, dynamic> body in <Map<String, dynamic>>[
        <String, dynamic>{'action': 'volume', 'volume': 50},
        <String, dynamic>{'action': 'episode', 'episodeIndex': 1},
        <String, dynamic>{'action': 'subtitleTrack', 'trackId': 'a'},
      ]) {
        await expectLater(
          call('command', body),
          throwsA(remoteError(409, videoRemoteActionUnsupported)),
          reason: body['action'].toString(),
        );
      }
      final Map<String, Object?> options = await call('playbackOptions');
      expect(options['episodes'], isEmpty);
      expect(options['subtitleTracks'], isEmpty);
    });

    test('未知动作仍是 invalid_action', () async {
      await connect(_FakePlayer(full: false));
      await expectLater(
        call('command', <String, dynamic>{'action': 'speed'}),
        throwsA(remoteError(400, 'invalid_action')),
      );
    });
  });

  group('新播放器绑定', () {
    late _FakePlayer player;
    setUp(() async {
      player = _FakePlayer(full: true);
      await connect(player);
    });

    test('快照声明三种能力并带音量 / 集数', () {
      expect(
        snapshot['capabilities'],
        unorderedEquals(<String>[
          videoRemoteCapabilityVolume,
          videoRemoteCapabilityEpisodes,
          videoRemoteCapabilitySubtitleTracks,
        ]),
      );
      expect(snapshot['volume'], 80);
      expect(snapshot['episodeCount'], 3);
    });

    test('volume：转给播放器、校验范围、不结束进行中的查词', () async {
      final Map<String, Object?> lookup = await call(
        'lookupBegin',
        <String, dynamic>{'cueId': 'c1'},
      );
      await call('command', <String, dynamic>{
        'action': 'volume',
        'volume': 35,
      });
      expect(player.volumes, <int>[35]);
      // 查词上下文仍在（音量不是播放意图）。
      await call('lookupContext', <String, dynamic>{
        'contextId': lookup['contextId'],
        'action': 'preview',
      });
      for (final Object? bad in <Object?>[-1, 101, '50', 12.5, null]) {
        await expectLater(
          call('command', <String, dynamic>{'action': 'volume', 'volume': bad}),
          throwsA(remoteError(400, 'invalid_number')),
          reason: '$bad',
        );
      }
      expect(player.volumes, <int>[35]);
    });

    test('电脑上改音量在 1 秒节流内也立即推给手机（暂停时没有别的通知）', () async {
      final int revision = snapshot['revision']! as int;
      player.volume = 20;
      player.notifyListeners();
      final Map<String, Object?> events = await call(
        'events',
        <String, dynamic>{'afterRevision': revision, 'waitMs': 0},
      );
      final List<Object?> list = events['events']! as List<Object?>;
      expect(list, isNotEmpty);
      final Map<String, Object?> last = list.last! as Map<String, Object?>;
      expect((last['payload']! as Map<String, Object?>)['volume'], 20);
    });

    test('playbackOptions 列出各集与字幕轨，关闭态按无选中轨判', () async {
      final Map<String, Object?> options = await call('playbackOptions');
      expect(options['episodes'], <Map<String, Object?>>[
        <String, Object?>{'index': 0, 'title': 'Ep 1', 'current': true},
        <String, Object?>{'index': 1, 'title': 'Ep 2', 'current': false},
        <String, Object?>{'index': 2, 'title': 'Ep 3', 'current': false},
      ]);
      expect(
        (options['subtitleTracks']! as List<Object?>).map(
          (Object? e) => (e! as Map<String, Object?>)['id'],
        ),
        <String>['ja', 'en', 'pgs'],
      );
      expect(options['subtitleOff'], isFalse);
      player.selectedTrack = null;
      expect((await call('playbackOptions'))['subtitleOff'], isTrue);
    });

    test('playbackOptions 校验会话', () async {
      await expectLater(
        host.handle('playbackOptions', <String, dynamic>{
          'sessionId': 'stale',
          'subtitleVersion': snapshot['subtitleVersion'],
        }, 'phone'),
        throwsA(remoteError(409, 'session_changed')),
      );
    });

    test('episode：只接受列表里的集，交给播放器换集', () async {
      await call('command', <String, dynamic>{
        'action': 'episode',
        'episodeIndex': 2,
      });
      expect(player.switched, <int>[2]);
      await expectLater(
        call('command', <String, dynamic>{
          'action': 'episode',
          'episodeIndex': 7,
        }),
        throwsA(remoteError(404, 'episode_missing')),
      );
      await expectLater(
        call('command', <String, dynamic>{
          'action': 'episode',
          'episodeIndex': '1',
        }),
        throwsA(remoteError(400, 'invalid_number')),
      );
      expect(player.switched, <int>[2]);
    });

    test('subtitleTrack：按 id 选轨 / null 关闭，换轨后字幕版本前进', () async {
      final int before = snapshot['subtitleVersion']! as int;
      await call('command', <String, dynamic>{
        'action': 'subtitleTrack',
        'trackId': 'en',
      });
      expect(player.selections, <String?>['en']);
      final Map<String, Object?> after = await host.handle(
        'snapshot',
        <String, dynamic>{},
        'phone',
      );
      expect(after['subtitleVersion'], before + 1);
      snapshot = after;
      await call('command', <String, dynamic>{
        'action': 'subtitleTrack',
        'trackId': null,
      });
      expect(player.selections, <String?>['en', null]);
      snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
      await expectLater(
        call('command', <String, dynamic>{
          'action': 'subtitleTrack',
          'trackId': 3,
        }),
        throwsA(remoteError(400, 'invalid_argument')),
      );
    });

    test('subtitleTrack：播放器的失败码原样回给手机', () async {
      player.selectError = const VideoRemoteException(
        409,
        'subtitle_track_unavailable',
      );
      await expectLater(
        call('command', <String, dynamic>{
          'action': 'subtitleTrack',
          'trackId': 'pgs',
        }),
        throwsA(remoteError(409, 'subtitle_track_unavailable')),
      );
    });
  });
}

final class _FakePlayer {
  _FakePlayer({required this.full});

  final bool full;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<int> volumes = <int>[];
  final List<int> switched = <int>[];
  final List<String?> selections = <String?>[];
  VideoRemoteException? selectError;
  bool playing = true;
  int controlRevision = 0;
  int volume = 80;
  String? selectedTrack = 'ja';
  List<VideoRemoteCue> cues = const <VideoRemoteCue>[
    VideoRemoteCue(
      id: 'c1',
      text: '一番',
      startMs: 0,
      endMs: 1000,
      delayMs: 0,
      track: 'primary',
    ),
  ];

  void notifyListeners() {
    for (final VoidCallback listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }

  VideoRemotePlaybackBinding binding({required bool full}) =>
      VideoRemotePlaybackBinding(
        identity: () => 'video-one',
        title: () => 'Video',
        bookUid: () => 'book',
        sectionIndex: () => 0,
        cues: () => cues,
        state: () => <String, Object?>{
          'playing': playing,
          'positionMs': 0,
          'speed': 1.0,
          'controlRevision': controlRevision,
          if (full) ...<String, Object?>{'volume': volume, 'episodeCount': 3},
        },
        command: (String action, Map<String, dynamic> body) async {
          controlRevision++;
          playing = action == 'play';
          notifyListeners();
        },
        mine:
            (
              VideoRemoteCue cue,
              Map<String, dynamic> fields,
              VideoRemoteMineSelection selection,
            ) async => <String, Object?>{'success': true},
        openFavorite: (FavoriteSentence favorite) async {},
        addListener: listeners.add,
        removeListener: listeners.remove,
        setVolume: full
            ? (int value) async {
                volumes.add(value);
                volume = value;
              }
            : null,
        episodes: full
            ? () => <VideoRemoteEpisode>[
                for (int i = 0; i < 3; i++)
                  VideoRemoteEpisode(
                    index: i,
                    title: 'Ep ${i + 1}',
                    current: i == 0,
                  ),
              ]
            : null,
        switchEpisode: full ? (int index) async => switched.add(index) : null,
        subtitleTracks: full
            ? () async => <VideoRemoteSubtitleOption>[
                for (final String id in <String>['ja', 'en', 'pgs'])
                  VideoRemoteSubtitleOption(
                    id: id,
                    label: id.toUpperCase(),
                    kind: id == 'pgs' ? 'graphic' : 'embedded',
                    selected: id == selectedTrack,
                    selectable: id != 'pgs',
                  ),
              ]
            : null,
        selectSubtitleTrack: full
            ? (String? id) async {
                final VideoRemoteException? error = selectError;
                if (error != null) throw error;
                selections.add(id);
                selectedTrack = id;
                // 换轨换 cue 列表（新对象），宿主据此前进字幕版本。
                cues = List<VideoRemoteCue>.of(cues);
                notifyListeners();
              }
            : null,
      );
}
