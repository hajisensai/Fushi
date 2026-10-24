import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/epub/epub_series.dart';
import 'package:fushi_engine/epub/epub_series_backfill.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// n4KC1azJvw：EPUB 按系列放的书被拉平到书架——OPF 里声明的系列以前根本没读。

const String _container = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

String _opf(String meta) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <opf:metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>T</dc:title>
    $meta
  </opf:metadata>
  <opf:manifest>
    <opf:item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
  </opf:manifest>
  <opf:spine><opf:itemref idref="c"/></opf:spine>
</opf:package>
''';

EpubSeries? _parse(String meta) =>
    parseEpubSeries(XmlDocument.parse(_opf(meta)));

void _writeExtracted(String dir, String opf) {
  Directory(p.join(dir, 'META-INF')).createSync(recursive: true);
  Directory(p.join(dir, 'OEBPS')).createSync(recursive: true);
  File(p.join(dir, 'META-INF', 'container.xml')).writeAsStringSync(_container);
  File(p.join(dir, 'OEBPS', 'content.opf')).writeAsStringSync(opf);
  File(p.join(dir, 'OEBPS', 'c.xhtml')).writeAsStringSync(
    '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>x</p></body></html>',
  );
}

void main() {
  group('parseEpubSeries', () {
    test(
      'EPUB 3 belongs-to-collection + collection-type=series + group-position',
      () {
        expect(
          _parse('''
          <opf:meta property="belongs-to-collection" id="c01">ココロコネクト</opf:meta>
          <opf:meta refines="#c01" property="collection-type">series</opf:meta>
          <opf:meta refines="#c01" property="group-position">2</opf:meta>'''),
          const EpubSeries(name: 'ココロコネクト', index: 2),
        );
      },
    );

    test('Calibre calibre:series / series_index（3.0 折成 3，小数保留）', () {
      expect(
        _parse('''
          <opf:meta name="calibre:series" content="くまクマ熊ベアー"/>
          <opf:meta name="calibre:series_index" content="3.0"/>'''),
        const EpubSeries(name: 'くまクマ熊ベアー', index: 3),
      );
      expect(
        _parse('''
          <meta name="calibre:series" content="S"/>
          <meta name="calibre:series_index" content="2.5"/>''')?.index,
        2.5,
      );
    });

    test('标成 series 的 EPUB 3 声明优先于 calibre；set 不算系列；无类型兜底', () {
      expect(
        _parse(
          '''
          <opf:meta name="calibre:series" content="Calibre 名"/>
          <opf:meta property="belongs-to-collection" id="c">正式名</opf:meta>
          <opf:meta refines="#c" property="collection-type">series</opf:meta>''',
        )?.name,
        '正式名',
      );
      expect(
        _parse('''
          <opf:meta property="belongs-to-collection" id="c">電撃文庫</opf:meta>
          <opf:meta refines="#c" property="collection-type">set</opf:meta>'''),
        isNull,
      );
      expect(
        _parse('''
          <opf:meta property="belongs-to-collection" id="c">無類型</opf:meta>'''),
        const EpubSeries(name: '無類型'),
      );
      expect(
        _parse('''
          <opf:meta property="belongs-to-collection" id="c">無類型</opf:meta>
          <opf:meta name="calibre:series" content="Calibre 名"/>''')?.name,
        'Calibre 名',
        reason: '无类型声明的优先级低于 calibre',
      );
      expect(_parse(''), isNull);
    });
  });

  test('sourceMetadata 编解码：没有声明也写类型标记；别的描述符不认', () {
    expect(
      decodeEpubSeriesMetadata(
        encodeEpubSeriesMetadata(const EpubSeries(name: 'A', index: 4)),
      ),
      const EpubSeries(name: 'A', index: 4),
    );
    final String none = encodeEpubSeriesMetadata(null);
    expect(none, contains(kEpubSeriesMetadataType));
    expect(decodeEpubSeriesMetadata(none), isNull);
    expect(decodeEpubSeriesMetadata('{"type":"hibiki-online-manga"}'), isNull);
    expect(decodeEpubSeriesMetadata('not json'), isNull);
    expect(decodeEpubSeriesMetadata(null), isNull);
  });

  group('backfillEpubSeries', () {
    late Directory tmp;
    late FushiDatabase db;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('epub_series_');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    Future<void> insert(
      String key, {
      required String extractDir,
      String format = 'epub',
      String? sourceMetadata,
    }) => db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '$key.epub',
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value<String>(format),
        sourceMetadata: Value<String?>(sourceMetadata),
      ),
    );

    test('只读 sourceMetadata 为空的 EPUB；目录不在跳过；读过即不再读', () async {
      final String series = p.join(tmp.path, 'series');
      _writeExtracted(
        series,
        _opf(
          '<opf:meta name="calibre:series" content="S"/>'
          '<opf:meta name="calibre:series_index" content="2"/>',
        ),
      );
      final String plain = p.join(tmp.path, 'plain');
      _writeExtracted(plain, _opf(''));
      await insert('series', extractDir: series);
      await insert('plain', extractDir: plain);
      await insert('gone', extractDir: p.join(tmp.path, 'missing'));
      await insert(
        'online',
        extractDir: series,
        sourceMetadata: '{"type":"lnreader-online-book"}',
      );
      await insert('manga', extractDir: series, format: 'manga');

      expect(await backfillEpubSeries(db), 2);
      expect(
        decodeEpubSeriesMetadata(
          (await db.getEpubBook('series'))!.sourceMetadata,
        ),
        const EpubSeries(name: 'S', index: 2),
      );
      final String? plainMeta = (await db.getEpubBook('plain'))!.sourceMetadata;
      expect(plainMeta, contains(kEpubSeriesMetadataType));
      expect(decodeEpubSeriesMetadata(plainMeta), isNull);
      expect(
        (await db.getEpubBook('gone'))!.sourceMetadata,
        isNull,
        reason: '目录暂时不在不能记成「读过、没有」',
      );
      expect(
        (await db.getEpubBook('online'))!.sourceMetadata,
        '{"type":"lnreader-online-book"}',
        reason: '别的描述符不覆盖',
      );
      expect((await db.getEpubBook('manga'))!.sourceMetadata, isNull);

      expect(await backfillEpubSeries(db), 0, reason: '每本只读一次');
    });

    test('解析整本时 EpubBook.series 同样带上声明', () {
      final String dir = p.join(tmp.path, 'full');
      _writeExtracted(
        dir,
        _opf(
          '<opf:meta property="belongs-to-collection" id="c">X</opf:meta>'
          '<opf:meta refines="#c" property="group-position">7</opf:meta>',
        ),
      );
      expect(
        EpubParser.parseFromExtracted(dir).series,
        const EpubSeries(name: 'X', index: 7),
      );
    });
  });
}
