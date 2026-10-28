import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_disc_artwork.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Same shape as a retail disc's BDMV/META/DL/bdmt_jpn.xml.
String _disclib(String images) =>
    '\uFEFF<?xml version="1.0" encoding="utf-8"?>\n'
    '<disclib xmlns="urn:BDA:bdmv;disclib">\n'
    '  <di:discinfo xmlns:di="urn:BDA:bdmv;discinfo">\n'
    '    <di:title><di:name>超かぐや姫！</di:name></di:title>\n'
    '    <di:description>$images</di:description>\n'
    '  </di:discinfo>\n'
    '</disclib>\n';

Uint8List _jpeg(int width, int height) =>
    img.encodeJpg(img.Image(width: width, height: height));

void main() {
  group('parseBlurayDiscArtworkRefs', () {
    test('reads every declared image href in document order', () {
      expect(
        parseBlurayDiscArtworkRefs(
          _disclib(
            '<di:thumbnail href="./S.jpg" size="416x240" />'
            '<di:thumbnail href="./L.jpg" size="640x360" />',
          ),
        ).map((BlurayDiscArtworkRef t) => t.href),
        <String>['S.jpg', 'L.jpg'],
      );
    });

    test('drops hrefs that leave META/DL', () {
      expect(
        parseBlurayDiscArtworkRefs(
          _disclib(
            '<di:thumbnail href="../../index.bdmv" />'
            '<di:thumbnail href="/etc/passwd" />'
            '<di:thumbnail href="C:\\Windows\\a.jpg" />'
            '<di:thumbnail href="sub\\..\\..\\x.jpg" />'
            '<di:thumbnail href="art/cover.png" />',
          ),
        ).map((BlurayDiscArtworkRef t) => t.href),
        <String>['art/cover.png'],
      );
    });

    test('malformed XML yields nothing', () {
      expect(parseBlurayDiscArtworkRefs('<disclib><di:thumb'), isEmpty);
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

  test('metadata file names match case-insensitively', () {
    expect(
      orderBlurayDiscMetadataFiles(<String>[
        'BDMT_JPN.XML',
        'bdmt_eng.xml',
        'Bdmt_x.xml',
      ], preferredLanguages: blurayLanguageCodes('ja')),
      <String>['BDMT_JPN.XML', 'bdmt_eng.xml'],
    );
  });

  group('readImageHeaderSize', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('bd_hdr_'));
    tearDown(() => dir.delete(recursive: true));

    Future<({int width, int height})?> sizeOf(List<int> bytes) {
      final File file = File(p.join(dir.path, 'x.img'))
        ..writeAsBytesSync(bytes);
      return readImageHeaderSize(file);
    }

    test(
      'JPEG and PNG sizes come from the header, not a declared size',
      () async {
        expect(await sizeOf(_jpeg(40, 60)), (width: 40, height: 60));
        expect(await sizeOf(img.encodePng(img.Image(width: 64, height: 36))), (
          width: 64,
          height: 36,
        ));
        expect(
          await sizeOf(
            img.encodeJpg(img.Image(width: 9, height: 5), quality: 10),
          ),
          (width: 9, height: 5),
        );
      },
    );

    test('SOF behind APPn segments larger than the read window', () async {
      final Uint8List jpeg = _jpeg(30, 20);
      // SOI, then two ~51 KB APP1 segments (an embedded EXIF preview / ICC
      // profile does this; one segment's length is 16-bit), then the rest of
      // the original stream: the SOF sits past the first 64 KB.
      final BytesBuilder b = BytesBuilder()..add(<int>[0xFF, 0xD8]);
      for (int i = 0; i < 2; i++) {
        b
          ..add(<int>[0xFF, 0xE1, 0xC8, 0x02])
          ..add(Uint8List(0xC800));
      }
      b.add(jpeg.sublist(2));
      final Uint8List bytes = b.takeBytes();
      expect(bytes.length, greaterThan(64 * 1024));
      expect(await sizeOf(bytes), (width: 30, height: 20));
    });

    test('not an image / truncated header → null', () async {
      expect(await sizeOf(<int>[9, 8, 7]), isNull);
      expect(await sizeOf(_jpeg(40, 60).sublist(0, 20)), isNull);
      expect(await sizeOf(<int>[0xFF, 0xD8, 0xFF, 0xDA, 0, 2]), isNull);
      expect(
        await readImageHeaderSize(File(p.join(dir.path, 'missing.jpg'))),
        isNull,
      );
    });
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
