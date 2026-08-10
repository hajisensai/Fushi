import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cover_cache.dart';

void main() {
  test('漫画封面跨缓存实例命中磁盘且不重复联网', () async {
    final Directory root =
        await Directory.systemTemp.createTemp('fushi-mihon-cover-cache-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    int fetches = 0;
    Future<Uint8List> fetch() async {
      fetches++;
      return Uint8List.fromList(<int>[1, 2, 3, 4]);
    }

    final MihonCoverCache first = MihonCoverCache(root);
    expect(
      await first.load(
        extensionPackage: 'org.example.raw',
        sourceId: '42',
        url: 'https://example.test/cover.jpg',
        fetch: fetch,
      ),
      <int>[1, 2, 3, 4],
    );

    final MihonCoverCache afterRestart = MihonCoverCache(root);
    expect(
      await afterRestart.load(
        extensionPackage: 'org.example.raw',
        sourceId: '42',
        url: 'https://example.test/cover.jpg',
        fetch: fetch,
      ),
      <int>[1, 2, 3, 4],
    );
    expect(fetches, 1);
  });

  test('扩展、来源或 URL 不同不会错误共用封面', () {
    final String original = mihonCoverCacheKey(
      extensionPackage: 'org.example.raw',
      sourceId: '42',
      url: 'https://example.test/cover.jpg',
    );
    expect(
      mihonCoverCacheKey(
        extensionPackage: 'org.example.other',
        sourceId: '42',
        url: 'https://example.test/cover.jpg',
      ),
      isNot(original),
    );
    expect(
      mihonCoverCacheKey(
        extensionPackage: 'org.example.raw',
        sourceId: '43',
        url: 'https://example.test/cover.jpg',
      ),
      isNot(original),
    );
    expect(
      mihonCoverCacheKey(
        extensionPackage: 'org.example.raw',
        sourceId: '42',
        url: 'https://example.test/new-cover.jpg',
      ),
      isNot(original),
    );
  });
}
