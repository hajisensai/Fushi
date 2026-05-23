import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ReaderHibikiSource custom font helpers', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hibiki_font_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('canonicalizes allowed custom font paths before building CSS',
        () async {
      final fontsDir = Directory(p.join(tempDir.path, 'fonts'));
      await fontsDir.create();
      final fontFile = File(p.join(fontsDir.path, 'font.ttf'));
      await fontFile.writeAsBytes(<int>[0, 1, 0, 0]);
      final rawPath = p.join(fontsDir.path, '..', 'fonts', 'font.ttf');

      final result = ReaderHibikiSource.customFontCssForEntries(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Test Font',
            'path': rawPath,
            'enabled': true,
          },
        ],
        allowedDirectories: <String>[fontsDir.path],
      );

      expect(
        result.fontFaces,
        contains(Uri.encodeComponent(p.canonicalize(fontFile.path))),
      );
      expect(result.fontFaces, isNot(contains('..')));
    });

    test('rejects custom font paths outside the allowed directories', () async {
      final fontsDir = Directory(p.join(tempDir.path, 'fonts'));
      final outsideDir = Directory(p.join(tempDir.path, 'outside'));
      await fontsDir.create();
      await outsideDir.create();
      final outsideFont = File(p.join(outsideDir.path, 'font.ttf'));
      await outsideFont.writeAsBytes(<int>[0, 1, 0, 0]);

      final result = ReaderHibikiSource.customFontCssForEntries(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Outside Font',
            'path': outsideFont.path,
            'enabled': true,
          },
        ],
        allowedDirectories: <String>[fontsDir.path],
      );

      expect(result.fontFamily, isEmpty);
      expect(result.fontFaces, isEmpty);
    });
  });
}
