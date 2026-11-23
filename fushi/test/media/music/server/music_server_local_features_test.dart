// 服务器曲目（Jellyfin / Subsonic）的本机功能：响度（服务器给的 NormalizationGain /
// replayGain 进播放项；音乐库还原的曲目起播期补查）与生成日语字幕的取音频（按当前配置的
// 服务器现算原样直出的流地址，凭据不出内存、报错文本脱敏）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/asr/music_plugin_asr_audio.dart';
import 'package:fushi/src/media/music/asr/music_server_asr_audio.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_loudness_resolver.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_core/fushi_core.dart' show MusicRemoteTrackRow;
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginStream;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// [JellyfinMusicClient.serverId] 是配置派生的 `jellyfin:<地址>|<用户>`。
final String _sid = JellyfinMusicClient(_config).serverId;

const JellyfinServerConfig _config = JellyfinServerConfig(
  serverUrl: 'http://nas:8096',
  username: 'me',
  userId: 'uid',
  accessToken: 'secret-token',
);

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

class _Backend implements FfmpegBackend {
  _Backend({this.returnCode = 0, this.output = ''});

  final int returnCode;
  final String output;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    calls.add(args);
    if (returnCode == 0) {
      File(args.last).writeAsBytesSync(List<int>.filled(1000, 0));
    }
    return FfmpegRunResult(returnCode: returnCode, output: output);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const MusicServerTrack track = MusicServerTrack(
    id: 'jf-t1',
    title: '初恋テスト Track 1',
    albumId: 'jf-a1',
    loudness: MusicServerLoudness(trackGainDb: 3.9),
  );

  group('播放项', () {
    test('服务器给的响度进 rg 字段，服务器身份进 serverTrack（不含凭据）', () {
      final JellyfinMusicClient c = JellyfinMusicClient(_config);
      final MusicPlayItem item = musicServerPlayItem(
        c,
        track,
        maxBitrateKbps: 192,
      );
      expect(item.rgTrackGain, 3.9);
      expect(item.rgAlbumGain, isNull);
      expect(
        item.serverTrack,
        MusicServerTrackRef(
          kind: MusicServerKind.jellyfin,
          serverId: _sid,
          trackId: 'jf-t1',
          albumId: 'jf-a1',
        ),
      );
      expect(item.trackUid, musicServerTrackUid(_sid, 'jf-t1'));
      expect(musicItemNeedsServerLoudness(item), isTrue, reason: '缺专辑增益要补查');
      expect(musicItemIsTranscribableServerTrack(item), isTrue);
    });

    test('音乐库还原的服务器曲目（v149 行里没有响度）同样带 serverTrack，可补查 / 生成字幕', () {
      final MusicPlayItem? item = musicPlayItemOfRemote(
        MusicRemoteTrackRow(
          trackUid: musicServerTrackUid(_sid, 'jf-t1'),
          kind: 'server',
          sourceKey: _sid,
          itemId: 'jf-t1',
          title: 'Track 1',
          albumId: 'jf-a1',
          createdAt: 0,
          updatedAt: 0,
        ),
        server: MusicServerBinding(JellyfinMusicClient(_config)),
      );
      expect(item!.rgTrackGain, isNull);
      expect(item.serverTrack?.trackId, 'jf-t1');
      expect(musicItemNeedsServerLoudness(item), isTrue);
      expect(musicItemIsTranscribableServerTrack(item), isTrue);
    });

    test('补查结果并进已有值：列表当场给的优先，缺的才用补查的', () {
      const MusicPlayItem item = MusicPlayItem(
        trackUid: 'u',
        path: 'http://x',
        title: 't',
        rgTrackGain: 3.9,
      );
      expect(
        musicItemLoudnessWith(
          item,
          const MusicServerLoudness(
            trackGainDb: 1.0,
            trackPeak: 0.5,
            albumGainDb: 3.8,
          ),
        ),
        (trackGain: 3.9, trackPeak: null, albumGain: 3.8, albumPeak: null),
      );
    });

    test('非 Jellyfin / Subsonic（Apple Music、YouTube）不补查、不出字幕入口', () {
      const MusicPlayItem item = MusicPlayItem(
        trackUid: 'u',
        path: 'http://x',
        title: 't',
        serverTrack: MusicServerTrackRef(
          kind: MusicServerKind.appleMusic,
          serverId: 'am',
          trackId: '1',
        ),
      );
      expect(musicItemNeedsServerLoudness(item), isFalse);
      expect(musicItemIsTranscribableServerTrack(item), isFalse);
    });
  });

