import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/sources/core_audio_discovery_source.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/torrent/torrent_metainfo.dart';

void main() {
  test('catalog 保留全部 Source，按系列分组并复用媒体搜索归一化', () {
    final CoreAudioCatalog catalog = CoreAudioCatalog.parse(_catalogBytes());

    expect(catalog.series, hasLength(2));
    final CoreAudioSeries series = catalog.series.firstWhere(
      (CoreAudioSeries value) => value.title == 'リアデイルの大地にて',
    );
    expect(series.title, 'リアデイルの大地にて');
    expect(series.author, 'Ceez');
    expect(series.volumes.map((CoreAudioVolume value) => value.order), <String>[
      '01',
      '08',
    ]);
    expect(catalog.search('りあでいる'), <CoreAudioSeries>[series]);
    expect(catalog.search('B0CCN9M612'), <CoreAudioSeries>[series]);
    expect(catalog.search('Not downloadable here'), hasLength(1));
  });

  test('文件匹配优先真实文件名和 Audible id，不能匹配时 fail closed', () {
    final CoreAudioSeries series = CoreAudioCatalog.parse(
      _catalogBytes(),
    ).series.single;
    final InspectedTorrentMetainfo metainfo = inspectTorrentMetainfo(
      _torrentBytes(),
    );

    expect(matchCoreAudioTorrentFile(series.volumes[0], metainfo).index, 1);
    expect(matchCoreAudioTorrentFile(series.volumes[1], metainfo).index, 2);
    expect(
      () => matchCoreAudioTorrentFile(
        CoreAudioVolume(
          id: 'B000000000',
          title: '不存在',
          author: 'x',
          series: 'x',
          order: '1',
          myFileName: '',
          originalFileName: '',
          sourceTorrentId: '1616763',
          fileSizeKiB: null,
          coverUrl: null,
          releaseDate: null,
          amazonId: null,
        ),
        metainfo,
      ),
      throwsA(isA<CoreAudioFileMatchException>()),
    );
  });

  test(
    'search → series folder → volumes → lazy Nyaa metainfo selection',
    () async {
      int catalogRequests = 0;
      int torrentRequests = 0;
      final CoreAudioDiscoverySource source = CoreAudioDiscoverySource(
        catalogUri: Uri.parse('https://catalog.test/data.json'),
        nyaaBaseUri: Uri.parse('https://nyaa.test'),
        client: MockClient((http.Request request) async {
          if (request.url.host == 'catalog.test') {
            catalogRequests++;
            return http.Response.bytes(_catalogBytes(), 200);
          }
          if (request.url.path == '/download/1616763.torrent') {
            torrentRequests++;
            return http.Response.bytes(_torrentBytes(), 200);
          }
          return http.Response('not found', 404);
        }),
      );

      final ProviderBatchResult<DiscoveryResultPage> search = await source
          .search(
            const DiscoveryRequest(
              kind: DiscoveryMediaKind.audiobook,
              query: 'Ceez',
            ),
          );
      final DiscoveryFolder folder =
          search.items.single.entries.single as DiscoveryFolder;
      expect(folder.title, 'リアデイルの大地にて');
      expect(folder.note, 'Ceez');
      expect(folder.itemCount, 2);

      final ProviderBatchResult<DiscoveryResultPage> browse = await source
          .browse(
            DiscoveryRequest(
              kind: DiscoveryMediaKind.audiobook,
              path: folder.path,
            ),
          );
      final List<DiscoveryResourceItem> volumes = browse.items.single.entries
          .cast<DiscoveryResourceItem>()
          .toList(growable: false);
      expect(volumes, hasLength(2));
      expect(volumes.first.note, 'TMW Part 1');
      expect(volumes.first.isDownloadable, isTrue);
      expect(volumes.first.payload, isNull, reason: '.torrent 只在点击下载时获取');

      final DiscoverySelectedTorrentPayload payload =
          await source.resolvePayload(volumes.first)
              as DiscoverySelectedTorrentPayload;
      expect(payload.selectedFileIndexes, <int>{1});
      expect(payload.resourceTitle, 'TMW Part 1');
      expect(payload.importAfterDownload, isFalse);
      expect(
        catalogRequests,
        1,
        reason: 'catalog app-lifetime single-flight cache',
      );
      expect(torrentRequests, 1);
      source.close();
    },
  );
}

Uint8List _catalogBytes() => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'B085VWLBM7': <String, Object?>{
        'title': '[1巻] リアデイルの大地にて',
        'author': 'Ceez',
        'series': 'リアデイルの大地にて',
        'order': '01',
        'my_filename': '[01] リアデイルの大地にて [B085VWLBM7].m4b',
        'original_filename': '[1巻] リアデイルの大地にて.m4b',
        'source': '1616763',
        'filesize': '3',
        'cover': 'https://img.test/1.jpg',
        'release_date': '2019-01-30',
        'amazon_id': 'B085VWQN7Y',
      },
      'B0CCN9M612': <String, Object?>{
        'title': 'リアデイルの大地にて8',
        'author': 'Ceez',
        'series': 'リアデイルの大地にて',
        'order': '08',
        'my_filename': '[08] リアデイルの大地にて8 [B0CCN9M612].m4b',
        'original_filename': '[8巻] リアデイルの大地にて8[B0CCN9M612].m4b',
        'source': '2003063',
        'filesize': '5',
      },
      'MEGA_ONLY': <String, Object?>{
        'title': 'Not downloadable here',
        'series': 'Other',
        'source': 'mega',
      },
    }),
  ),
);

Uint8List _torrentBytes() => _bencode(<String, Object?>{
  'announce': 'https://tracker.test/announce',
  'info': <String, Object?>{
    'files': <Object?>[
      <String, Object?>{
        'length': 1024,
        'path': <Object?>['readme.txt'],
      },
      <String, Object?>{
        'length': 3 * 1024,
        'path': <Object?>['[1巻] リアデイルの大地にて.m4b'],
      },
      <String, Object?>{
        'length': 5 * 1024,
        'path': <Object?>[
          '[Ceez] リアデイルの大地にて',
          '[08] リアデイルの大地にて8 [B0CCN9M612].m4b',
        ],
      },
    ],
    'name': 'Audiobook Collection Part 1',
    'piece length': 16384,
    'pieces': Uint8List(20),
  },
});

Uint8List _bencode(Object? value) {
  final BytesBuilder output = BytesBuilder(copy: false);

  void write(Object? current) {
    if (current is int) {
      output.add(utf8.encode('i${current}e'));
    } else if (current is String) {
      final List<int> bytes = utf8.encode(current);
      output
        ..add(utf8.encode('${bytes.length}:'))
        ..add(bytes);
    } else if (current is Uint8List) {
      output
        ..add(utf8.encode('${current.length}:'))
        ..add(current);
    } else if (current is List<Object?>) {
      output.addByte(0x6c);
      for (final Object? child in current) {
        write(child);
      }
      output.addByte(0x65);
    } else if (current is Map<String, Object?>) {
      output.addByte(0x64);
      final List<String> keys = current.keys.toList()..sort();
      for (final String key in keys) {
        write(key);
        write(current[key]);
      }
      output.addByte(0x65);
    } else {
      throw ArgumentError.value(current, 'value');
    }
  }

  write(value);
  return output.takeBytes();
}
