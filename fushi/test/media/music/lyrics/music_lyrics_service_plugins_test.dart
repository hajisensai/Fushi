import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/plugin/music_plugins.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_music/fushi_music.dart';

/// 歌词插件来源链（LRCLIB 之后）：顺序、首个命中胜出、禁用跳过、负缓存、错误隔离。
/// 解析走真 Rust 库（硬依赖）。
Future<LyricTimeline> _parse(Uint8List b, String hint, int? d) async =>
    FushiLyrics.parse(b, hint: hint, durationMs: d);

class _FakePlugins {
  /// pluginId -> 搜索结果（null = 抛 [MusicPluginException]）。
  final Map<String, List<MusicPluginLyricsCandidate>?> candidates =
      <String, List<MusicPluginLyricsCandidate>?>{};

  /// pluginId -> 取词结果。
  final Map<String, MusicPluginLyrics?> lyrics = <String, MusicPluginLyrics?>{};
  final List<String> searched = <String>[];
  final List<String> fetched = <String>[];

  Future<List<MusicPluginLyricsCandidate>> search(
    String id,
    String title, {
    String? artist,
    String? album,
    int? durationMs,
    String? query,
  }) async {
    searched.add(id);
    final List<MusicPluginLyricsCandidate>? c = candidates[id];
    if (c == null) throw MusicPluginException('boom $id');
    return c;
  }

  Future<MusicPluginLyrics?> fetch(String id, Object ref) async {
    fetched.add(id);
    return lyrics[id];
  }
}

MusicPluginLyricsCandidate _cand(String id) => MusicPluginLyricsCandidate(
  title: 'Song',
  artist: 'Artist',
  durationMs: 200000,
  ref: <String, Object?>{'id': id},
);

MusicPluginLyrics _lyr(String text) => MusicPluginLyrics(
  original: MusicPluginLyricText(format: 'lrc', text: text),
);

