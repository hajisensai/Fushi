import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/dictionary_font_css.dart';

/// TODO-049: the dictionary popup is an isolated WebView with no font-file
/// serving and (on Windows) an about:blank origin. These tests pin the two
/// zero-cross-platform injection paths: system family names become a plain CSS
/// `font-family`, and imported files are inlined as base64 `data:` URL
/// `@font-face` declarations (gated by the allowed-directory whitelist).
Map<String, dynamic> _e(String name, {String? path, bool enabled = true}) =>
    <String, dynamic>{'name': name, 'path': path, 'enabled': enabled};

void main() {
  test('system font (no path) yields a font-family, no @font-face', () {
    final result = DictionaryFontCss.build(<Map<String, dynamic>>[
      _e('Noto Sans JP'),
    ]);
    expect(result.fontFamily, '"Noto Sans JP"');
    expect(result.fontFaces, isEmpty);
  });

  test('disabled entries are skipped', () {
    final result = DictionaryFontCss.build(<Map<String, dynamic>>[
      _e('Disabled Font', enabled: false),
      _e('Active Font'),
    ]);
    expect(result.fontFamily, '"Active Font"');
  });

  test('empty/whitespace names are skipped, empty input → empty CSS', () {
    expect(DictionaryFontCss.build(const <Map<String, dynamic>>[]).fontFamily,
        isEmpty);
    final result = DictionaryFontCss.build(<Map<String, dynamic>>[
      _e('   '),
      _e('Good'),
    ]);
    expect(result.fontFamily, '"Good"');
  });

  test('imported file inside the allowed dir → base64 data: @font-face',
      () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_dictfont');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File fontFile = File('${dir.path}/MyFont.ttf');
    await fontFile.writeAsBytes(<int>[0x00, 0x01, 0x02, 0x03]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('MyFont', path: fontFile.path)],
      allowedDirectories: <String>[dir.path],
    );

    expect(result.fontFamily, '"MyFont"');
    expect(result.fontFaces, contains('@font-face'));
    expect(result.fontFaces, contains('data:font/ttf;base64,'));
    expect(result.fontFaces, contains('format("truetype")'));
    // The four bytes 00 01 02 03 encode to "AAECAw==".
    expect(result.fontFaces, contains('AAECAw=='));
  });

  test('file outside the allowed dir is rejected (no inlining)', () async {
    final Directory allowed =
        await Directory.systemTemp.createTemp('hibiki_allowed');
    final Directory other =
        await Directory.systemTemp.createTemp('hibiki_other');
    addTearDown(() async {
      if (allowed.existsSync()) await allowed.delete(recursive: true);
      if (other.existsSync()) await other.delete(recursive: true);
    });
    final File outside = File('${other.path}/Evil.ttf');
    await outside.writeAsBytes(<int>[0x00, 0x01]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Evil', path: outside.path)],
      allowedDirectories: <String>[allowed.path],
    );

    expect(result.fontFamily, isEmpty);
    expect(result.fontFaces, isEmpty);
  });

  test('oversized file is skipped (data: payload bound)', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_bigfont');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File big = File('${dir.path}/Big.ttf');
    await big.writeAsBytes(List<int>.filled(64, 0));

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Big', path: big.path)],
      allowedDirectories: <String>[dir.path],
      maxFileBytes: 16,
    );

    expect(result.fontFamily, isEmpty);
    expect(result.fontFaces, isEmpty);
  });

  test('unknown extension is skipped', () async {
    final Directory dir =
        await Directory.systemTemp.createTemp('hibiki_badext');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File f = File('${dir.path}/NotAFont.exe');
    await f.writeAsBytes(<int>[0x00]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('NotAFont', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );

    expect(result.fontFamily, isEmpty);
  });

  test('woff2 maps to the correct mime + format hint', () async {
    final Directory dir = await Directory.systemTemp.createTemp('hibiki_woff2');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final File f = File('${dir.path}/Web.woff2');
    await f.writeAsBytes(<int>[0x10, 0x20]);

    final result = DictionaryFontCss.build(
      <Map<String, dynamic>>[_e('Web', path: f.path)],
      allowedDirectories: <String>[dir.path],
    );
    expect(result.fontFaces, contains('data:font/woff2;base64,'));
    expect(result.fontFaces, contains('format("woff2")'));
  });
}
