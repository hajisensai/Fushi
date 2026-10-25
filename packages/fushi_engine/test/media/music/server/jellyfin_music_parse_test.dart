import 'package:fushi_engine/media/music/server/jellyfin_music_parse.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:test/test.dart';

/// Jellyfin 音乐条目解析（字段形状按 Jellyfin 10.10 `BaseItemDto` 的真实响应手写）。
void main() {
  test('音乐库视图：只要 CollectionType == music', () {
    expect(
      jellyfinMusicLibraryIds(<String, Object?>{
        'Items': <Object?>[
          <String, Object?>{'Id': 'm1', 'CollectionType': 'music'},
          <String, Object?>{'Id': 'v1', 'CollectionType': 'movies'},
          <String, Object?>{'Id': 'm2', 'CollectionType': 'Music'},
          <String, Object?>{'Id': 'x'},
        ],
      }),
      <String>['m1', 'm2'],
    );
  });

  test('专辑：艺人回落 AlbumArtists、封面只在有 Primary 图时给', () {
    final MusicServerAlbum a = parseJellyfinMusicAlbum(<String, Object?>{
      'Id': 'al1',
      'Name': 'Night Album',
      'AlbumArtists': <Object?>[
        <String, Object?>{'Name': 'Singer', 'Id': 'ar1'},
      ],
      'ProductionYear': 2020,
      'ChildCount': 12,
      'RunTimeTicks': 30000000000,
      'ImageTags': <String, Object?>{'Primary': 'tag'},
    })!;
    expect(a.title, 'Night Album');
    expect(a.artist, 'Singer');
    expect(a.artistId, 'ar1');
    expect(a.year, 2020);
    expect(a.trackCount, 12);
    expect(a.durationMs, 3000000);
    expect(a.coverRef, 'al1');
    expect(
      parseJellyfinMusicAlbum(<String, Object?>{
        'Id': 'b',
        'Name': 'x',
      })!.coverRef,
      isNull,
    );
    expect(parseJellyfinMusicAlbum(<String, Object?>{'Name': 'no id'}), isNull);
  });

  test('曲目：音频流属性、码率换 kbps、封面回落专辑图；乱序按碟号 / 轨号排', () {
    Map<String, Object?> track(String id, int disc, int no) =>
        <String, Object?>{
          'Id': id,
          'Name': 'Song $id',
          'Artists': <Object?>['A', 'B'],
          'Album': 'Night Album',
          'AlbumId': 'al1',
          'AlbumPrimaryImageTag': 'tag',
          'ParentIndexNumber': disc,
          'IndexNumber': no,
          'RunTimeTicks': 1850000000,
          'Container': 'FLAC',
          'MediaStreams': <Object?>[
            <String, Object?>{
              'Type': 'Audio',
              'Codec': 'FLAC',
              'BitRate': 2116000,
              'SampleRate': 96000,
              'BitDepth': 24,
              'Channels': 2,
            },
          ],
          'MediaSources': <Object?>[
            <String, Object?>{'Size': 49000000, 'Container': 'flac'},
          ],
        };
    final List<MusicServerTrack> tracks =
        sortMusicServerTracks(<MusicServerTrack>[
          parseJellyfinMusicTrack(track('t3', 2, 1))!,
          parseJellyfinMusicTrack(track('t2', 1, 2))!,
          parseJellyfinMusicTrack(track('t1', 1, 1))!,
        ]);
    expect(tracks.map((MusicServerTrack t) => t.id), <String>[
      't1',
      't2',
      't3',
    ]);
    final MusicServerTrack t = tracks.first;
    expect(t.artist, 'A, B');
    expect(t.codec, 'flac');
    expect(t.container, 'flac');
    expect(t.bitrateKbps, 2116);
    expect(t.sampleRate, 96000);
    expect(t.bitDepth, 24);
    expect(t.durationMs, 185000);
    expect(t.sizeBytes, 49000000);
    expect(t.isLossless, isTrue);
    expect(t.coverRef, 'al1');
  });

  test('播放流：原样直出 static=true；给了上限走 universal 请服务器转码', () {
    final ({String path, Map<String, String> query, bool transcoded}) direct =
        jellyfinMusicStreamRequest(
          trackId: 't1',
          userId: 'u',
          deviceId: 'd',
          token: 'tok',
        );
    expect(direct.path, '/Audio/t1/stream');
    expect(direct.query['static'], 'true');
    expect(direct.query['api_key'], 'tok');
    expect(direct.transcoded, isFalse);
    final ({String path, Map<String, String> query, bool transcoded}) capped =
        jellyfinMusicStreamRequest(
          trackId: 't1',
          userId: 'u',
          deviceId: 'd',
          token: 'tok',
          maxBitrateKbps: 192,
        );
    expect(capped.path, '/Audio/t1/universal');
    expect(capped.query['MaxStreamingBitrate'], '192000');
    expect(capped.query['AudioCodec'], 'opus');
    expect(capped.query['Container'], contains('flac'));
    expect(capped.transcoded, isTrue);
  });

  test('播放身份：服务器 + 条目派生、稳定、与专辑命名空间不撞', () {
    final String a = musicServerTrackUid('srv-1', 'x');
    expect(a, musicServerTrackUid('srv-1', 'x'));
    expect(a, isNot(musicServerTrackUid('srv-2', 'x')));
    expect(a, isNot(musicServerAlbumUid('srv-1', 'x')));
    expect(a, startsWith('srv'));
    expect(a, hasLength(33));
  });
}
