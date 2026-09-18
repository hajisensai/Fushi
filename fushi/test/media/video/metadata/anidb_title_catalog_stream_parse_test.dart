import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/metadata/anidb_title_catalog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-2577：AniDB 标题包改为后台 isolate 流式解析后，行为面必须与原 DOM 版
/// 一致——本文件钉住流式状态机在原版没被测到的分支：实体 / CDATA 解码、
/// 自闭合元素、DOCTYPE 拒收、非法根元素、压缩体原样落盘 + 旧版明文缓存兼容。
void main() {
  group('AniDbTitleCatalog streaming parse (BUG-2577)', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('fushi-anidb-stream-');
    });

    tearDown(() => directory.delete(recursive: true));

    AniDbTitleCatalog catalogFor(String xml, {bool gzipBody = true}) {
      final List<int> body =
          gzipBody ? gzip.encode(utf8.encode(xml)) : utf8.encode(xml);
      return AniDbTitleCatalog(
        cacheDirectory: directory,
        sourceUrl: Uri.parse('https://example.test/anime-titles.xml.gz'),
        now: () => DateTime.utc(2026, 9, 18, 12),
        client: MockClient(
          (http.Request request) async => http.Response.bytes(body, 200),
        ),
      );
    }

    test('decodes entities and CDATA inside titles like the DOM parser did',
        () async {
      final AniDbTitleCatalog catalog = catalogFor('''
<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="7">
    <title type="main" xml:lang="x-jat">Tom &amp; Jerry</title>
    <title type="official" xml:lang="ja"><![CDATA[トム<と>ジェリー]]></title>
    <title type="short" xml:lang="en"/>
  </anime>
</animetitles>
''');
      addTearDown(catalog.close);

      final AniDbTitleRecord? record = await catalog.findByAnimeId(7);
      expect(record, isNotNull);
      expect(
        record!.titles.map((AniDbTitle title) => title.value),
        <String>['Tom & Jerry', 'トム<と>ジェリー'],
        reason: '实体要解码、CDATA 原样保留、自闭合空标题跳过',
      );
      final List<AniDbTitleSearchResult> hit = await catalog.search(
        'Tom & Jerry',
      );
      expect(hit.single.kind, AniDbTitleMatchKind.exact);
    });

    test('self-closing elements do not desync the element stack', () async {
      // 自闭合只有 start 事件：若不先入栈就 _end，弹掉的是父级，
      // 之后的所有标题与作品会被静默丢掉（解析器等价性断裂、且不报错）。
      final AniDbTitleCatalog catalog = catalogFor('''
<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="1">
    <title type="short" xml:lang="en"/>
    <title type="main" xml:lang="x-jat">First</title>
  </anime>
  <anime aid="2"/>
  <anime aid="3">
    <title type="main" xml:lang="x-jat">Third</title>
  </anime>
</animetitles>
''');
      addTearDown(catalog.close);

      final AniDbTitleRecord? first = await catalog.findByAnimeId(1);
      final AniDbTitleRecord? third = await catalog.findByAnimeId(3);
      expect(
        first?.titles.map((AniDbTitle title) => title.value),
        <String>['First'],
        reason: '自闭合空标题之后同一作品的标题不能丢',
      );
      expect(
        third?.titles.map((AniDbTitle title) => title.value),
        <String>['Third'],
        reason: '自闭合 <anime/> 之后的作品不能丢',
      );
      expect(await catalog.findByAnimeId(2), isNull);
    });

    test('rejects DOCTYPE declarations before building any record', () async {
      final AniDbTitleCatalog catalog = catalogFor('''
<?xml version="1.0"?>
<!DOCTYPE animetitles [ <!ENTITY x "y"> ]>
<animetitles><anime aid="1"><title type="main" xml:lang="en">A</title></anime></animetitles>
''');
      addTearDown(catalog.close);

      await expectLater(
        catalog.search('A'),
        throwsA(
          isA<AniDbTitleCatalogException>().having(
            (AniDbTitleCatalogException e) => e.message,
            'message',
            contains('forbidden declaration'),
          ),
        ),
      );
    });

    test('rejects an unexpected root element', () async {
      final AniDbTitleCatalog catalog = catalogFor(
        '<titles><anime aid="1"><title type="main" xml:lang="en">A</title></anime></titles>',
      );
      addTearDown(catalog.close);

      await expectLater(
        catalog.search('A'),
        throwsA(
          isA<AniDbTitleCatalogException>().having(
            (AniDbTitleCatalogException e) => e.message,
            'message',
            contains('unexpected root element'),
          ),
        ),
      );
    });

    test('reports malformed XML as a catalog exception with a string cause',
        () async {
      final AniDbTitleCatalog catalog = catalogFor(
        '<animetitles><anime aid="1"><title type="main" xml:lang="en">A</anime></animetitles>',
      );
      addTearDown(catalog.close);

      await expectLater(
        catalog.search('A'),
        throwsA(
          isA<AniDbTitleCatalogException>()
              .having(
                (AniDbTitleCatalogException e) => e.message,
                'message',
                contains('invalid XML'),
              )
              .having(
                (AniDbTitleCatalogException e) => e.cause,
                'cause',
                isA<String>(),
              ),
        ),
      );
    });

    test('stores the compressed download as-is and reloads it from disk',
        () async {
      const String xml = '''
<animetitles>
  <anime aid="3"><title type="main" xml:lang="x-jat">Violet Evergarden</title></anime>
</animetitles>
''';
      final AniDbTitleCatalog first = catalogFor(xml);
      expect((await first.search('Violet Evergarden')).single.record.animeId, 3);
      first.close();

      final File cacheFile = File(
        '${directory.path}${Platform.pathSeparator}'
        '${AniDbTitleCatalog.cacheFileName}',
      );
      final List<int> onDisk = await cacheFile.readAsBytes();
      expect(onDisk.length, greaterThan(2));
      expect(
        <int>[onDisk[0], onDisk[1]],
        <int>[0x1f, 0x8b],
        reason: '缓存落的是下载到的 gzip 体，不再展开成几十 MB 明文写进手机',
      );

      // 第二个实例：网络必须不被碰，全靠缓存。
      final AniDbTitleCatalog reopened = AniDbTitleCatalog(
        cacheDirectory: directory,
        sourceUrl: Uri.parse('https://example.test/anime-titles.xml.gz'),
        now: () => DateTime.utc(2026, 9, 18, 13),
        client: MockClient(
          (http.Request request) async => throw StateError('no network'),
        ),
      );
      addTearDown(reopened.close);
      expect(
        (await reopened.search('Violet Evergarden')).single.record.animeId,
        3,
      );
    });

    test('still loads a legacy plain-XML cache written by older builds',
        () async {
      final File cacheFile = File(
        '${directory.path}${Platform.pathSeparator}'
        '${AniDbTitleCatalog.cacheFileName}',
      );
      await cacheFile.writeAsString('''
﻿<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="9"><title type="main" xml:lang="x-jat">Sousou no Frieren</title></anime>
</animetitles>
''');
      await cacheFile.setLastModified(DateTime.utc(2026, 9, 18, 11));

      final AniDbTitleCatalog catalog = AniDbTitleCatalog(
        cacheDirectory: directory,
        sourceUrl: Uri.parse('https://example.test/anime-titles.xml.gz'),
        now: () => DateTime.utc(2026, 9, 18, 12),
        client: MockClient(
          (http.Request request) async => throw StateError('no network'),
        ),
      );
      addTearDown(catalog.close);

      final List<AniDbTitleSearchResult> hit = await catalog.search(
        'Sousou no Frieren',
      );
      expect(hit.single.record.animeId, 9);
      expect(hit.single.kind, AniDbTitleMatchKind.exact);
    });

    test('kanji queries still reach the fuzzy branch and rank by similarity',
        () async {
      final AniDbTitleCatalog catalog = catalogFor('''
<animetitles>
  <anime aid="1"><title type="main" xml:lang="ja">無職転生 異世界行ったら本気だす</title></anime>
  <anime aid="2"><title type="main" xml:lang="ja">葬送のフリーレン</title></anime>
</animetitles>
''');
      addTearDown(catalog.close);

      final List<AniDbTitleSearchResult> results = await catalog.search(
        '無職転生 第二期',
      );
      expect(results, isNotEmpty);
      expect(results.first.record.animeId, 1);
      expect(results.first.kind, AniDbTitleMatchKind.similar);
    });
  });
}
