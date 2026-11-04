import 'dart:convert';
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

/// 编辑歌单 / 电台 / 相似艺人 / 收藏（`playlistEdit` / `radio` / `artistSimilar` / `collect`）
/// 与 `editable` / `collected` 字段的契约（docs/specs/2026-10-28-music-plugins.md §4）：参数原样
/// 下发、返回值解析、坏项丢弃与截断、插件抛错转成 [MusicPluginException]、未声明能力拒调。
///
/// 无返回值的调用把收到的参数记进 storage，测试经 `playlist({id: '__log'})` 读回来核对。
const String editJs = r'''
const ok = 'https://p1.cdn.example.com/';
const evil = 'https://evil.com/';
async function log(cap, a) {
  const all = JSON.parse((await fushi.storage.get('log')) || '[]');
  all.push({ cap, a });
  await fushi.storage.set('log', JSON.stringify(all));
}
module.exports = {
  search() { return { items: [], hasMore: false }; },
  async account() { return { loggedIn: true }; },
  async login() { return { state: 'done' }; },
  album(a) {
    return { album: { id: a.id, title: 'A', collected: a.id === 'yes' ? true : 'yes' }, tracks: [] };
  },
  async playlist(a) {
    if (a.id === '__log') {
      return { playlist: { id: 'log', title: (await fushi.storage.get('log')) || '[]' }, tracks: [] };
    }
    return { playlist: { id: a.id, title: 'P', editable: a.id === 'mine', collected: a.id === 'mine' ? false : 1 },
             tracks: [] };
  },
  artist(a) { return { artist: { id: a.id, name: 'N', collected: true }, tracks: [] }; },
  stream(a) { return { url: 'https://api.example.com/' + a.id + '.mp3' }; },
  async playlistEdit(a) {
    if (a.op === 'create') {
      if (a.name === 'broken') return { list: {} };
      await log('create', a);
      return { playlist: { id: 'new1', title: a.name, coverUrl: evil + 'c.jpg', editable: true } };
    }
    if (a.playlistId === 'locked') throw new Error('这个歌单不能编辑');
    await log('edit', a);
    return null;
  },
  async radio(a) {
    if (a.op === 'trash') { await log('trash', a); return null; }
    if (a.seedTrackId === 'broken') return { items: [] };
    if (a.seedTrackId === 'empty') return { tracks: [] };
    await log('next', a);
    const tracks = [{ title: 'no id' }, 'junk'];
    for (let i = 0; i < 130; i++) {
      tracks.push({ id: 't' + i, title: 'T' + i, coverUrl: (i % 2 ? evil : ok) + i + '.jpg' });
    }
    return { tracks, title: a.seedTrackId ? '  心动模式  ' : '私人 FM' };
  },
  artistSimilar(a) {
    if (a.id === 'broken') return { artists: [] };
    const items = [{ name: 'no id' }, { id: 'x' }];
    for (let i = 0; i < 70; i++) {
      items.push({ id: 's' + i, name: 'S' + i, coverUrl: (i ? evil : ok) + i + '.jpg' });
    }
    return { items };
  },
  async collect(a) {
    if (a.id === 'nope') throw new Error('请先登录');
    await log('collect', a);
    return null;
  },
};
''';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-edit-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MusicPluginManager newManager() => MusicPluginManager(
    rootDir: root,
    vaultKey: testVaultKey,
    httpClientFactory: HttpClient.new,
    resolver: fakePublicResolve,
    mediaProbe: noRedirectProbe,
    log: (_, _, _) {},
  );

  Future<(MusicPluginManager, MusicPluginSource)> install({
    List<String> caps = const <String>[
      'search',
      'login',
      'account',
      'album',
      'playlist',
      'playlistEdit',
      'stream',
      'radio',
      'artist',
      'artistSimilar',
      'collect',
    ],
  }) async {
    final MusicPluginManager m = newManager();
    final Uint8List zip = buildPlugin(
      manifest(
        caps: caps,
        perms: const <String>['network', 'storage', 'credentials'],
      ),
      <String, String>{'main.js': editJs},
    );
    final MusicPluginPackageInfo info = await m.inspect(zip);
    await m.install(zip, info.digest);
    return (m, m.source('moe.test.fake'));
  }

  /// 插件记下的调用参数（按调用顺序），读完清空。
  Future<List<Map<String, Object?>>> drainLog(MusicPluginSource src) async {
    final String raw = (await src.playlist('__log')).playlist.title;
    final List<Map<String, Object?>> out = <Map<String, Object?>>[
      for (final Object? e in jsonDecode(raw) as List<Object?>)
        (e! as Map<String, Object?>),
    ];
    return out;
  }

  test('playlistEdit：create 返回新歌单（封面越权清空、editable），增删改参数原样下发', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginPlaylist p = await src.createPlaylist(
      '新歌单',
      description: '说明',
      trackIds: const <String>['1', '2'],
    );
    expect(p.id, 'new1');
    expect(p.title, '新歌单');
    expect(p.editable, isTrue);
    expect(p.coverUrl, isNull, reason: '封面不在网络授权内');
    await src.createPlaylist('无歌');
    await src.addToPlaylist('mine', const <String>['3']);
    await src.removeFromPlaylist('mine', const <String>['1', '3']);
    await src.deletePlaylist('mine');
    expect(await drainLog(src), <Map<String, Object?>>[
      <String, Object?>{
        'cap': 'create',
        'a': <String, Object?>{
          'op': 'create',
          'name': '新歌单',
          'description': '说明',
          'trackIds': <Object?>['1', '2'],
        },
      },
      <String, Object?>{
        'cap': 'create',
        'a': <String, Object?>{'op': 'create', 'name': '无歌'},
      },
      <String, Object?>{
        'cap': 'edit',
        'a': <String, Object?>{
          'op': 'add',
          'playlistId': 'mine',
          'trackIds': <Object?>['3'],
        },
      },
      <String, Object?>{
        'cap': 'edit',
        'a': <String, Object?>{
          'op': 'remove',
          'playlistId': 'mine',
          'trackIds': <Object?>['1', '3'],
        },
      },
      <String, Object?>{
        'cap': 'edit',
        'a': <String, Object?>{'op': 'delete', 'playlistId': 'mine'},
      },
    ]);
    await expectLater(
      src.createPlaylist('broken'),
      throwsA(isA<MusicPluginException>()),
      reason: 'create 返回值缺 playlist',
    );
    await expectLater(
      src.addToPlaylist('locked', const <String>['1']),
      throwsA(
        isA<MusicPluginException>().having(
          (MusicPluginException e) => e.message,
          'message',
          contains('这个歌单不能编辑'),
        ),
      ),
    );
    await m.dispose();
  });

  test('radio：next 截断到 100 首、坏项丢弃、封面核对、标题修剪；空批；trash 下发 id', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginRadioBatch fm = await src.radioNext();
    expect(fm.title, '私人 FM');
    expect(fm.tracks, hasLength(MusicPluginRadioBatch.maxTracks));
    expect(fm.tracks.first.id, 't0');
    expect(fm.tracks.first.coverUrl, 'https://p1.cdn.example.com/0.jpg');
    expect(fm.tracks[1].coverUrl, isNull, reason: '越权封面清空');
    final MusicPluginRadioBatch seeded = await src.radioNext(
      seedTrackId: 's1',
      count: 20,
    );
    expect(seeded.title, '心动模式');
    final MusicPluginRadioBatch empty = await src.radioNext(
      seedTrackId: 'empty',
    );
    expect(empty.tracks, isEmpty);
    expect(empty.title, isNull);
    await expectLater(
      src.radioNext(seedTrackId: 'broken'),
      throwsA(isA<MusicPluginException>()),
      reason: '返回值缺 tracks',
    );
    await src.radioTrash('t5');
    expect(await drainLog(src), <Map<String, Object?>>[
      <String, Object?>{
        'cap': 'next',
        'a': <String, Object?>{'op': 'next'},
      },
      <String, Object?>{
        'cap': 'next',
        'a': <String, Object?>{'op': 'next', 'seedTrackId': 's1', 'count': 20},
      },
      <String, Object?>{
        'cap': 'trash',
        'a': <String, Object?>{'op': 'trash', 'id': 't5'},
      },
    ]);
    await m.dispose();
  });

  test('artistSimilar：最多 50 位、坏项丢弃、封面核对；缺 items 抛错', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final List<MusicPluginArtist> list = await src.similarArtists('a1');
    expect(list, hasLength(MusicPluginSource.maxSimilarArtists));
    expect(list.first.id, 's0');
    expect(list.first.coverUrl, 'https://p1.cdn.example.com/0.jpg');
    expect(list[1].coverUrl, isNull);
    await expectLater(
      src.similarArtists('broken'),
      throwsA(isA<MusicPluginException>()),
    );
    await m.dispose();
  });

  test('collect：三种对象的收藏 / 取消参数原样下发，插件抛错转成异常', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    await src.setCollected(MusicPluginCollectType.playlist, 'p1', on: true);
    await src.setCollected(MusicPluginCollectType.album, 'al1', on: false);
    await src.setCollected(MusicPluginCollectType.artist, 'ar1', on: true);
    expect(await drainLog(src), <Map<String, Object?>>[
      for (final (String type, String id, bool on) in <(String, String, bool)>[
        ('playlist', 'p1', true),
        ('album', 'al1', false),
        ('artist', 'ar1', true),
      ])
        <String, Object?>{
          'cap': 'collect',
          'a': <String, Object?>{'op': 'set', 'type': type, 'id': id, 'on': on},
        },
    ]);
    await expectLater(
      src.setCollected(MusicPluginCollectType.artist, 'nope', on: true),
      throwsA(
        isA<MusicPluginException>().having(
          (MusicPluginException e) => e.message,
          'message',
          contains('请先登录'),
        ),
      ),
    );
    await m.dispose();
  });

  test(
    'editable / collected：bool 才认，缺省 editable=false、collected=null',
    () async {
      final (MusicPluginManager m, MusicPluginSource src) = await install();
      final MusicPluginPlaylist mine = (await src.playlist('mine')).playlist;
      expect(mine.editable, isTrue);
      expect(mine.collected, isFalse);
      final MusicPluginPlaylist other = (await src.playlist('other')).playlist;
      expect(other.editable, isFalse);
      expect(other.collected, isNull, reason: '非 bool 当缺失');
      expect((await src.album('yes')).album.collected, isTrue);
      expect((await src.album('no')).album.collected, isNull);
      expect((await src.artist('a')).artist.collected, isTrue);
      // 复制方法保留字段。
      expect(mine.withCover(null).editable, isTrue);
      expect(mine.withCover(null).collected, isFalse);
      expect(
        const MusicPluginAlbum(
          id: 'a',
          title: 'A',
          collected: true,
        ).withCover(null).collected,
        isTrue,
      );
      expect(
        const MusicPluginArtist(
          id: 'a',
          name: 'A',
          collected: false,
        ).withCover(null).collected,
        isFalse,
      );
      expect(
        MusicPluginPlaylist.fromJson(<String, Object?>{
          'id': 'x',
          'title': 'X',
        })!.editable,
        isFalse,
      );
      await m.dispose();
    },
  );

  test('未声明的新能力：调用一律抛 MusicPluginException', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install(
      caps: const <String>['search', 'album', 'stream', 'lyrics'],
    );
    for (final Future<Object?> Function() call in <Future<Object?> Function()>[
      () => src.createPlaylist('x'),
      () => src.addToPlaylist('p', const <String>['1']),
      () => src.removeFromPlaylist('p', const <String>['1']),
      () => src.deletePlaylist('p'),
      () => src.radioNext(),
      () => src.radioTrash('1'),
      () => src.similarArtists('a'),
      () => src.setCollected(MusicPluginCollectType.album, 'a', on: true),
    ]) {
      await expectLater(call(), throwsA(isA<MusicPluginException>()));
    }
    await m.dispose();
  });

  test('新能力缺依赖拒装', () async {
    for (final List<String> caps in <List<String>>[
      <String>['search', 'login', 'account', 'playlistEdit'],
      <String>['search', 'playlist', 'playlistEdit'],
      <String>['search', 'radio'],
      <String>['search', 'artistSimilar'],
      <String>['search', 'collect'],
    ]) {
      final MusicPluginManager m = newManager();
      final Uint8List zip = buildPlugin(
        manifest(
          caps: caps,
          perms: const <String>['network', 'storage', 'credentials'],
        ),
        <String, String>{'main.js': editJs},
      );
      await expectLater(
        m.inspect(zip),
        throwsA(isA<MusicPluginException>()),
        reason: '$caps',
      );
      await m.dispose();
    }
  });
}
