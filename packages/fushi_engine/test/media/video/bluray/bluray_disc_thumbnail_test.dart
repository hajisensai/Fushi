import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_disc_thumbnail.dart';
import 'package:image/image.dart' as img;
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

Uint8List _jpeg(int width, int height) =>
    img.encodeJpg(img.Image(width: width, height: height));

void main() {
  group('parseBlurayDiscThumbnails', () {
    test('reads every thumbnail href in document order', () {
      expect(
        parseBlurayDiscThumbnails(
          _disclib(
            '<di:thumbnail href="./S.jpg" size="416x240" />'
            '<di:thumbnail href="./L.jpg" size="640x360" />',
          ),
        ).map((BlurayDiscThumbnail t) => t.href),
        <String>['S.jpg', 'L.jpg'],
      );
    });

    test('drops hrefs that leave META/DL', () {
      expect(
        parseBlurayDiscThumbnails(
          _disclib(
            '<di:thumbnail href="../../index.bdmv" />'
            '<di:thumbnail href="/etc/passwd" />'
            '<di:thumbnail href="C:\\Windows\\a.jpg" />'
            '<di:thumbnail href="sub\\..\\..\\x.jpg" />'
            '<di:thumbnail href="art/cover.png" />',
          ),
        ).map((BlurayDiscThumbnail t) => t.href),
        <String>['art/cover.png'],
      );
    });

    test('malformed XML yields nothing', () {
      expect(parseBlurayDiscThumbnails('<disclib><di:thumb'), isEmpty);
    });
  });

  test('UI languages map to the ISO 639-2 forms discs use', () {
    expect(blurayLanguageCodes('zh'), <String>['chi', 'zho']);
    expect(blurayLanguageCodes('ja'), <String>['jpn']);
    expect(blurayLanguageCodes('DE'), <String>['ger', 'deu']);
    expect(blurayLanguageCodes('xx'), isEmpty);
  });

  test('metadata files order by the given languages, then by name', () {
    final List<String> names = <String>[
      'bdmt_fra.xml',
      'bdmt_eng.xml',
      'L.jpg',
      'bdmt_jpn.xml',
      'bdmt_zho.xml',
      'bdmt_jpn.xml.bak',
    ];
    expect(
      orderBlurayDiscMetadataFiles(
        names,
        preferredLanguages: blurayLanguageCodes('zh'),
      ),
      <String>['bdmt_zho.xml', 'bdmt_eng.xml', 'bdmt_fra.xml', 'bdmt_jpn.xml'],
    );
    expect(
      orderBlurayDiscMetadataFiles(names, preferredLanguages: const <String>[]),
      <String>['bdmt_eng.xml', 'bdmt_fra.xml', 'bdmt_jpn.xml', 'bdmt_zho.xml'],
    );
  });

  test('image size comes from the image, not from a declared size', () {
    expect(decodeImageSize(_jpeg(40, 60)), (width: 40, height: 60));
    expect(decodeImageSize(Uint8List.fromList(<int>[9, 8, 7])), isNull);
  });

  group('readBlurayDiscArtwork', () {
    late Directory root;
    late Directory dl;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bd_art_');
      dl = await Directory(
        p.join(root.path, 'BDMV', 'META', 'DL'),
      ).create(recursive: true);
    });

    tearDown(() => root.delete(recursive: true));

    Future<void> write(String name, Object content) async {
      final File file = File(p.join(dl.path, name));
      if (content is String) {
        await file.writeAsString(content);
      } else {
        await file.writeAsBytes(content as List<int>);
      }
    }

    test('returns the UI language\'s images with measured sizes', () async {
      // Declared sizes lie on purpose: the portrait image claims landscape.
      await write('P.jpg', _jpeg(40, 60));
      await write('L.jpg', _jpeg(64, 36));
      await write('E.jpg', _jpeg(32, 18));
      await write(
        'bdmt_eng.xml',
        _disclib('<di:thumbnail href="./E.jpg" size="1920x1080" />'),
      );
      await write(
        'bdmt_jpn.xml',
        _disclib(
          '<di:thumbnail href="./P.jpg" size="640x360" />'
          '<di:thumbnail href="./L.jpg" size="640x360" />',
        ),
      );
      final List<BlurayDiscArtwork> art = await readBlurayDiscArtwork(
        root.path,
        preferredLanguages: blurayLanguageCodes('ja'),
      );
      expect(
        art.map((BlurayDiscArtwork a) => (p.basename(a.path), a.aspect)),
        <(String, double)>[('P.jpg', 40 / 60), ('L.jpg', 64 / 36)],
      );
      final List<BlurayDiscArtwork> english = await readBlurayDiscArtwork(
        root.path,
        preferredLanguages: blurayLanguageCodes('en'),
      );
      expect(english.single.path, p.join(dl.path, 'E.jpg'));
    });

    test(
      'a language whose images are missing or undecodable falls through',
      () async {
        await write('bad.jpg', <int>[1, 2, 3]);
        await write('E.jpg', _jpeg(32, 18));
        await write(
          'bdmt_jpn.xml',
          _disclib(
            '<di:thumbnail href="./gone.jpg" />'
            '<di:thumbnail href="./bad.jpg" />',
          ),
        );
        await write(
          'bdmt_eng.xml',
          _disclib('<di:thumbnail href="./E.jpg" />'),
        );
        final List<BlurayDiscArtwork> art = await readBlurayDiscArtwork(
          root.path,
          preferredLanguages: blurayLanguageCodes('ja'),
        );
        expect(art.single.path, p.join(dl.path, 'E.jpg'));
      },
    );

    test('a disc without META/DL has no artwork', () async {
      await dl.delete(recursive: true);
      expect(
        await readBlurayDiscArtwork(
          root.path,
          preferredLanguages: const <String>[],
        ),
        isEmpty,
      );
    });
  });
}
