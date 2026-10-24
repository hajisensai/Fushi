import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/lyric_cues.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 歌词来源优先级 + `music_lyrics` 落库 + LRCLIB（离线 fixture，不出网）。解析走真 Rust 库
/// （硬依赖：找不到库这里判红）。
const String _fixtures = 'test/media/music/lyrics/fixtures';

Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

class _FakeLrclib {
  final List<Uri> calls = <Uri>[];
  String? getBody = File('$_fixtures/lrclib_get.json').readAsStringSync();
  int getStatus = 200;

  Future<({int status, String body})> call(Uri uri) async {
    calls.add(uri);
    if (uri.path == '/api/search') {
      return (
        status: 200,
        body: File('$_fixtures/lrclib_search.json').readAsStringSync(),
      );
    }
    return (status: getStatus, body: getBody ?? '');
  }
}

void main() {
  late FushiDatabase db;
  late Directory dir;
  late _FakeLrclib lrclib;
  late List<EmbeddedLyrics> embedded;
  late bool online;
  late int now;

  MusicLyricsService service() => MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(transport: lrclib.call),
    onlineEnabled: () => online,
    readEmbedded: (String _, int? _) async => embedded,
    parse: _parse,
    now: () => now,
  );

  MusicLyricsTrackRef track({int? cueStartMs}) => MusicLyricsTrackRef(
    trackUid: 'uid-1',
    path: '${dir.path}${Platform.pathSeparator}夜に駆ける.flac',
    title: '夜に駆ける',
    artist: 'YOASOBI',
    album: 'THE BOOK',
    durationMs: 261000,
    cueStartMs: cueStartMs,
  );

  void writeSide(String name, String content) => File(
    '${dir.path}${Platform.pathSeparator}$name',
  ).writeAsStringSync(content);

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('fushi_lyrics_svc_');
    File(
      '${dir.path}${Platform.pathSeparator}夜に駆ける.flac',
    ).writeAsBytesSync(<int>[0]);
    lrclib = _FakeLrclib();
    embedded = <EmbeddedLyrics>[];
    online = true;
    now = 1000000;
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  group('pickLyricSidecars', () {
    test('按档位挑正文、语言后缀当翻译、不区分大小写', () {
      final LyricSidecarSet s = pickLyricSidecars('/m/Song.flac', <String>[
        '/m/Song.flac',
        '/m/song.lrc',
        '/m/Song.TTML',
        '/m/Song.zh.lrc',
        '/m/Song.zh.srt',
        '/m/Song.en-US.vtt',
        '/m/Other.lrc',
        '/m/Song.cover.jpg',
      ]);
      expect(s.primary!.path, '/m/Song.TTML');
      expect(s.primary!.ext, 'ttml');
      expect(
        s.translations.map((LyricSidecarFile f) => (f.translationLang, f.ext)),
        <(String?, String)>[('zh', 'lrc'), ('en-US', 'vtt')],
      );
    });

    test('只有翻译文件时拿它当正文', () {
      final LyricSidecarSet s = pickLyricSidecars('/m/a.mp3', <String>[
        '/m/a.ja.lrc',
      ]);
      expect(s.primary!.path, '/m/a.ja.lrc');
      expect(s.translations, isEmpty);
    });
  });

  test('sidecar 优先于内嵌与在线；翻译 sidecar 按时间合并；行落库带版本', () async {
    writeSide('夜に駆ける.lrc', '[00:01.00]沈むように\n[00:05.00]溶けてゆくように');
    writeSide('夜に駆ける.zh.lrc', '[00:01.10]像沉没一般\n[00:05.00]像融化一般');
    final MusicLyricsResolution? r = await service().resolve(track());
    expect(r!.source, MusicLyricsSource.sidecar);
    expect(
      r.timeline.lines[0].translations.single,
      const LyricTranslation('zh', '像沉没一般'),
    );
    expect(lrclib.calls, isEmpty, reason: '本地有歌词不出网');
    final List<MusicLyricRow> rows = await db.select(db.musicLyrics).get();
    expect(rows.single.source, MusicLyricsSource.sidecar);
    expect(rows.single.timelineVersion, FushiLyrics.parserVersion);
    expect(decodeLyricTimeline(rows.single.timelineCache!).lines.length, 2);
  });

  test('没有 sidecar 用内嵌（取最细粒度那条）', () async {
    final LyricTimeline plain = FushiLyrics.parse(utf8.encode('just text'));
    final LyricTimeline synced = FushiLyrics.parse(
      utf8.encode('[00:02.00]夜に駆ける'),
      hint: 'lrc',
    );
    embedded = <EmbeddedLyrics>[
      EmbeddedLyrics(
        key: 'unsyncedlyrics',
        format: 'txt',
        raw: utf8.encode('just text'),
        timeline: plain,
      ),
      EmbeddedLyrics(
        key: 'lyrics',
        format: 'lrc',
        raw: utf8.encode('[00:02.00]夜に駆ける'),
        timeline: synced,
      ),
    ];
    final MusicLyricsResolution? r = await service().resolve(track());
    expect(r!.source, MusicLyricsSource.embedded);
    expect(r.timeline.lines.single.text, '夜に駆ける');
  });

  test('CUE 虚拟曲目不认同名 sidecar / 内嵌，走 LRCLIB 精确匹配并缓存进 DB', () async {
    writeSide('夜に駆ける.lrc', '[00:01.00]整张镜像的歌词');
    final MusicLyricsResolution? r = await service().resolve(
      track(cueStartMs: 60000),
    );
    expect(r!.source, MusicLyricsSource.lrclib);
    expect(r.timeline.lines.first.text, '沈むように溶けてゆくように');
    final Uri call = lrclib.calls.single;
    expect(call.path, '/api/get');
    expect(call.queryParameters, <String, String>{
      'track_name': '夜に駆ける',
      'artist_name': 'YOASOBI',
      'album_name': 'THE BOOK',
      'duration': '261',
    });
    // 第二次直接读缓存，不再出网。
    await service().resolve(track(cueStartMs: 60000));
    expect(lrclib.calls.length, 1);
  });

  test('LRCLIB 时长差超过 2 s 不采用，写负缓存，TTL 内不再查', () async {
    lrclib.getBody = jsonEncode(<String, Object?>{
      ...jsonDecode(File('$_fixtures/lrclib_get.json').readAsStringSync())
          as Map<String, Object?>,
      'duration': 270.0,
    });
    expect(await service().resolve(track()), isNull);
    final MusicLyricRow neg = (await db.select(db.musicLyrics).get()).single;
    expect(neg.format, kMusicLyricsNoneFormat);
    now += const Duration(days: 1).inMilliseconds;
    expect(await service().resolve(track()), isNull);
    expect(lrclib.calls.length, 1);
    now += kLrclibNegativeCacheTtl.inMilliseconds;
    await service().resolve(track());
    expect(lrclib.calls.length, 2, reason: 'TTL 过后重查');
  });

  test('关掉在线歌词不出网', () async {
    online = false;
    expect(await service().resolve(track()), isNull);
    expect(lrclib.calls, isEmpty);
  });

  test('模糊搜索：有时间的排前、纯音乐剔除、不落库', () async {
    final List<MusicLyricsCandidate> c = await service().searchOnline(track());
    expect(c.length, 2);
    expect(c.first.format, 'lrc');
    expect(c.first.label, '夜に駆ける — YOASOBI');
    expect(await db.select(db.musicLyrics).get(), isEmpty);
  });

  test('用户编辑永远最高、偏移持久化、撤销后回到自动优先级', () async {
    writeSide('夜に駆ける.lrc', '[00:01.00]沈むように');
    final MusicLyricsService s = service();
    final MusicLyricsResolution side = (await s.resolve(track()))!;
    await s.setOffset('uid-1', side.source, 250);
    expect((await s.resolve(track()))!.timeline.offsetMs, 250);

    final LyricLine l = side.timeline.lines.single;
    final LyricTimeline edited = side.timeline.copyWith(
      lines: <LyricLine>[
        l.copyWith(
          syllables: <LyricSyllable>[
            l.syllables.single.copyWith(text: '沈むように!'),
          ],
          translations: const <LyricTranslation>[LyricTranslation('zh', '像沉没')],
        ),
      ],
      offsetMs: -100,
    );
    await s.saveUserEdit('uid-1', edited);
    final MusicLyricsResolution user = (await s.resolve(track()))!;
    expect(user.source, MusicLyricsSource.user);
    expect(user.timeline.isUserEdited, isTrue);
    expect(user.timeline.offsetMs, -100);
    expect(user.timeline.lines.single.text, '沈むように!');
    final MusicLyricRow row = (await (db.select(
      db.musicLyrics,
    )..where(($MusicLyricsTable t) => t.source.equals('user'))).getSingle());
    expect(row.format, 'ttml');
    expect(utf8.decode(row.raw), contains('像沉没'));

    await s.clearUserEdit('uid-1');
    final MusicLyricsResolution back = (await s.resolve(track()))!;
    expect(back.source, MusicLyricsSource.sidecar);
    expect(back.timeline.offsetMs, 250);
  });

  test('缓存版本对不上时从 raw 重建', () async {
    writeSide('夜に駆ける.lrc', '[00:01.00]沈むように');
    final MusicLyricsService s = service();
    final MusicLyricsResolution side = (await s.resolve(track()))!;
    await s.saveUserEdit('uid-1', side.timeline);
    await (db.update(
      db.musicLyrics,
    )..where(($MusicLyricsTable t) => t.source.equals('user'))).write(
      const MusicLyricsCompanion(
        timelineVersion: Value<int>(0),
        timelineCache: Value<Uint8List?>(null),
      ),
    );
    final MusicLyricsResolution again = (await s.resolve(track()))!;
    expect(again.timeline.lines.single.text, '沈むように');
    final MusicLyricRow row = await (db.select(
      db.musicLyrics,
    )..where(($MusicLyricsTable t) => t.source.equals('user'))).getSingle();
    expect(row.timelineVersion, FushiLyrics.parserVersion);
  });

  test('导出到音频旁边：显式操作、默认不覆盖', () async {
    final LyricTimeline t = FushiLyrics.parse(
      utf8.encode('[00:01.00]沈むように'),
      hint: 'lrc',
    );
    final String path = await service().exportBesideAudio(track(), t, 'ttml');
    expect(path, endsWith('夜に駆ける.ttml'));
    expect(File(path).readAsStringSync(), contains('<tt'));
    expect(
      () => service().exportBesideAudio(track(), t, 'ttml'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('LyricTimeline → AudioCue：偏移与 CUE 起点换回音频时间、跳过和声', () {
    final LyricTimeline t = FushiLyrics.parse(
      File(
        '../native/fushi_music/tests/fixtures/lyrics/samples/amll.ttml',
      ).readAsBytesSync(),
      hint: 'ttml',
    ).copyWith(offsetMs: 200);
    final List<AudioCue> cues = lyricTimelineToAudioCues(
      t,
      trackUid: 'uid-1',
      fileOffsetMs: 60000,
      lineOffsetsMs: const <int, int>{2: 100},
    );
    expect(cues.length, 2);
    expect(cues[0].text, '沈むように');
    expect(cues[0].startMs, 1000 - 200 + 60000);
    expect(cues[1].sentenceIndex, 2);
    expect(cues[1].startMs, 5000 - 200 - 100 + 60000);
  });
}
