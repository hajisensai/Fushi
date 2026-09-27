// M3U / IPTV 频道列表导入（iptv_playlist_import.dart）：
// - classifyM3uPlaylist：HLS 流不拆、频道列表拆、空列表；
// - groupIptvChannels：单分组 = 一个合集，多分组按 group-title 切；
// - importIptvChannels：复用 importSplitPlaylist 的存储形状，重复导入走对齐不出副本；
// - fetchRemoteIptvPlaylist：基址 / 列表名推导，非 2xx 抛错。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/iptv_playlist_import.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _list = '''
#EXTM3U
#EXTINF:-1 tvg-logo="http://logo/a.png" group-title="News",Ch A
http://iptv.example/a.m3u8
#EXTINF:-1 group-title="Sports",Ch B
rtsp://iptv.example/b
#EXTINF:-1,Ch C
http://iptv.example/c.ts
''';

void main() {
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

  test('列表名与基址推导', () {
    expect(iptvPlaylistNameFromLocation('https://h.example/iptv/jp.m3u?t=1'),
        'jp');
    expect(iptvPlaylistNameFromLocation('https://h.example/'), 'h.example');
    expect(iptvPlaylistNameFromLocation('/home/u/My List.m3u8'), 'My List');
    expect(iptvPlaylistBaseUrl('https://h.example/iptv/jp.m3u?t=1'),
        'https://h.example/iptv');
    expect(
        iptvPlaylistBaseUrl('https://h.example/list.m3u'), 'https://h.example');
  });

  test('importIptvChannels：落成流条目 + 合集；重复导入对齐、不出副本', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final VideoBookRepository repo = VideoBookRepository(db);
    final List<M3uChannel> channels =
        parseM3uChannels(content: _list, baseDir: '');

    final IptvPlaylistImportResult first = await importIptvChannels(
      db: db,
      repo: repo,
      listName: 'TV',
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
    final List<MediaCollectionRow> cols = (await db.getAllMediaCollections())
        .where((MediaCollectionRow c) => c.collectionType == 'playlist')
        .toList();
    expect(cols.map((MediaCollectionRow c) => c.name).toSet(),
        <String>{'TV · News', 'TV · Sports', 'TV'});

    // 再导入一次：同名合集走对齐，行数 / 合集数不变。
    final IptvPlaylistImportResult second = await importIptvChannels(
      db: db,
      repo: repo,
      listName: 'TV',
      channels: channels,
    );
    expect(second.collectionIds.toSet(), first.collectionIds.toSet());
    expect(second.firstBookUid, isNull);
    expect(await repo.listAll(), hasLength(3));
    expect(
      (await db.getAllMediaCollections())
          .where((MediaCollectionRow c) => c.collectionType == 'playlist'),
      hasLength(3),
    );
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
  });
}
