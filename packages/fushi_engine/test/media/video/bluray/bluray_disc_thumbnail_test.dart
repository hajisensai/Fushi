import 'dart:io';

import 'package:fushi_engine/media/video/bluray/bluray_disc_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Same shape as a retail disc's BDMV/META/DL/bdmt_jpn.xml.
String _disclib(String thumbnails) =>
    '\uFEFF<?xml version="1.0" encoding="utf-8"?>\n'
    '<disclib xmlns="urn:BDA:bdmv;disclib">\n'
    '  <di:discinfo xmlns:di="urn:BDA:bdmv;discinfo">\n'
    '    <di:title><di:name>超かぐや姫！</di:name></di:title>\n'
    '    <di:description>$thumbnails</di:description>\n'
    '  </di:discinfo>\n'
    '</disclib>\n';

void main() {
  group('parseBlurayDiscThumbnails', () {
    test('reads href and size of every thumbnail', () {
      final List<BlurayDiscThumbnail> thumbs = parseBlurayDiscThumbnails(
        _disclib(
          '<di:thumbnail href="./S.jpg" size="416x240" />'
          '<di:thumbnail href="./L.jpg" size="640x360" />',
        ),
      );
      expect(thumbs.map((BlurayDiscThumbnail t) => t.href), <String>[
        'S.jpg',
        'L.jpg',
      ]);
      expect(thumbs.last.width, 640);
      expect(thumbs.last.height, 360);
    });

    test('drops hrefs that leave META/DL and keeps unsized entries', () {
      final List<BlurayDiscThumbnail> thumbs = parseBlurayDiscThumbnails(
        _disclib(
          '<di:thumbnail href="../../index.bdmv" size="9x9" />'
          '<di:thumbnail href="/etc/passwd" />'
          '<di:thumbnail href="C:\\Windows\\a.jpg" />'
          '<di:thumbnail href="sub\\..\\..\\x.jpg" />'
          '<di:thumbnail href="art/cover.png" />',
        ),
      );
      expect(thumbs, hasLength(1));
      expect(thumbs.single.href, 'art/cover.png');
      expect(thumbs.single.width, 0);
    });

    test('malformed XML yields nothing', () {
      expect(parseBlurayDiscThumbnails('<disclib><di:thumb'), isEmpty);
    });
  });

  test('metadata files order by preferred language, then name', () {
    expect(
      orderBlurayDiscMetadataFiles(<String>[
        'bdmt_fra.xml',
        'bdmt_eng.xml',
        'L.jpg',
        'bdmt_jpn.xml',
        'bdmt_deu.xml',
        'bdmt_jpn.xml.bak',
      ]),
      <String>['bdmt_jpn.xml', 'bdmt_eng.xml', 'bdmt_deu.xml', 'bdmt_fra.xml'],
    );
  });

  group('findBlurayDiscThumbnail', () {
    late Directory root;
    late Directory dl;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bd_thumb_');
      dl = await Directory(
        p.join(root.path, 'BDMV', 'META', 'DL'),
      ).create(recursive: true);
    });

    tearDown(() => root.delete(recursive: true));

    test(
      'picks the largest existing thumbnail of the preferred language',
      () async {
        await File(p.join(dl.path, 'S.jpg')).writeAsBytes(<int>[1]);
        await File(p.join(dl.path, 'L.jpg')).writeAsBytes(<int>[1]);
        await File(p.join(dl.path, 'E.jpg')).writeAsBytes(<int>[1]);
        await File(p.join(dl.path, 'bdmt_eng.xml')).writeAsString(
          _disclib('<di:thumbnail href="./E.jpg" size="1920x1080" />'),
        );
        await File(p.join(dl.path, 'bdmt_jpn.xml')).writeAsString(
          _disclib(
            '<di:thumbnail href="./S.jpg" size="416x240" />'
            '<di:thumbnail href="./L.jpg" size="640x360" />',
          ),
        );
        expect(
          await findBlurayDiscThumbnail(root.path),
          p.join(dl.path, 'L.jpg'),
        );
      },
    );

    test(
      'falls through to another language when the files are missing',
      () async {
        await File(p.join(dl.path, 'E.jpg')).writeAsBytes(<int>[1]);
        await File(p.join(dl.path, 'bdmt_jpn.xml')).writeAsString(
          _disclib('<di:thumbnail href="./gone.jpg" size="640x360" />'),
        );
        await File(p.join(dl.path, 'bdmt_eng.xml')).writeAsString(
          _disclib('<di:thumbnail href="./E.jpg" size="640x360" />'),
        );
        expect(
          await findBlurayDiscThumbnail(root.path),
          p.join(dl.path, 'E.jpg'),
        );
      },
    );

    test('a disc without META/DL has no thumbnail', () async {
      await dl.delete(recursive: true);
      expect(await findBlurayDiscThumbnail(root.path), isNull);
    });
  });
}
