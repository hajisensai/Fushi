// M3U / IPTV 频道列表导入（iptv_playlist_import.dart）：
// - classifyM3uPlaylist：HLS 流不拆、频道列表拆、空列表（远端基址下被拒条目不算）；
// - groupIptvChannels：单分组 = 一个合集，多分组按 group-title 切；
// - importIptvChannels：身份按列表来源——重复导入同一来源对齐自己的合集、频道按完整
//   地址对齐（index.m3u8 撞名 / 地址轮换）、不同来源与用户同名合集互不污染；远端列表
//   只收网络流（UNC / 盘符 / POSIX / file:// 一条都不入库）；
// - fetchRemoteIptvPlaylist：基址 / 列表名推导、非 2xx 抛错、超限边读边停；
// - 台标：同地址只下一次、有上限、可取消，远端列表不打回环 / 私网。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/iptv_playlist_import.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/utils/net/bounded_read.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const String _list = '''
#EXTM3U
#EXTINF:-1 tvg-logo="http://logo/a.png" group-title="News",Ch A
http://iptv.example/a.m3u8
#EXTINF:-1 group-title="Sports",Ch B
rtsp://iptv.example/b
#EXTINF:-1,Ch C
http://iptv.example/c.ts
''';

/// 完整可解码的 1×1 PNG（封面落盘前会校验 IEND）。
final List<int> _png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChw'
    'GA60e6kgAAAABJRU5ErkJggg==');

/// 删行后的资产回收要解析封面目录：给每个用例装一个临时数据根。
void _useTempEnginePaths() {
  late Directory root;
  late EnginePaths previous;
  setUp(() {
    root = Directory.systemTemp.createTempSync('iptv_import_');
    previous = enginePaths;
    enginePaths = FixedEnginePaths(documents: root, support: root, temp: root);
  });
  tearDown(() {
    enginePaths = previous;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });
}

/// 一份远端列表来源（正文由各测试直接给频道，不经下载）。
IptvPlaylistSource _remote(String url, {String? listName}) =>
    IptvPlaylistSource(
      content: '',
      baseDir: iptvPlaylistBaseUrl(url),
      listName: listName ?? iptvPlaylistNameFromLocation(url),
      url: url,
    );

List<M3uChannel> _parse(String content, IptvPlaylistSource source) =>
    parseM3uChannels(content: content, baseDir: source.baseDir);

Future<List<String>> _memberPaths(FushiDatabase db, int collectionId) async {
  final List<String> out = <String>[];
  for (final MediaCollectionItemRow item
      in await db.getCollectionItems(collectionId)) {
    final VideoBookRow? row = await db.getVideoBookByBookUid(item.entryKey);
    if (row != null) out.add(row.videoPath);
  }
  return out;
}

Future<List<MediaCollectionRow>> _playlists(FushiDatabase db) async =>
    (await db.getAllMediaCollections())
        .where((MediaCollectionRow c) => c.collectionType == 'playlist')
        .toList();

void main() {
  // 封面落盘后要经 app 装的钩子驱逐图片缓存（PaintingBinding）。
  TestWidgetsFlutterBinding.ensureInitialized();
  _useTempEnginePaths();

  group('classifyM3uPlaylist', () {
    test('HLS media / master → hlsStream（整份当单条流）', () {
      expect(
        classifyM3uPlaylist(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\ns1.ts\n'),
        M3uPlaylistKind.hlsStream,
      );
      expect(
        classifyM3uPlaylist(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlow.m3u8\n'),
        M3uPlaylistKind.hlsStream,
      );
    });

    test('频道列表 / 空列表', () {
      expect(classifyM3uPlaylist(_list), M3uPlaylistKind.channelList);
      expect(
          classifyM3uPlaylist('#EXTM3U\n# nothing\n'), M3uPlaylistKind.empty);
    });

    test('远端基址下只有本地条目的列表 = 空列表', () {
      const String onlyLocal = '#EXTM3U\n#EXTINF:-1,X\n\\\\evil\\share\\a.mkv\n'
          '#EXTINF:-1,Y\nfile:///etc/passwd\n';
      expect(classifyM3uPlaylist(onlyLocal), M3uPlaylistKind.channelList);
      expect(
        classifyM3uPlaylist(onlyLocal, baseDir: 'https://evil.example/l'),
        M3uPlaylistKind.empty,
      );
    });
  });

  group('groupIptvChannels', () {
    test('只有一个（或没有）分组：整份列表一个合集', () {
      final List<M3uChannel> one = parseM3uChannels(
        content: '#EXTINF:-1 group-title="G",A\nhttp://h/a\n'
            '#EXTINF:-1,B\nhttp://h/b\n',
        baseDir: '',
      );
      final List<IptvChannelGroup> groups = groupIptvChannels(one, 'List');
      expect(groups, hasLength(1));
      expect(groups.single.collectionName, 'List');
      expect(groups.single.channels, hasLength(2));
    });

    test('多个分组：每组一个合集，未分组留在列表名合集，保持首次出现顺序', () {
      final List<IptvChannelGroup> groups = groupIptvChannels(
          parseM3uChannels(content: _list, baseDir: ''), 'TV');
      expect(groups.map((IptvChannelGroup g) => g.collectionName).toList(),
          <String>['TV · News', 'TV · Sports', 'TV']);
      expect(groups.last.channels.single.title, 'Ch C');
    });
  });

  test('列表名与基址推导：通用接口名 / 动态脚本退回 host', () {
    expect(iptvPlaylistNameFromLocation('https://h.example/iptv/jp.m3u?t=1'),
        'jp');
    expect(iptvPlaylistNameFromLocation('https://h.example/'), 'h.example');
    expect(iptvPlaylistNameFromLocation('/home/u/My List.m3u8'), 'My List');
    expect(
      iptvPlaylistNameFromLocation(
          'http://p1.example:8080/get.php?username=u&password=x&type=m3u_plus'),
      'p1.example',
    );
    expect(iptvPlaylistNameFromLocation('https://h.example/tv/index.m3u8'),
        'h.example');
    expect(iptvPlaylistNameFromLocation('https://h.example/playlist.m3u'),
        'h.example');
    expect(iptvPlaylistBaseUrl('https://h.example/iptv/jp.m3u?t=1'),
        'https://h.example/iptv');
    expect(
        iptvPlaylistBaseUrl('https://h.example/list.m3u'), 'https://h.example');
  });

  test('来源 / 频道身份：地址归一、query 保留、fragment 与大小写不影响', () {
    expect(normalizeIptvUrl('HTTP://Example.COM:80/a/b.m3u8?x=1#frag'),
        'http://example.com/a/b.m3u8?x=1');
    final String src = iptvPlaylistSourceKey(url: 'https://h.example/l.m3u');
    expect(iptvChannelBookUid(src, 'http://a/index.m3u8?t=1'),
        isNot(iptvChannelBookUid(src, 'http://a/index.m3u8?t=2')));
    expect(iptvChannelBookUid(src, 'http://a/x#1'),
        iptvChannelBookUid(src, 'HTTP://A/x'));
    final String uid = iptvChannelBookUid(src, 'http://a/x');
    expect(isIptvChannelBookUid(uid), isTrue);
    expect(uid.startsWith(iptvSourceBookUidPrefix(src)), isTrue);
    expect(
      iptvChannelBookUid(
          iptvPlaylistSourceKey(url: 'https://other.example/l.m3u'),
          'http://a/x'),
      isNot(uid),
    );
  });

  test('importIptvChannels：落成流条目 + 合集；重复导入对齐、不出副本', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    final IptvPlaylistSource source =
        _remote('https://iptv.example/lists/tv.m3u', listName: 'TV');
    final List<M3uChannel> channels = _parse(_list, source);

    final IptvPlaylistImportResult first = await importIptvChannels(
      db: db,
      repo: repo,
      source: source,
      channels: channels,
    );
    expect(first.collectionIds, hasLength(3));
    expect(first.channelCount, 3);
    expect(first.firstBookUid, isNotNull);

    final List<VideoBookRow> rows = await repo.listAll();
    expect(rows.map((VideoBookRow r) => r.videoPath).toSet(), <String>{
      'http://iptv.example/a.m3u8',
      'rtsp://iptv.example/b',
      'http://iptv.example/c.ts',
    });
    expect(rows.map((VideoBookRow r) => r.title).toSet(),
        <String>{'Ch A', 'Ch B', 'Ch C'});
    expect(rows.every((VideoBookRow r) => isIptvChannelBookUid(r.bookUid)),
        isTrue);
    expect((await _playlists(db)).map((MediaCollectionRow c) => c.name).toSet(),
        <String>{'TV · News', 'TV · Sports', 'TV'});

    // 再导入一次：同一来源走对齐，行数 / 合集数不变。
    final IptvPlaylistImportResult second = await importIptvChannels(
      db: db,
      repo: repo,
      source: source,
      channels: channels,
    );
    expect(second.collectionIds, first.collectionIds);
    expect(second.firstBookUid, isNull);
    expect(second.removedChannelCount, 0);
    expect(await repo.listAll(), hasLength(3));
    expect(await _playlists(db), hasLength(3));
  });

  group('远端列表只收网络流（阻断 1）', () {
    const String hostile = '#EXTM3U\n'
        '#EXTINF:-1,UNC\n\\\\evil\\share\\a.mkv\n'
        '#EXTINF:-1,UNC slash\n//evil/share/b.mkv\n'
        '#EXTINF:-1,Drive\nC:\\Users\\victim\\c.mkv\n'
        '#EXTINF:-1,Posix\n/data/local/d.mkv\n'
        '#EXTINF:-1,File URL\nfile:///etc/passwd\n'
        '#EXTINF:-1,File UNC\nfile://evil/share/e.mkv\n'
        '#EXTINF:-1,Good\nhttp://ok.example/live.m3u8\n';

    test('解析 + 导入：UNC / 盘符 / POSIX 绝对 / //host/share / file:// 一条都不入库',
        () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final IptvPlaylistSource source =
          _remote('https://evil.example/lists/x.m3u');
      final IptvPlaylistImportResult result = await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: _parse(hostile, source),
      );
      expect(result.channelCount, 1);
      expect((await repo.listAll()).map((VideoBookRow r) => r.videoPath),
          <String>['http://ok.example/live.m3u8']);
    });

    test('导入层兜底：绕过解析层直接喂的本地条目同样拒收', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final List<M3uChannel> injected = <M3uChannel>[
        for (final String url in <String>[
          r'\\evil\share\a.mkv',
          '//evil/share/b.mkv',
          r'C:\Users\victim\c.mkv',
          '/data/local/d.mkv',
          'file:///etc/passwd',
          'file://evil/share/e.mkv',
          'rtsp://ok.example/1',
        ])
          M3uChannel(title: url, url: url),
      ];
      final IptvPlaylistImportResult result = await importIptvChannels(
        db: db,
        repo: repo,
        source: _remote('https://evil.example/lists/x.m3u'),
        channels: injected,
      );
      expect(result.channelCount, 1);
      expect((await repo.listAll()).map((VideoBookRow r) => r.videoPath),
          <String>['rtsp://ok.example/1']);
    });

    test('本地列表：本地相对条目行为不变（解析到列表目录下）', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final String dir = p.join(Directory.systemTemp.path, 'iptv_local_list');
      final IptvPlaylistSource source = IptvPlaylistSource(
        content: '',
        baseDir: dir,
        listName: 'Local',
        localPath: p.join(dir, 'local.m3u'),
      );
      final List<M3uChannel> channels =
          _parse('#EXTINF:-1,Ep\nsub/ep1.mkv\n', source);
      expect(channels.single.url, p.normalize(p.join(dir, 'sub', 'ep1.mkv')));
      await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: channels,
      );
      expect((await repo.listAll()).single.videoPath, channels.single.url);
    });
  });

  group('身份按列表来源（阻断 2）', () {
    test('多个 index.m3u8 基名撞车 + 地址轮换：重导入后频道真更新、旧行删除', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final IptvPlaylistSource source =
          _remote('https://iptv.example/lists/jp.m3u');
      const String v1 = '#EXTM3U\n'
          '#EXTINF:-1,A\nhttp://a.example/ch1/index.m3u8?token=1\n'
          '#EXTINF:-1,B\nhttp://b.example/ch2/index.m3u8?token=1\n'
          '#EXTINF:-1,C\nhttp://c.example/ch3/index.m3u8\n';
      const String v2 = '#EXTM3U\n'
          '#EXTINF:-1,A\nhttp://a.example/ch1/index.m3u8?token=2\n'
          '#EXTINF:-1,B\nhttp://b.example/ch2/index.m3u8?token=2\n'
          '#EXTINF:-1,C\nhttp://c.example/ch3/index.m3u8\n'
          '#EXTINF:-1,D\nhttp://d.example/ch4/index.m3u8\n';

      final IptvPlaylistImportResult first = await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: _parse(v1, source),
      );
      final int collectionId = first.collectionIds.single;
      final String cUid = iptvChannelBookUid(
          source.sourceKey, 'http://c.example/ch3/index.m3u8');
      await repo.updatePosition(cUid, 42000);

      final IptvPlaylistImportResult second = await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: _parse(v2, source),
      );
      expect(second.collectionIds, <int>[collectionId]);
      expect(second.removedChannelCount, 2);
      expect(await _memberPaths(db, collectionId), <String>[
        'http://a.example/ch1/index.m3u8?token=2',
        'http://b.example/ch2/index.m3u8?token=2',
        'http://c.example/ch3/index.m3u8',
        'http://d.example/ch4/index.m3u8',
      ]);
      // 过期地址的旧行整行删除（不留孤儿），没变的频道保留原行与进度。
      final List<VideoBookRow> rows = await repo.listAll();
      expect(rows, hasLength(4));
      expect(rows.map((VideoBookRow r) => r.videoPath),
          isNot(contains('http://a.example/ch1/index.m3u8?token=1')));
      expect((await repo.getByBookUid(cUid))!.lastPositionMs, 42000);
    });

    test('被用户放进别的合集的过期频道：只从列表合集解绑，不删行', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final IptvPlaylistSource source =
          _remote('https://iptv.example/lists/jp.m3u');
      await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: _parse('#EXTINF:-1,A\nhttp://a.example/1?t=1\n', source),
      );
      final String oldUid =
          iptvChannelBookUid(source.sourceKey, 'http://a.example/1?t=1');
      final int mine = await db.createMediaCollection('My favourites');
      await db.addToCollection(mine, MediaKind.video, oldUid);

      await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: _parse('#EXTINF:-1,A\nhttp://a.example/1?t=2\n', source),
      );
      expect(await repo.getByBookUid(oldUid), isNotNull);
      expect(await _memberPaths(db, mine), <String>['http://a.example/1?t=1']);
    });

    test('两个 get.php 列表互不污染（含同一 host 的两个账号）', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final IptvPlaylistSource p1 = _remote(
          'http://p1.example/get.php?username=u1&password=x&type=m3u_plus');
      final IptvPlaylistSource p2 = _remote(
          'http://p2.example/get.php?username=u2&password=y&type=m3u_plus');
      final IptvPlaylistSource p3 = _remote(
          'http://p2.example/get.php?username=u3&password=z&type=m3u_plus');
      expect(<String>{p1.listName, p2.listName},
          <String>{'p1.example', 'p2.example'});
      expect(p3.listName, p2.listName);

      final int c1 = (await importIptvChannels(
        db: db,
        repo: repo,
        source: p1,
        channels: _parse(
            '#EXTINF:-1,X1\nhttp://p1.example/live/u1/x/1.ts\n'
            '#EXTINF:-1,X2\nhttp://p1.example/live/u1/x/2.ts\n',
            p1),
      ))
          .collectionIds
          .single;
      final int c2 = (await importIptvChannels(
        db: db,
        repo: repo,
        source: p2,
        channels:
            _parse('#EXTINF:-1,Y1\nhttp://p2.example/live/u2/y/1.ts\n', p2),
      ))
          .collectionIds
          .single;
      final int c3 = (await importIptvChannels(
        db: db,
        repo: repo,
        source: p3,
        channels:
            _parse('#EXTINF:-1,Z1\nhttp://p2.example/live/u3/z/1.ts\n', p3),
      ))
          .collectionIds
          .single;
      expect(<int>{c1, c2, c3}, hasLength(3));
      expect((await db.getMediaCollectionById(c3))!.name, 'p2.example (2)');

      // 第一家的列表缩水：只动自己的合集。
      await importIptvChannels(
        db: db,
        repo: repo,
        source: p1,
        channels:
            _parse('#EXTINF:-1,X1\nhttp://p1.example/live/u1/x/1.ts\n', p1),
      );
      expect(await _memberPaths(db, c1),
          <String>['http://p1.example/live/u1/x/1.ts']);
      expect(await _memberPaths(db, c2),
          <String>['http://p2.example/live/u2/y/1.ts']);
      expect(await _memberPaths(db, c3),
          <String>['http://p2.example/live/u3/z/1.ts']);
    });

    test('同名普通 playlist 合集不受影响', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final SplitPlaylistImportResult local = await repo.importSplitPlaylist(
        collectionName: 'TV',
        entries: const <PlaylistEntry>[
          PlaylistEntry(title: 'ep1', path: '/videos/ep1.mkv'),
          PlaylistEntry(title: 'ep2', path: '/videos/ep2.mkv'),
        ],
      );
      final IptvPlaylistSource source =
          _remote('https://iptv.example/lists/tv.m3u', listName: 'TV');
      final List<M3uChannel> channels =
          _parse('#EXTINF:-1,Ch\nhttp://iptv.example/ch.m3u8\n', source);

      final IptvPlaylistImportResult first = await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: channels,
      );
      final int iptvId = first.collectionIds.single;
      expect(iptvId, isNot(local.collectionId));
      expect((await db.getMediaCollectionById(iptvId))!.name, 'TV (2)');
      // 再导入（清单变空之外的任何变化）都只动 IPTV 合集。
      await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels:
            _parse('#EXTINF:-1,Ch2\nhttp://iptv.example/ch2.m3u8\n', source),
      );
      expect(await _memberPaths(db, local.collectionId),
          <String>['/videos/ep1.mkv', '/videos/ep2.mkv']);
      expect((await db.getMediaCollectionById(local.collectionId))!.name, 'TV');
      expect(await _memberPaths(db, iptvId),
          <String>['http://iptv.example/ch2.m3u8']);
    });

    test('用户改过合集名：单分组列表仍对齐回同一合集', () async {
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);
      final IptvPlaylistSource source =
          _remote('https://iptv.example/lists/tv.m3u', listName: 'TV');
      final int id = (await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: _parse('#EXTINF:-1,A\nhttp://iptv.example/a\n', source),
      ))
          .collectionIds
          .single;
      await db.renameMediaCollection(id, 'My TV');
      final IptvPlaylistImportResult again = await importIptvChannels(
        db: db,
        repo: repo,
        source: source,
        channels: _parse('#EXTINF:-1,B\nhttp://iptv.example/b\n', source),
      );
      expect(again.collectionIds, <int>[id]);
      expect(await _playlists(db), hasLength(1));
      expect(await _memberPaths(db, id), <String>['http://iptv.example/b']);
    });
  });

  group('fetchRemoteIptvPlaylist', () {
    test('取回正文并推导基址 / 列表名', () async {
      final MockClient client = MockClient((http.Request req) async =>
          http.Response.bytes(
              '#EXTM3U\n#EXTINF:-1,A\nrel/a.m3u8\n'.codeUnits, 200));
      final IptvPlaylistSource src = await fetchRemoteIptvPlaylist(
        'https://h.example/lists/jp.m3u',
        httpClient: client,
      );
      expect(src.listName, 'jp');
      expect(src.url, 'https://h.example/lists/jp.m3u');
      expect(src.isRemote, isTrue);
      final List<M3uChannel> ch =
          parseM3uChannels(content: src.content, baseDir: src.baseDir);
      expect(ch.single.url, 'https://h.example/lists/rel/a.m3u8');
    });

    test('非 2xx 抛 HttpException', () async {
      final MockClient client =
          MockClient((http.Request req) async => http.Response('x', 403));
      await expectLater(
        fetchRemoteIptvPlaylist('https://h.example/a.m3u', httpClient: client),
        throwsA(isA<HttpException>()),
      );
    });

    test('正文超过上限：边读边计数，超限即停并抛 BodyTooLargeException', () async {
      int served = 0;
      const int chunk = 1024 * 1024;
      final MockClient client =
          MockClient.streaming((http.BaseRequest req, _) async {
        final Stream<List<int>> body = Stream<List<int>>.fromIterable(
          Iterable<List<int>>.generate(64, (_) {
            served++;
            return List<int>.filled(chunk, 0x23);
          }),
        );
        return http.StreamedResponse(body, 200);
      });
      await expectLater(
        fetchRemoteIptvPlaylist('https://h.example/huge.m3u',
            httpClient: client),
        throwsA(isA<BodyTooLargeException>()),
      );
      // 上限 16 MiB / 每块 1 MiB：越过上限那一块就停，不会把 64 MiB 读完。
      expect(served, lessThan(64), reason: '超限后应停止读取');
    });
  });

  group('台标', () {
    test('isIptvLogoUrlAllowed：远端列表不打回环 / 私网，本地列表放行', () {
      for (final String url in <String>[
        'http://127.0.0.1:8765/a.png',
        'http://localhost/a.png',
        'http://192.168.1.2/a.png',
        'http://10.0.0.5/a.png',
        'http://[::1]/a.png',
        'http://nas.local/a.png',
      ]) {
        expect(isIptvLogoUrlAllowed(url, remoteSource: true), isFalse,
            reason: url);
        expect(isIptvLogoUrlAllowed(url, remoteSource: false), isTrue,
            reason: url);
      }
      expect(
          isIptvLogoUrlAllowed('https://logo.example/a.png',
              remoteSource: true),
          isTrue);
      expect(
          isIptvLogoUrlAllowed('file:///a.png', remoteSource: false), isFalse);
      expect(isIptvLogoUrlAllowed(null, remoteSource: false), isFalse);
    });

    group('applyIptvChannelLogos', () {
      const String logoList = '#EXTM3U\n'
          '#EXTINF:-1 tvg-logo="https://logo.example/shared.png",A\n'
          'http://iptv.example/a\n'
          '#EXTINF:-1 tvg-logo="https://logo.example/shared.png",B\n'
          'http://iptv.example/b\n'
          '#EXTINF:-1 tvg-logo="https://logo.example/shared.png",C\n'
          'http://iptv.example/c\n'
          '#EXTINF:-1 tvg-logo="http://192.168.1.10/private.png",D\n'
          'http://iptv.example/d\n'
          '#EXTINF:-1 tvg-logo="https://logo.example/other.png",E\n'
          'http://iptv.example/e\n';

      Future<(VideoBookRepository, IptvPlaylistSource, List<M3uChannel>)> seed(
          FushiDatabase db) async {
        final VideoBookRepository repo = VideoBookRepository(db);
        final IptvPlaylistSource source =
            _remote('https://iptv.example/lists/logo.m3u');
        final List<M3uChannel> channels = _parse(logoList, source);
        await importIptvChannels(
            db: db, repo: repo, source: source, channels: channels);
        return (repo, source, channels);
      }

      MockClient pngClient(List<String> seen) =>
          MockClient((http.Request req) async {
            seen.add(req.url.toString());
            return http.Response.bytes(_png1x1, 200,
                headers: <String, String>{'content-type': 'image/png'});
          });

      test('同一地址只下一次、分给所有频道；私网地址不请求', () async {
        final FushiDatabase db =
            FushiDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final (
          VideoBookRepository repo,
          IptvPlaylistSource source,
          List<M3uChannel> channels
        ) = await seed(db);
        final List<String> seen = <String>[];
        final int applied = await applyIptvChannelLogos(
          repo: repo,
          source: source,
          channels: channels,
          httpClient: pngClient(seen),
        );
        expect(seen, <String>[
          'https://logo.example/shared.png',
          'https://logo.example/other.png',
        ]);
        expect(applied, 4);
      });

      test('有上限、可取消', () async {
        final FushiDatabase db =
            FushiDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final (
          VideoBookRepository repo,
          IptvPlaylistSource source,
          List<M3uChannel> channels
        ) = await seed(db);
        final List<String> capped = <String>[];
        await applyIptvChannelLogos(
          repo: repo,
          source: source,
          channels: channels,
          httpClient: pngClient(capped),
          maxDownloads: 1,
        );
        expect(capped, <String>['https://logo.example/shared.png']);

        final List<String> cancelled = <String>[];
        final IptvLogoCancelToken token = beginIptvLogoJob(source.sourceKey);
        // 同一来源再开一路：上一路随即被取消。
        final IptvLogoCancelToken next = beginIptvLogoJob(source.sourceKey);
        expect(token.isCancelled, isTrue);
        next.cancel();
        await applyIptvChannelLogos(
          repo: repo,
          source: source,
          channels: channels,
          httpClient: pngClient(cancelled),
          cancelToken: next,
        );
        expect(cancelled, isEmpty);
        cancelAllIptvLogoJobs();
      });
    });
  });
}
