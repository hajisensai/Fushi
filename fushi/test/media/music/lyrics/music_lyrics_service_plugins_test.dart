import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lrclib_client.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_sources.dart';
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
    expect(r!.source, MusicLyricsSource.plugin('a'));
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
    expect(r.source, MusicLyricsSource.plugin('b'));
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
    expect(r.source, MusicLyricsSource.plugin('c'));
    expect(plugins.searched, isNot(contains('a')));
  });

  test('插件报错被隔离：不写负缓存，继续问下一个', () async {
    plugins.candidates['a'] = null; // 抛错
    plugins.candidates['b'] = <MusicPluginLyricsCandidate>[_cand('b')];
    plugins.lyrics['b'] = _lyr('[00:01.00]b');
    final MusicLyricsResolution r = (await service().resolve(track))!;
    expect(r.source, MusicLyricsSource.plugin('b'));
    final List<MusicLyricRow> rows = await db.select(db.musicLyrics).get();
    expect(
      rows.where(
        (MusicLyricRow x) => x.source == MusicLyricsSource.plugin('a'),
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
          (MusicLyricRow x) => x.source == MusicLyricsSource.plugin('a'),
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
    expect(r.source, MusicLyricsSource.plugin('a'));
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
