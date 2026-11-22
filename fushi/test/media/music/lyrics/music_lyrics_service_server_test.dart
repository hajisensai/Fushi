import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart';

/// 媒体服务器歌词（③'）：服务器曲目先问服务器、命中就不搜在线；没有 → 负缓存后回落在线；
/// 出错不写负缓存；不是服务器曲目不碰。解析走真 Rust 库。
Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

const MusicServerLyrics _lyrics = MusicServerLyrics(
  lines: <MusicServerLyricLine>[
    MusicServerLyricLine(text: '初恋テスト Track 1 一行目', startMs: 0),
    MusicServerLyricLine(text: '二行目の歌詞です', startMs: 5000),
  ],
);

void main() {
  late FushiDatabase db;
  late List<Uri> lrclibCalls;
  late int now;
  late List<String> asked;

  /// null = 不是服务器曲目；`(lyrics: null)` = 服务器上没有；抛 = 服务器出错。
  late Future<({MusicServerLyrics? lyrics})?> Function() answer;

  MusicLyricsService service() => MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(
      transport: (Uri uri) async {
        lrclibCalls.add(uri);
        return (status: 404, body: '');
      },
    ),
    onlineEnabled: () => true,
    readEmbedded: (String _, int? _) async => <EmbeddedLyrics>[],
    parse: _parse,
    now: () => now,
    serverLyrics: (String uid, String path) {
      asked.add(uid);
      return answer();
    },
  );

  const MusicLyricsTrackRef server = MusicLyricsTrackRef(
    trackUid: 'srv0001',
    path: 'http://nas:8096/Audio/abc/stream?static=true&api_key=x',
    title: '初恋テスト Track 1',
    artist: '宇多田テスト',
    durationMs: 30000,
  );

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    lrclibCalls = <Uri>[];
    now = 1000000;
    asked = <String>[];
    answer = () async => (lyrics: _lyrics);
  });

  tearDown(() => db.close());

  test('服务器有歌词：用它（同步行），不搜在线；第二次走缓存', () async {
    final MusicLyricsResolution r = (await service().resolve(server))!;
    expect(r.source, MusicLyricsSource.server);
    expect(r.timeline.lines.length, 2);
    expect(r.timeline.lines.first.startMs, 0);
    expect(r.timeline.lines.last.startMs, 5000);
    expect(lrclibCalls, isEmpty);
    final MusicLyricsResolution again = (await service().resolve(server))!;
    expect(again.source, MusicLyricsSource.server);
    expect(asked.length, 1);
  });

  test('服务器没有：写负缓存、回落在线；TTL 内不再问服务器', () async {
    answer = () async => (lyrics: null);
    expect(await service().resolve(server), isNull);
    expect(lrclibCalls, isNotEmpty);
    await service().resolve(server);
    expect(asked.length, 1);
    now += kServerLyricsNegativeCacheTtl.inMilliseconds;
    await service().resolve(server);
    expect(asked.length, 2);
  });

  test('服务器出错：不写负缓存，下次还问', () async {
    answer = () async => throw Exception('offline');
    expect(await service().resolve(server), isNull);
    expect(lrclibCalls, isNotEmpty);
    await service().resolve(server);
    expect(asked.length, 2);
  });

  test('不是服务器曲目（fetcher 回 null）：不落任何服务器行', () async {
    answer = () async => null;
    await service().resolve(server);
    final List<MusicLyricRow> rows = await db.select(db.musicLyrics).get();
    expect(
      rows.where((MusicLyricRow r) => r.source == MusicLyricsSource.server),
      isEmpty,
    );
  });

  test('本地文件不问服务器', () async {
    await service().resolve(
      const MusicLyricsTrackRef(
        trackUid: 'local',
        path: '/nonexistent/a.flac',
        title: 'a',
      ),
    );
    expect(asked, isEmpty);
  });

  test('服务器歌词档位在生成字幕之后、LRCLIB 之前', () {
    expect(
      MusicLyricsSource.automaticRank(MusicLyricsSource.server),
      greaterThan(MusicLyricsSource.automaticRank(MusicLyricsSource.asr)),
    );
    expect(
      MusicLyricsSource.automaticRank(MusicLyricsSource.server),
      lessThan(MusicLyricsSource.automaticRank(MusicLyricsSource.lrclib)),
    );
  });
}
