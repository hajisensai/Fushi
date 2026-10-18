import 'dart:convert';
import 'dart:isolate';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// AniDB 标题目录 / anime XML 原生解析的绑定层测试（找不到原生库直接失败，不 skip）。
/// 与旧 Dart 实现的逐位对拍向量见 title_score_test.dart 与
/// fushi/test/media/video/metadata/anidb_native_parity_test.dart。
void main() {
  const String sample = '''
<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="1">
    <title type="main" xml:lang="x-jat">Seikai no Monshou</title>
    <title type="official" xml:lang="en">Crest of the Stars</title>
    <title type="syn" xml:lang="en">Crest &amp; Stars</title>
  </anime>
  <anime aid="2"><title type="main" xml:lang="ja">無職転生</title></anime>
</animetitles>
''';

  int build(List<List<int>> chunks) {
    final AniDbCatalogBuilderNative builder = AniDbCatalogBuilderNative();
    try {
      chunks.forEach(builder.add);
      builder.close();
      return builder.finish();
    } finally {
      builder.dispose();
    }
  }

  AniDbCatalogNativeError failure(String xml) {
    try {
      build(<List<int>>[utf8.encode(xml)]);
    } on AniDbCatalogNativeError catch (e) {
      return e;
    }
    fail('expected AniDbCatalogNativeError for $xml');
  }

  test('builds, finds and searches; chunk boundaries do not matter', () {
    final List<int> bytes = utf8.encode(sample);
    for (final int size in <int>[bytes.length, 1, 3, 17]) {
      final AniDbCatalogNative catalog = AniDbCatalogNative.adopt(
        build(<List<int>>[
          for (int i = 0; i < bytes.length; i += size)
            bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
        ]),
      );
      addTearDown(catalog.dispose);
      expect(catalog.animeIds(), <int>[1, 2]);
      final List<AniDbNativeTitle> titles = catalog.find(1)!;
      expect(titles.map((AniDbNativeTitle t) => t.value), <String>[
        'Seikai no Monshou',
        'Crest of the Stars',
        'Crest & Stars',
      ]);
      expect(titles[2].normalized, 'crest stars');
      expect(catalog.find(3), isNull);
      final List<AniDbNativeSearchHit> hits = catalog.search(
        TitleScoreNative.normalize('Crest of the Stars'),
        15,
      );
      expect(hits.single.animeId, 1);
      expect(hits.single.titleIndex, 1);
      expect(hits.single.kind, 0);
      expect(hits.single.similarity, 1.0);
      expect(
        catalog.search(TitleScoreNative.normalize('無職転生 2'), 15).single.kind,
        2,
      );
    }
  });

  test('builder failures carry the original kinds', () {
    expect(
      failure('<!DOCTYPE a><animetitles/>').kind,
      AniDbCatalogNativeError.forbiddenDeclaration,
    );
    expect(failure('<root/>').kind, AniDbCatalogNativeError.unexpectedRoot);
    final AniDbCatalogNativeError mismatch = failure(
      '<animetitles><anime aid="1"></animetitles>',
    );
    expect(mismatch.kind, AniDbCatalogNativeError.invalidXml);
    expect(
      mismatch.detail,
      'XmlTagException: Expected </anime>, but found </animetitles>',
    );
    expect(
      failure('<animetitles><anime aid="1">').detail,
      'XmlTagException: Missing </anime>',
    );
    expect(
      failure('<animetitles/>').kind,
      AniDbCatalogNativeError.noUsableRecords,
    );
    final AniDbCatalogBuilderNative builder = AniDbCatalogBuilderNative();
    addTearDown(builder.dispose);
    expect(
      () => builder.add(<int>[0x3C, 0xC0, 0x80]),
      throwsA(
        isA<AniDbCatalogNativeError>().having(
          (AniDbCatalogNativeError e) => e.kind,
          'kind',
          AniDbCatalogNativeError.invalidData,
        ),
      ),
    );
  });

  test('a catalog built in another isolate is adopted by address', () async {
    final List<int> bytes = utf8.encode(sample);
    final int address = await Isolate.run(() => build(<List<int>>[bytes]));
    final AniDbCatalogNative catalog = AniDbCatalogNative.adopt(address);
    expect(catalog.find(2)!.single.value, '無職転生');
    catalog.dispose();
    expect(catalog.isDisposed, isTrue);
    expect(() => catalog.find(2), throwsStateError);
    catalog.dispose(); // 幂等
  });

  group('anime XML DOM', () {
    test('tree view follows package:xml DOM accessors', () {
      final FfcXmlElement root = parseAniDbAnimeXml(
        '<?xml version="1.0"?><anime id="7" xmlns:foo="http://www.w3.org/XML/1998/namespace">'
        '<titles><title xml:lang="en" type="main">A &amp; <![CDATA[<B>]]></title>'
        '<title foo:lang="de">C</title></titles><x/></anime>',
      );
      expect(root.name, 'anime');
      expect(root.getAttribute('id'), '7');
      final FfcXmlElement titles = root.getElement('titles')!;
      final List<FfcXmlElement> list = titles.findElements('title').toList();
      expect(list.first.innerText, 'A & <B>');
      expect(list.first.getAttribute('xml:lang'), 'en');
      expect(
        list[1].getAttributeNs('lang', 'http://www.w3.org/XML/1998/namespace'),
        'de',
      );
      expect(root.innerText, 'A & <B>C');
      expect(root.getElement('x')!.innerText, '');
      expect(root.getElement('missing'), isNull);
    });

    test('failures report kind and UTF-16 position', () {
      FfcXmlParseError error(String xml) {
        try {
          parseAniDbAnimeXml(xml);
        } on FfcXmlParseError catch (e) {
          return e;
        }
        fail('expected failure for $xml');
      }

      expect(
        error('<!DOCTYPE a><a/>').kind,
        FfcXmlParseError.forbiddenDeclaration,
      );
      final FfcXmlParseError mismatch = error('<a></b>');
      expect(mismatch.kind, FfcXmlParseError.mismatchClosingTag);
      expect(mismatch.position, 3);
      expect((mismatch.expectedName, mismatch.actualName), ('a', 'b'));
      expect(error('<a>').kind, FfcXmlParseError.missingClosingTag);
      expect(error('</a>').kind, FfcXmlParseError.unexpectedClosingTag);
      expect(error('<a/><b/>').message, 'Unexpected root element');
    });
  });
}
