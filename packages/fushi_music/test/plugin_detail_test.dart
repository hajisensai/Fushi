import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart'
    show
        buildPlugin,
        manifest,
        fakePublicResolve,
        noRedirectProbe,
        testVaultKey;

/// 艺人 / 专辑 / 歌单详情、MV 与搜索最佳匹配的契约
/// （docs/specs/2026-10-28-music-plugins.md §4）：新字段解析、截断、坏数据丢弃、封面授权。
const String detailJs = r'''
const ok = 'https://p1.cdn.example.com/';
const evil = 'https://evil.com/';
function longText(n) { let s = ''; while (s.length < n) s += '夜'; return s; }
module.exports = {
  search() { return { items: [], hasMore: false }; },
  album(a) {
    return {
      album: { id: a.id, title: 'A', artists: [{ id: '9', name: 'X' }], coverUrl: ok + 'a.jpg',
               releaseDate: '2024-03-01', company: '  Label  ', description: longText(30000),
               trackCount: -3 },
      tracks: [
        { id: '1', title: 'T1', discNo: 1, mvId: '77' },
        { id: '2', title: 'T2', discNo: 2, mvId: 5 },
      ],
    };
  },
  playlist(a) {
    return { playlist: { id: a.id, title: 'P', owner: 'O', playCount: 123456, description: 'D',
                         tags: ['a', 'a', '', 7, 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l'] },
             tracks: [] };
  },
  artist(a) {
    const hot = [];
    for (let i = 0; i < 80; i++) hot.push({ id: 'h' + i, title: 'H' + i, artists: [] });
    hot.push({ title: 'no id' });
    return {
      artist: { id: a.id, name: 'Name', coverUrl: evil + 'x.jpg',
                aliases: ['Name', 'Alias', 'Alias', '', 3, longText(300)],
                description: '  简介  ',
                intro: [{ title: '经历', text: '正文' }, { title: '空' }, 'junk', { text: '无标题' }],
                stats: { trackCount: 332, albumCount: 55, mvCount: -1, fanCount: 'many' } },
      tracks: hot,
    };
  },
  artistAlbums(a) {
    return { items: [{ id: 'al' + a.page, title: 'Al', coverUrl: ok + 'al.jpg' },
                     { id: 'bad' }, { id: 'ev', title: 'Ev', coverUrl: evil + 'e.jpg' }],
             hasMore: a.page < 2, total: 5 };
  },
  artistMvs(a) {
    if (a.id === 'broken') return { mvs: [] };
    return { items: [{ id: 'm1', title: 'MV1', coverUrl: ok + 'm.jpg', durationMs: 240000,
                       playCount: 99, publishDate: '2025-09-26' },
                     { id: 'm2', title: 'MV2', coverUrl: evil + 'm.jpg', durationMs: -1,
                       publishDate: 'yesterday' },
                     { title: 'no id' }],
             hasMore: false };
  },
  mvStream(a) {
    if (a.id === 'evil') return { url: evil + 'v.mp4' };
    if (a.id === 'none') return {};
    return { url: 'https://v.cdn.example.com/' + a.id + '.mp4?q=' + a.quality,
             headers: { Referer: 'https://api.example.com/', bad: 1 }, expiresAt: 5, width: 1920, height: -1 };
  },
  searchBest(a) {
    if (a.query === 'none') return null;
    return { artist: { id: '1', name: 'ずっと真夜中でいいのに。', aliases: ['ZUTOMAYO'],
                       coverUrl: ok + 'z.jpg', stats: { trackCount: 332, fanCount: 793789 } },
             playlist: { id: 'p', title: '热门精选', coverUrl: evil + 'p.jpg' },
             album: { title: 'missing id' } };
  },
};
''';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-detail-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(MusicPluginManager, MusicPluginSource)> install({
    List<String> caps = const <String>[
      'search',
      'album',
      'playlist',
      'artist',
      'artistAlbums',
      'artistMvs',
      'mvStream',
      'searchBest',
    ],
  }) async {
    final MusicPluginManager m = MusicPluginManager(
      rootDir: root,
      vaultKey: testVaultKey,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
    );
    final Uint8List zip = buildPlugin(manifest(caps: caps), <String, String>{
      'main.js': detailJs,
    });
    await m.install(zip, (await m.inspect(zip)).digest);
    return (m, m.source('moe.test.fake'));
  }

  test('artist：别名去重截断、简介裁空白、坏介绍段丢弃、坏统计当缺失、热门曲封顶、越权头像清空', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final ({
      MusicPluginArtist artist,
      List<MusicPluginAlbum> albums,
      List<MusicPluginTrack> tracks,
    })
    r = await src.artist('42');
    final MusicPluginArtist a = r.artist;
    expect(a.coverUrl, isNull, reason: 'evil.com 不在网络授权内');
    expect(a.aliases.length, 2, reason: '同名、重复、空串、非字符串丢弃');
    expect(a.aliases.first, 'Alias');
    expect(
      a.aliases.last.runes.length,
      MusicPluginTextLimits.alias,
      reason: '超长别名截断',
    );
    expect(a.description, '简介');
    expect(a.intro.map((MusicPluginIntroSection s) => s.text), <String>[
      '正文',
      '无标题',
    ]);
    expect(a.intro.first.title, '经历');
    expect(a.intro.last.title, isNull);
    expect(a.stats.trackCount, 332);
    expect(a.stats.albumCount, 55);
    expect(a.stats.mvCount, isNull, reason: '负数当缺失');
    expect(a.stats.fanCount, isNull, reason: '非数字当缺失');
    expect(a.hasDetails, isTrue);
    expect(r.tracks.length, MusicPluginSource.maxArtistHotTracks);
    expect(r.albums, isEmpty);
    await m.dispose();
  });

  test('artistAlbums / artistMvs：分页、坏条目丢弃、越权封面清空、日期与计数校验', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginPage<MusicPluginAlbum> albums = await src.artistAlbums(
      '42',
      page: 1,
    );
    expect(albums.items.map((MusicPluginAlbum a) => a.id), <String>[
      'al1',
      'ev',
    ]);
    expect(albums.items.first.coverUrl, 'https://p1.cdn.example.com/al.jpg');
    expect(albums.items.last.coverUrl, isNull);
    expect(albums.hasMore, isTrue);
    expect(albums.total, 5);

    final MusicPluginPage<MusicPluginMv> mvs = await src.artistMvs('42');
    expect(mvs.items.map((MusicPluginMv x) => x.id), <String>['m1', 'm2']);
    final MusicPluginMv m1 = mvs.items.first;
    expect(m1.coverUrl, 'https://p1.cdn.example.com/m.jpg');
    expect(m1.durationMs, 240000);
    expect(m1.playCount, 99);
    expect(m1.publishDate, '2025-09-26');
    final MusicPluginMv m2 = mvs.items.last;
    expect(m2.coverUrl, isNull);
    expect(m2.durationMs, isNull);
    expect(m2.publishDate, isNull);
    expect(mvs.hasMore, isFalse);

    await expectLater(
      src.artistMvs('broken'),
      throwsA(isA<MusicPluginException>()),
      reason: '缺 items 按插件错误处理',
    );
    await m.dispose();
  });

  test('mvStream：授权内放行并保留头，越权 / 缺地址报错', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginMvStream s = await src.mvStream(
      'v1',
      quality: MusicPluginQuality.lossless,
    );
    expect(s.url, 'https://v.cdn.example.com/v1.mp4?q=lossless');
    expect(s.headers, <String, String>{'Referer': 'https://api.example.com/'});
    expect(s.expiresAt, 5);
    expect(s.width, 1920);
    expect(s.height, isNull);
    await expectLater(
      src.mvStream('evil'),
      throwsA(isA<MusicPluginException>()),
    );
    await expectLater(
      src.mvStream('none'),
      throwsA(isA<MusicPluginException>()),
    );
    await m.dispose();
  });

  test('album / playlist：新字段解析与截断，曲目 mvId 只收字符串', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final ({MusicPluginAlbum album, List<MusicPluginTrack> tracks}) a =
        await src.album('7');
    expect(a.album.releaseDate, '2024-03-01');
    expect(a.album.company, 'Label');
    expect(
      a.album.description!.runes.length,
      MusicPluginTextLimits.description,
    );
    expect(a.album.trackCount, isNull, reason: '负数当缺失');
    expect(a.tracks.first.mvId, '77');
    expect(a.tracks.last.mvId, isNull, reason: '数字 mvId 当缺失（id 一律字符串）');
    expect(a.tracks.map((MusicPluginTrack t) => t.discNo), <int?>[1, 2]);

    final ({MusicPluginPlaylist playlist, List<MusicPluginTrack> tracks}) p =
        await src.playlist('8');
    expect(p.playlist.playCount, 123456);
    expect(p.playlist.owner, 'O');
    expect(p.playlist.tags.length, MusicPluginTextLimits.maxTags);
    expect(p.playlist.tags.take(3), <String>['a', 'b', 'c']);
    await m.dispose();
  });

  test('searchBest：解析艺人统计与别名，越权封面清空，坏实体丢弃；null 与未声明都是 none', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginSearchBest best = await src.searchBest('zutomayo');
    expect(best.artist!.name, 'ずっと真夜中でいいのに。');
    expect(best.artist!.aliases, <String>['ZUTOMAYO']);
    expect(best.artist!.coverUrl, 'https://p1.cdn.example.com/z.jpg');
    expect(best.artist!.stats.fanCount, 793789);
    expect(best.playlist!.title, '热门精选');
    expect(best.playlist!.coverUrl, isNull);
    expect(best.album, isNull, reason: '缺 id 的专辑丢弃');
    expect((await src.searchBest('none')).isEmpty, isTrue);
    await m.dispose();

    root.deleteSync(recursive: true);
    root.createSync();
    final (MusicPluginManager m2, MusicPluginSource src2) = await install(
      caps: const <String>['search', 'album'],
    );
    expect((await src2.searchBest('zutomayo')).isEmpty, isTrue);
    await expectLater(
      src2.artistAlbums('1'),
      throwsA(isA<MusicPluginException>()),
    );
    await m2.dispose();
  });
}
