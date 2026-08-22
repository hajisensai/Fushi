import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi-native-font-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('returns a system family without a file path', () {
    final result = AppFontLoader.resolveForNativeOverlay(
      <Map<String, dynamic>>[
        <String, dynamic>{'name': 'Yu_Gothic_UI', 'enabled': true},
      ],
      allowedDirectories: <String>[root.path],
    );

    expect(result?.family, 'Yu Gothic UI');
    expect(result?.path, isNull);
  });

  test('skips disabled and web fonts, then returns a safe OpenType file', () {
    final File raw = File(p.join(root.path, 'lookup.ttf'))..writeAsBytesSync(<int>[0]);
    File(p.join(root.path, 'web.woff2')).writeAsBytesSync(<int>[0]);

    final result = AppFontLoader.resolveForNativeOverlay(
      <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Disabled',
          'path': raw.path,
          'enabled': false,
        },
        <String, dynamic>{
          'name': 'Web Font',
          'path': p.join(root.path, 'web.woff2'),
          'enabled': true,
        },
        <String, dynamic>{
          'name': 'Lookup_Font',
          'path': raw.path,
          'enabled': true,
        },
      ],
      allowedDirectories: <String>[root.path],
    );

    expect(result?.family, 'Lookup Font');
    expect(result?.path, p.canonicalize(raw.path));
  });

  test('rejects imported files outside the managed font directory', () {
    final Directory outside = Directory.systemTemp.createTempSync('fushi-font-outside-');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    });
    final File raw = File(p.join(outside.path, 'outside.otf'))
      ..writeAsBytesSync(<int>[0]);

    final result = AppFontLoader.resolveForNativeOverlay(
      <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Outside',
          'path': raw.path,
          'enabled': true,
        },
      ],
      allowedDirectories: <String>[root.path],
    );

    expect(result, isNull);
  });
}