void main() {
  late FushiDatabase db;
  late _FakePlugins plugins;
  late List<String> enabled;
  late List<Uri> lrclibCalls;
  late int lrclibStatus;
  late String lrclibBody;
  late bool online;
  late int now;

  MusicLyricsService service({bool withPlugins = true}) => MusicLyricsService(
    database: () => db,
    lrclib: LrclibClient(
      transport: (Uri uri) async {
        lrclibCalls.add(uri);
        return (status: lrclibStatus, body: lrclibBody);
      },
    ),
    onlineEnabled: () => online,
    readEmbedded: (String _, int? _) async => <EmbeddedLyrics>[],
    parse: _parse,
    now: () => now,
    pluginSearch: withPlugins ? plugins.search : null,
    pluginFetch: withPlugins ? plugins.fetch : null,
    providers: withPlugins ? () async => enabled : null,
  );

  const MusicLyricsTrackRef track = MusicLyricsTrackRef(
    trackUid: 'uid-1',
    path: '/nonexistent/Song.flac',
    title: 'Song',
    artist: 'Artist',
    durationMs: 200000,
  );

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    plugins = _FakePlugins();
    enabled = <String>['a', 'b', 'c'];
    lrclibCalls = <Uri>[];
    lrclibStatus = 404;
    lrclibBody = '';
    online = true;
    now = 1000000;
  });

  tearDown(() => db.close());

  test('LRCLIB 未命中才落到插件', () async {
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[_cand('a')];
    plugins.lyrics['a'] = _lyr('[00:01.00]hi');
    final MusicLyricsResolution? r = await service().resolve(track);
    expect(lrclibCalls, isNotEmpty);
    expect(r!.source, MusicLyricsSource.lyricsPlugin('a'));
  });

  test('LRCLIB 命中时不问任何插件', () async {
    lrclibStatus = 200;
    lrclibBody = File(
      'test/media/music/lyrics/fixtures/lrclib_get.json',
    ).readAsStringSync();
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[_cand('a')];
    plugins.lyrics['a'] = _lyr('[00:01.00]hi');
    const MusicLyricsTrackRef t = MusicLyricsTrackRef(
      trackUid: 'uid-1',
      path: '/nonexistent/x.flac',
      title: '夜に駆ける',
      artist: 'YOASOBI',
      album: 'THE BOOK',
      durationMs: 261000,
    );
    final MusicLyricsResolution r = (await service().resolve(t))!;
    expect(r.source, MusicLyricsSource.lrclib);
    expect(plugins.searched, isEmpty);
  });

  test('按列表顺序问，首个命中胜出，后面的不问', () async {
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[];
    plugins.candidates['b'] = <MusicPluginLyricsCandidate>[_cand('b')];
    plugins.lyrics['b'] = _lyr('[00:01.00]from b');
    plugins.candidates['c'] = <MusicPluginLyricsCandidate>[_cand('c')];
    plugins.lyrics['c'] = _lyr('[00:01.00]from c');
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('b'));
    expect(r.timeline.lines.first.text, 'from b');
    expect(plugins.searched.toSet(), <String>{'a', 'b'});
    expect(
      plugins.searched.indexOf('a'),
      lessThan(plugins.searched.indexOf('b')),
    );
    expect(plugins.fetched, <String>['b']);
  });

  test('未在启用列表里的插件不会被问', () async {
    enabled = <String>['c'];
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[_cand('a')];
    plugins.lyrics['a'] = _lyr('[00:01.00]a');
    plugins.candidates['c'] = <MusicPluginLyricsCandidate>[_cand('c')];
    plugins.lyrics['c'] = _lyr('[00:01.00]c');
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('c'));
    expect(plugins.searched, isNot(contains('a')));
  });

  test('插件报错被隔离：不写负缓存，继续问下一个', () async {
    plugins.candidates['a'] = null; // 抛错
    plugins.candidates['b'] = <MusicPluginLyricsCandidate>[_cand('b')];
    plugins.lyrics['b'] = _lyr('[00:01.00]b');
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('b'));
    final List<MusicLyricRow> rows = await db.select(db.musicLyrics).get();
    expect(
      rows.where(
        (MusicLyricRow x) => x.source == MusicLyricsSource.lyricsPlugin('a'),
      ),
      isEmpty,
    );
  });

  test('没有结果写 1 天负缓存，期内不再问，过期重问', () async {
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[];
    enabled = <String>['a'];
    expect(await service().resolve(track), isNull);
    final MusicLyricRow neg = (await db.select(db.musicLyrics).get())
        .firstWhere(
          (MusicLyricRow x) => x.source == MusicLyricsSource.lyricsPlugin('a'),
        );
    expect(neg.format, kMusicLyricsNoneFormat);
    final int first = plugins.searched.length;
    now += const Duration(hours: 1).inMilliseconds;
    expect(await service().resolve(track), isNull);
    expect(plugins.searched.length, first);
    now += kPluginLyricsNegativeCacheTtl.inMilliseconds;
    await service().resolve(track);
    expect(plugins.searched.length, greaterThan(first));
  });

  test('命中后落库，再解析直接读缓存不再问插件', () async {
    enabled = <String>['a'];
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[_cand('a')];
    plugins.lyrics['a'] = _lyr('[00:01.00]cached');
    await service().resolve(track);
    final int n = plugins.searched.length;
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.source, MusicLyricsSource.lyricsPlugin('a'));
    expect(plugins.searched.length, n);
  });

  test('总闸关闭不问插件；回调为 null（iOS）只剩 LRCLIB', () async {
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[_cand('a')];
    plugins.lyrics['a'] = _lyr('[00:01.00]a');
    online = false;
    expect(await service().resolve(track), isNull);
    expect(plugins.searched, isEmpty);
    online = true;
    expect(await service(withPlugins: false).resolve(track), isNull);
    expect(plugins.searched, isEmpty);
    expect(lrclibCalls, isNotEmpty);
  });

  group('同一插件既给平台曲目自带歌词、又做歌词来源', () {
    const String pluginId = 'a';
    late MusicPluginLyrics? ownReply;
    late int ownFetches;

    MusicLyricsService both() => MusicLyricsService(
      database: () => db,
      lrclib: LrclibClient(
        transport: (Uri uri) async {
          lrclibCalls.add(uri);
          return (status: lrclibStatus, body: lrclibBody);
        },
      ),
      onlineEnabled: () => online,
      readEmbedded: (String _, int? _) async => <EmbeddedLyrics>[],
      parse: _parse,
      now: () => now,
      pluginLyrics: (String id, String trackId) async {
        expect((id, trackId), (pluginId, '7'));
        ownFetches++;
        return ownReply;
      },
      pluginSearch: plugins.search,
      pluginFetch: plugins.fetch,
      providers: () async => enabled,
    );

    final MusicLyricsTrackRef platformTrack = MusicLyricsTrackRef(
      trackUid: musicPluginTrackUid(pluginId, '7'),
      path: musicPluginTrackPath(pluginId, '7'),
      title: 'Song',
      artist: 'Artist',
      durationMs: 200000,
    );

    setUp(() {
      ownReply = null;
      ownFetches = 0;
      enabled = <String>[pluginId];
      plugins.candidates[pluginId] = <MusicPluginLyricsCandidate>[
        _cand(pluginId),
      ];
      plugins.lyrics[pluginId] = _lyr('[00:01.00]fuzzy');
    });

    test('两条路径各记各的缓存：自带歌词的负缓存不挡搜索，搜索结果不冒充自带歌词', () async {
      final MusicLyricsResolution first = (await both().resolve(
        platformTrack,
      ))!;
      expect(first.source, MusicLyricsSource.lyricsPlugin(pluginId));
      expect(first.timeline.lines.first.text, 'fuzzy');
      final Map<String, String> formats = <String, String>{
        for (final MusicLyricRow r in await db.select(db.musicLyrics).get())
          r.source: r.format,
      };
      expect(
        formats[MusicLyricsSource.plugin(pluginId)],
        kMusicLyricsNoneFormat,
      );
      expect(formats[MusicLyricsSource.lyricsPlugin(pluginId)], 'lrc');

      // 负缓存期内：自带歌词不再问，搜索结果走自己的缓存。
      final MusicLyricsResolution cached = (await both().resolve(
        platformTrack,
      ))!;
      expect(cached.source, MusicLyricsSource.lyricsPlugin(pluginId));
      expect(ownFetches, 1);
      expect(plugins.fetched, <String>[pluginId]);

      // 平台补上了歌词：负缓存过期后自带歌词重新被问到并胜出（共用缓存键时 ③' 会把搜索结果
      // 当成自带歌词命中，永远不再问平台）。
      ownReply = _lyr('[00:01.00]official');
      now += kPluginLyricsNegativeCacheTtl.inMilliseconds;
      final MusicLyricsResolution official = (await both().resolve(
        platformTrack,
      ))!;
      expect(ownFetches, 2);
      expect(official.source, MusicLyricsSource.plugin(pluginId));
      expect(official.timeline.lines.first.text, 'official');
    });

    test('选来源面板两份候选都列出，按来源区分', () async {
      ownReply = _lyr('[00:01.00]official');
      await both().resolve(platformTrack);
      // 平台结果胜出时 ⑤ 不会被问；手动写入一份搜索结果模拟早先的命中。
      await db
          .into(db.musicLyrics)
          .insert(
            MusicLyricsCompanion.insert(
              trackUid: platformTrack.trackUid,
              source: MusicLyricsSource.lyricsPlugin(pluginId),
              format: 'lrc',
              raw: Uint8List.fromList(utf8.encode('[00:01.00]fuzzy')),
              updatedAt: now,
            ),
          );
      final List<MusicLyricsCandidate> cands = await both().localCandidates(
        platformTrack,
      );
      expect(
        cands.map((MusicLyricsCandidate c) => (c.source, c.label)).toSet(),
        <(String, String)>{
          (MusicLyricsSource.plugin(pluginId), pluginId),
          (MusicLyricsSource.lyricsPlugin(pluginId), pluginId),
        },
      );
    });
  });

  group('歌词插件结果的缓存新鲜度（解析器版本）', () {
    const String original = '[00:01.00]orig one\n[00:05.00]orig two';
    const String translation = '[00:01.00]译一\n[00:05.00]译二';
    const MusicPluginLyrics withTranslation = MusicPluginLyrics(
      original: MusicPluginLyricText(format: 'lrc', text: original),
      translation: MusicPluginLyricText(
        format: 'lrc',
        text: translation,
        language: 'zh-Hans',
      ),
    );

    test('有译文时落库原始各轨，不是合并后的派生 TTML', () async {
      enabled = <String>['a'];
      plugins.candidates['a'] = <MusicPluginLyricsCandidate>[_cand('a')];
      plugins.lyrics['a'] = withTranslation;
      final MusicLyricsResolution r = (await service().resolve(track))!;
      expect(r.timeline.lines.first.translations.single.text, '译一');
      final MusicLyricRow row = (await db.select(db.musicLyrics).get())
          .singleWhere(
            (MusicLyricRow x) =>
                x.source == MusicLyricsSource.lyricsPlugin('a'),
          );
      expect(row.format, kMusicPluginLyricsTracksFormat);
      final MusicPluginLyrics stored = MusicPluginLyrics.fromJson(
        jsonDecode(utf8.decode(row.raw)),
      )!;
      expect(stored.original!.text, original);
      expect(stored.translation!.text, translation);
      expect(stored.translation!.language, 'zh-Hans');
    });

    test('解析器版本变了：从原始各轨按当前解析器重新合并，不问插件、离线也行', () async {
      enabled = <String>['a'];
      online = false;
      // 旧解析器留下的缓存：时间轴是错的（模拟旧合并规则的产物），版本落后一版。
      final LyricTimeline staleMerge = FushiLyrics.parse(
        utf8.encode('[00:01.00]orig one\n[00:01.80]译一'),
        hint: 'lrc',
      );
      await db
          .into(db.musicLyrics)
          .insert(
            MusicLyricsCompanion.insert(
              trackUid: track.trackUid,
              source: MusicLyricsSource.lyricsPlugin('a'),
              format: kMusicPluginLyricsTracksFormat,
              raw: Uint8List.fromList(
                utf8.encode(jsonEncode(withTranslation.toJson())),
              ),
              timelineCache: Value<Uint8List?>(encodeLyricTimeline(staleMerge)),
              timelineVersion: Value<int>(FushiLyrics.parserVersion - 1),
              offsetMs: const Value<int>(80),
              updatedAt: now,
            ),
          );
      final MusicLyricsResolution r = (await service().resolve(track))!;
      expect(r.source, MusicLyricsSource.lyricsPlugin('a'));
      expect(r.timeline.offsetMs, 80);
      expect(r.timeline.lines.map((LyricLine l) => l.text).toList(), <String>[
        'orig one',
        'orig two',
      ]);
      expect(
        r.timeline.lines
            .map((LyricLine l) => l.translations.single.text)
            .toList(),
        <String>['译一', '译二'],
      );
      expect(plugins.searched, isEmpty);
      expect(plugins.fetched, isEmpty);
      final MusicLyricRow row = (await db.select(db.musicLyrics).get()).single;
      expect(row.timelineVersion, FushiLyrics.parserVersion);
      expect(row.format, kMusicPluginLyricsTracksFormat);
    });

    test('原始各轨坏了按解析错误报，不当成没有歌词', () async {
      await expectLater(
        parseStoredMusicLyrics(
          Uint8List.fromList(utf8.encode('{not json')),
          kMusicPluginLyricsTracksFormat,
          isUserEdited: false,
          parse: _parse,
        ),
        throwsA(isA<LyricsParseException>()),
      );
      await expectLater(
        parseStoredMusicLyrics(
          Uint8List.fromList(utf8.encode('{}')),
          kMusicPluginLyricsTracksFormat,
          isUserEdited: false,
          parse: _parse,
        ),
        throwsA(isA<LyricsParseException>()),
      );
    });
  });

  test('候选与曲目对不上（标题相似度低）不取词也不采用', () async {
    enabled = <String>['a'];
    plugins.candidates['a'] = <MusicPluginLyricsCandidate>[
      const MusicPluginLyricsCandidate(
        title: 'Totally Different',
        artist: 'Other',
        durationMs: 200000,
        ref: <String, Object?>{'id': 'x'},
      ),
    ];
    expect(await service().resolve(track), isNull);
    expect(plugins.fetched, isEmpty);
  });
}
