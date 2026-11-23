import 'dart:convert';

import 'package:fushi_engine/media/music/server/jellyfin_music_parse.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart';
import 'package:fushi_engine/media/music/server/subsonic_server_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 服务器曲目的响度：Jellyfin `NormalizationGain`（真 Jellyfin 10.10.7 开了 LUFS 扫描后曲目 /
/// 专辑条目各带一份）与 OpenSubsonic `replayGain` 解析进 [MusicServerTrack.loudness]；
/// 音乐库还原的曲目起播时经 [MusicServerLoudnessLookup] 补查。
void main() {
  group('Jellyfin NormalizationGain', () {
    test('曲目条目带 NormalizationGain → 曲目增益；没有 → null', () {
      final MusicServerTrack? t = parseJellyfinMusicTrack(<String, Object?>{
        'Id': 't1',
        'Name': '初恋テスト Track 1',
        'AlbumId': 'a1',
        'NormalizationGain': 3.8999996,
      });
      expect(t!.loudness, const MusicServerLoudness(trackGainDb: 3.8999996));
      final MusicServerTrack? none = parseJellyfinMusicTrack(<String, Object?>{
        'Id': 't2',
        'Name': 'x',
      });
      expect(none!.loudness, isNull, reason: '媒体库没开 LUFS 扫描时没有这一项');
    });

    test('Items?Ids=<曲目>,<专辑>：曲目增益取曲目条目、专辑增益取专辑条目', () {
      expect(
        jellyfinLoudnessOfItems(
          <Map<String, Object?>>[
            <String, Object?>{
              'Id': 't1',
              'Type': 'Audio',
              'NormalizationGain': 3.9,
            },
            <String, Object?>{
              'Id': 'a1',
              'Type': 'MusicAlbum',
              'NormalizationGain': 3.8,
            },
          ],
          trackId: 't1',
          albumId: 'a1',
        ),
        const MusicServerLoudness(trackGainDb: 3.9, albumGainDb: 3.8),
      );
      expect(
        jellyfinLoudnessOfItems(
          <Map<String, Object?>>[
            <String, Object?>{'Id': 't1'},
          ],
          trackId: 't1',
          albumId: 'a1',
        ),
        isNull,
      );
    });
  });

  group('OpenSubsonic replayGain', () {
    test('四项齐全', () {
      expect(
        parseOpenSubsonicReplayGain(<String, Object?>{
          'trackGain': -7.5,
          'albumGain': -6.25,
          'trackPeak': 0.98,
          'albumPeak': 1.0,
        }),
        const MusicServerLoudness(
          trackGainDb: -7.5,
          trackPeak: 0.98,
          albumGainDb: -6.25,
          albumPeak: 1.0,
        ),
      );
    });

    test('没标签的文件填 0 占位（没有峰值）按「没有」处理；缺对象为 null', () {
      expect(
        parseOpenSubsonicReplayGain(<String, Object?>{
          'trackGain': 0,
          'albumGain': 0,
        }),
        isNull,
      );
      expect(parseOpenSubsonicReplayGain(null), isNull);
      expect(
        parseOpenSubsonicReplayGain(<String, Object?>{
          'trackGain': 0,
          'trackPeak': 0.5,
        }),
        const MusicServerLoudness(trackGainDb: 0, trackPeak: 0.5),
        reason: '有峰值时 0 dB 是真值',
      );
    });

    SubsonicMusicClient client(Object Function(Uri u) body) =>
        SubsonicMusicClient(
          SubsonicServerConfig(
            id: 'nd',
            name: 'Navidrome',
            serverUrl: Uri.parse('https://music.example.com/'),
            username: 'alice',
            password: 'sesame',
          ),
          client: MockClient(
            (http.Request r) async => http.Response.bytes(
              utf8.encode(jsonEncode(body(r.url))),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            ),
          ),
          saltSource: () => 'abcdef',
        );

    Map<String, Object?> ok(Map<String, Object?> body) => <String, Object?>{
      'subsonic-response': <String, Object?>{'status': 'ok', ...body},
    };

    test('getAlbum 的曲目带 replayGain → MusicServerTrack.loudness', () async {
      final List<MusicServerTrack> tracks = await client(
        (Uri u) => ok(<String, Object?>{
          'album': <String, Object?>{
            'song': <Object?>[
              <String, Object?>{
                'id': 's1',
                'title': 'Song',
                'replayGain': <String, Object?>{
                  'trackGain': -3.0,
                  'albumGain': -2.0,
                },
              },
            ],
          },
        }),
      ).albumTracks('al1');
      expect(
        tracks.single.loudness,
        const MusicServerLoudness(trackGainDb: -3.0, albumGainDb: -2.0),
      );
    });

    test('补查走 getSong?id=<曲目>', () async {
      final List<Uri> seen = <Uri>[];
      final MusicServerLoudness? l =
          await client((Uri u) {
            seen.add(u);
            return ok(<String, Object?>{
              'song': <String, Object?>{
                'id': 's1',
                'replayGain': <String, Object?>{'trackGain': -4.5},
              },
            });
          }).loudnessOf(
            const MusicServerTrackRef(
              kind: MusicServerKind.subsonic,
              serverId: 'subsonic-nd',
              trackId: 's1',
            ),
          );
      expect(l, const MusicServerLoudness(trackGainDb: -4.5));
      expect(seen.single.path, '/rest/getSong');
      expect(seen.single.queryParameters['id'], 's1');
    });
  });
}