  group('起播期补查', () {
    test('Jellyfin：一次 Items?Ids=<曲目>,<专辑> 取两份增益；同一首只问一次', () async {
      final List<Uri> seen = <Uri>[];
      final JellyfinMusicClient c = JellyfinMusicClient(
        _config,
        httpClient: MockClient((http.Request r) async {
          seen.add(r.url);
          return _json(<String, Object?>{
            'Items': <Object?>[
              <String, Object?>{'Id': 'jf-t1', 'NormalizationGain': 3.9},
              <String, Object?>{'Id': 'jf-a1', 'NormalizationGain': 3.8},
            ],
          });
        }),
      );
      final BindingMusicServerLoudnessResolver r =
          BindingMusicServerLoudnessResolver(
            () async => <String, MusicServerBinding>{
              _sid: MusicServerBinding(c),
            },
          );
      final MusicServerTrackRef ref = musicServerPlayItem(
        c,
        track,
      ).serverTrack!;
      expect(
        await r.resolve(ref),
        const MusicServerLoudness(trackGainDb: 3.9, albumGainDb: 3.8),
      );
      await r.resolve(ref);
      expect(seen, hasLength(1));
      expect(seen.single.path, '/Users/uid/Items');
      expect(seen.single.queryParameters['Ids'], 'jf-t1,jf-a1');
    });

    test('查询失败不缓存（下次再问）、不抛；没配这台服务器回 null', () async {
      int calls = 0;
      final JellyfinMusicClient c = JellyfinMusicClient(
        _config,
        httpClient: MockClient((http.Request r) async {
          calls++;
          return calls == 1
              ? http.Response('boom', 500)
              : _json(<String, Object?>{
                  'Items': <Object?>[
                    <String, Object?>{'Id': 'jf-t1', 'NormalizationGain': 2.0},
                  ],
                });
        }),
      );
      final BindingMusicServerLoudnessResolver r =
          BindingMusicServerLoudnessResolver(
            () async => <String, MusicServerBinding>{
              _sid: MusicServerBinding(c),
            },
          );
      final MusicServerTrackRef ref = musicServerPlayItem(
        c,
        track,
      ).serverTrack!;
      expect(await r.resolve(ref), isNull);
      expect(await r.resolve(ref), const MusicServerLoudness(trackGainDb: 2.0));
      final BindingMusicServerLoudnessResolver none =
          BindingMusicServerLoudnessResolver(
            () async => const <String, MusicServerBinding>{},
          );
      expect(await none.resolve(ref), isNull);
    });
  });

  group('生成字幕取音频', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('server_asr_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('按当前配置现算原样直出的流（不带码率上限），解码到 <uid>.wav', () async {
      final JellyfinMusicClient c = JellyfinMusicClient(_config);
      final MusicPlayItem item = musicServerPlayItem(
        c,
        track,
        maxBitrateKbps: 128,
      );
      final MusicAsrAudioInput input = await musicServerAsrAudioInput(
        item.serverTrack!,
        servers: () async => <String, MusicServerBinding>{
          _sid: MusicServerBinding(c, maxBitrateKbps: 128),
        },
      );
      final _Backend ffmpeg = _Backend();
      final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
        root: Directory(p.join(tmp.path, 'plugin_audio')),
        backend: () => ffmpeg,
      );
      final ({File audio, bool staged}) got = await musicAsrAudioFileOf(
        input,
        item: item,
        stager: stager,
        onProgress: (_) {},
        cancel: Completer<void>().future,
      );
      expect(got.staged, isTrue);
      expect(p.basename(got.audio.path), '${item.trackUid}.wav');
      final String url =
          ffmpeg.calls.single[ffmpeg.calls.single.indexOf('-i') + 1];
      final Uri u = Uri.parse(url);
      expect(u.path, '/Audio/jf-t1/stream', reason: '转写不需要服务器再转码一次');
      expect(u.queryParameters['static'], 'true');
      expect(u.queryParameters.containsKey('MaxStreamingBitrate'), isFalse);
    });

    test('离线副本：直接转写、不删', () async {
      final File f = File(p.join(tmp.path, 'x.flac'))
        ..writeAsBytesSync(<int>[1]);
      final ({File audio, bool staged}) got = await musicAsrAudioFileOf(
        MusicAsrLocalAudio(f),
        item: musicServerPlayItem(JellyfinMusicClient(_config), track),
        stager: MusicPluginAsrAudioStager(root: tmp),
        onProgress: (_) {},
        cancel: Completer<void>().future,
      );
      expect(got, (audio: f, staged: false));
    });

    test('这台设备没配这台服务器：明确报出来', () async {
      await expectLater(
        musicServerAsrAudioInput(
          musicServerPlayItem(JellyfinMusicClient(_config), track).serverTrack!,
          servers: () async => const <String, MusicServerBinding>{},
        ),
        throwsA(isA<MusicPluginAsrAudioUnavailable>()),
      );
    });

    test('ffmpeg 失败：报错文本里的流地址凭据脱敏', () async {
      final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
        root: tmp,
        backend: () => _Backend(
          returnCode: 1,
          output:
              'http://nas:8096/Audio/jf-t1/universal?api_key=secret-token&'
              'UserId=uid: Server returned 401 Unauthorized',
        ),
      );
      await expectLater(
        stager.stageStream(
          musicServerPlayItem(JellyfinMusicClient(_config), track),
          open: () async => const MusicPluginStream(url: 'http://nas:8096/x'),
          onProgress: (_) {},
          cancel: Completer<void>().future,
        ),
        throwsA(
          isA<MusicPluginAsrAudioUnavailable>().having(
            (MusicPluginAsrAudioUnavailable e) => e.message,
            'message',
            allOf(contains('401'), isNot(contains('secret-token'))),
          ),
        ),
      );
    });
  });
}
