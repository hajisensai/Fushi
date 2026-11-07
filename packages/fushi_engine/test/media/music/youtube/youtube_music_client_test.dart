import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/media/music/youtube/youtube_music_client.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('youtubeMusicTrackPath', () {
    test('往返保留区分大小写的 videoId', () {
      final String p = youtubeMusicTrackPath('dQw4w9WgXcQ');
      expect(p, 'fushi-music-youtube://video/dQw4w9WgXcQ');
      expect(youtubeMusicVideoIdFromPath(p), 'dQw4w9WgXcQ');
      expect(isYoutubeMusicTrackPath(p), isTrue);
    });

    test('别的路径 / 畸形 id 不认', () {
      expect(youtubeMusicVideoIdFromPath('/music/a.flac'), isNull);
      expect(
        youtubeMusicVideoIdFromPath('fushi-music-plugin://p/dQw4w9WgXcQ'),
        isNull,
      );
      expect(
        youtubeMusicVideoIdFromPath('fushi-music-youtube://video/x'),
        isNull,
      );
      expect(
        youtubeMusicVideoIdFromPath('fushi-music-youtube://other/dQw4w9WgXcQ'),
        isNull,
      );
    });
  });

  group('youtubeMusicTitleArtist', () {
    test('Topic 频道：标题即歌名，艺人去掉后缀', () {
      expect(youtubeMusicTitleArtist('アイドル', 'YOASOBI - Topic'), (
        title: 'アイドル',
        artist: 'YOASOBI',
      ));
    });

    test('艺人「歌名」Official Music Video', () {
      expect(
        youtubeMusicTitleArtist(
          'YOASOBI「アイドル」 Official Music Video',
          'Ayase / YOASOBI',
        ),
        (title: 'アイドル', artist: 'YOASOBI'),
      );
    });

    test('艺人 - 歌名 (Official Video)，保留 feat. 括注', () {
      expect(
        youtubeMusicTitleArtist(
          'Daft Punk - Get Lucky (feat. Pharrell Williams) (Official Video)',
          'DaftPunkVEVO',
        ),
        (title: 'Get Lucky (feat. Pharrell Williams)', artist: 'Daft Punk'),
      );
    });

    test('【MV】前缀括注被去掉', () {
      expect(youtubeMusicTitleArtist('【MV】ずっと真夜中でいいのに。 - 秒針を噛む', 'ZUTOMAYO'), (
        title: '秒針を噛む',
        artist: 'ずっと真夜中でいいのに。',
      ));
    });

    test('认不出结构：整条标题当歌名，艺人取频道（去 VEVO / Official 后缀）', () {
      expect(youtubeMusicTitleArtist('Lemon', 'Kenshi Yonezu Official'), (
        title: 'Lemon',
        artist: 'Kenshi Yonezu',
      ));
      expect(youtubeMusicTitleArtist('Bad Guy', 'BillieEilishVEVO'), (
        title: 'Bad Guy',
        artist: 'BillieEilish',
      ));
    });
  });

  group('YoutubeMusicClient', () {
    YoutubeSearchHit hit(String id, String title, Duration? d) =>
        YoutubeSearchHit(
          videoId: id,
          title: title,
          channelName: 'Artist - Topic',
          channelId: 'UC',
          duration: d,
        );

    test('搜索只出有时长的视频，转成曲目；播放路径是占位 URI', () async {
      String? asked;
      int? askedLimit;
      final YoutubeMusicClient c = YoutubeMusicClient(
        displayName: 'YouTube',
        search: (String q, {int limit = 10}) async {
          asked = q;
          askedLimit = limit;
          return <YoutubeSearchHit>[
            hit('dQw4w9WgXcQ', 'Song', const Duration(minutes: 3)),
            hit('aaaaaaaaaaa', 'Live now', null),
          ];
        },
      );
      final MusicServerSearchResult r = await c.search('song', limit: 7);
      expect(asked, 'song');
      expect(askedLimit, 7);
      expect(r.tracks, hasLength(1));
      final MusicServerTrack t = r.tracks.single;
      expect(t.id, 'dQw4w9WgXcQ');
      expect(t.title, 'Song');
      expect(t.artist, 'Artist');
      expect(t.durationMs, 180000);
      expect(r.albums, isEmpty);
      expect(c.kind, MusicServerKind.youtube);
      expect(
        c.streamFor(t).uri.toString(),
        'fushi-music-youtube://video/dQw4w9WgXcQ',
      );
      expect(c.streamFor(t).transcoded, isFalse);
      expect(
        c.coverUri(t.coverRef).toString(),
        'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
      );
    });

    test('空白查询不发请求', () async {
      bool called = false;
      final YoutubeMusicClient c = YoutubeMusicClient(
        displayName: 'YouTube',
        search: (String q, {int limit = 10}) async {
          called = true;
          return const <YoutubeSearchHit>[];
        },
      );
      expect((await c.search('  ')).isEmpty, isTrue);
      expect(called, isFalse);
    });

    test('没有专辑 / 艺人 / 歌单树', () async {
      final YoutubeMusicClient c = YoutubeMusicClient(displayName: 'YouTube');
      expect((await c.listAlbums()).items, isEmpty);
      expect(await c.listArtists(), isEmpty);
      expect((await c.listPlaylists()).items, isEmpty);
    });
  });

  test('youtubeStreamExpiresAtMs 读 googlevideo 的 expire 参数（秒 → 毫秒）', () {
    expect(
      youtubeStreamExpiresAtMs(
        'https://rr1.googlevideo.com/videoplayback?expire=1700000000&id=x',
      ),
      1700000000000,
    );
    expect(youtubeStreamExpiresAtMs('https://x/videoplayback?id=x'), isNull);
    expect(youtubeStreamExpiresAtMs('https://x/?expire=abc'), isNull);
  });
}
