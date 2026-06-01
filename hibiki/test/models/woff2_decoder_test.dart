import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/woff2_decoder.dart';

/// Locates a real `.woff2` fixture. The Flutter SDK ships several (Roboto)
/// under its bundled DevTools assets; honour an explicit override too. Returns
/// null when none is found (the test then skips rather than failing on CI).
String _baseName(Directory d) => d.path
    .replaceAll('\\', '/')
    .split('/')
    .where((String s) => s.isNotEmpty)
    .last;

String? _scanForWoff2(Directory dir) {
  if (!dir.existsSync()) return null;
  try {
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is File && e.path.toLowerCase().endsWith('.woff2')) return e.path;
    }
  } catch (_) {/* ignore unreadable dirs */}
  return null;
}

String? _findWoff2() {
  // Committed fixture (CI-stable). Falls back to an override / the SDK's
  // bundled Roboto woff2 when run outside the repo tree.
  final File vendored = File('test/fixtures/fonts/Roboto-Regular.woff2');
  if (vendored.existsSync()) return vendored.path;

  final String? override = Platform.environment['HIBIKI_WOFF2_FIXTURE'];
  if (override != null && File(override).existsSync()) return override;

  final List<Directory> caches = <Directory>[];
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    caches.add(Directory('$flutterRoot/bin/cache'));
  }
  // Under `flutter test` the executable is flutter_tester, several levels deep
  // inside flutter/bin/cache; walk up to the `cache` directory.
  Directory d = File(Platform.resolvedExecutable).parent;
  for (int i = 0; i < 10; i++) {
    if (_baseName(d) == 'cache') {
      caches.add(d);
      break;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }

  for (final Directory cache in caches) {
    // The SDK ships Roboto .woff2 under DevTools' bundled perfetto assets.
    final String? hit = _scanForWoff2(
            Directory('${cache.path}/dart-sdk/bin/resources/devtools')) ??
        _scanForWoff2(cache);
    if (hit != null) return hit;
  }
  return null;
}

({int flavor, int numTables, Map<String, (int, int)> tables}) _parse(
    Uint8List sfnt) {
  final ByteData bd =
      ByteData.view(sfnt.buffer, sfnt.offsetInBytes, sfnt.lengthInBytes);
  final int flavor = bd.getUint32(0);
  final int n = bd.getUint16(4);
  final Map<String, (int, int)> tables = <String, (int, int)>{};
  for (int i = 0; i < n; i++) {
    final int o = 12 + i * 16;
    final String tag = String.fromCharCodes(<int>[
      bd.getUint8(o),
      bd.getUint8(o + 1),
      bd.getUint8(o + 2),
      bd.getUint8(o + 3),
    ]);
    tables[tag] = (bd.getUint32(o + 8), bd.getUint32(o + 12));
  }
  return (flavor: flavor, numTables: n, tables: tables);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decodes a real Roboto .woff2 into a loadable, structurally valid sfnt',
      () async {
    final String? fixture = _findWoff2();
    if (fixture == null) {
      markTestSkipped('no .woff2 fixture found (set HIBIKI_WOFF2_FIXTURE)');
      return;
    }

    final Uint8List woff2 = File(fixture).readAsBytesSync();
    final Uint8List? sfnt = Woff2Decoder.toSfnt(woff2);
    expect(sfnt, isNotNull, reason: 'decode returned null for $fixture');

    final parsed = _parse(sfnt!);
    expect(parsed.flavor == 0x00010000 || parsed.flavor == 0x4F54544F, isTrue,
        reason: 'unexpected sfnt flavor 0x${parsed.flavor.toRadixString(16)}');
    expect(parsed.tables.keys.toSet().containsAll(<String>{'head', 'maxp'}),
        isTrue,
        reason: 'missing core tables: ${parsed.tables.keys}');

    final ByteData bd =
        ByteData.view(sfnt.buffer, sfnt.offsetInBytes, sfnt.lengthInBytes);

    // If glyf-based, loca must have numGlyphs+1 long entries, monotonic, and
    // every glyph must begin with a sane contour count.
    final (int, int)? maxp = parsed.tables['maxp'];
    final (int, int)? head = parsed.tables['head'];
    final (int, int)? loca = parsed.tables['loca'];
    final (int, int)? glyf = parsed.tables['glyf'];
    if (glyf != null && loca != null && maxp != null && head != null) {
      final int numGlyphs = bd.getUint16(maxp.$1 + 4);
      // We always emit the long loca format.
      expect(bd.getInt16(head.$1 + 50), 1, reason: 'head.indexToLocFormat');
      expect(loca.$2, (numGlyphs + 1) * 4, reason: 'loca length');
      int prev = -1;
      for (int i = 0; i <= numGlyphs; i++) {
        final int off = bd.getUint32(loca.$1 + i * 4);
        expect(off >= prev, isTrue, reason: 'loca not monotonic at $i');
        prev = off;
      }
      expect(prev, glyf.$2, reason: 'final loca offset != glyf length');
      for (int i = 0; i < numGlyphs; i++) {
        final int s = bd.getUint32(loca.$1 + i * 4);
        final int e = bd.getUint32(loca.$1 + (i + 1) * 4);
        if (e == s) continue; // empty glyph
        final int nc = bd.getInt16(glyf.$1 + s);
        expect(nc >= -1, isTrue, reason: 'glyph $i bad contour count $nc');
      }
    }

    // The engine must accept the reconstructed font.
    final FontLoader loader = FontLoader('Woff2 Decoder Test')
      ..addFont(Future<ByteData>.value(
          ByteData.view(sfnt.buffer, sfnt.offsetInBytes, sfnt.lengthInBytes)));
    await loader.load();
  });

  // The Roboto fixture does not exercise the hmtx transform, so verify that
  // reconstruction directly (both the from-xMin and from-stream paths).
  group('hmtx transform reconstruction', () {
    Uint8List bytesOf(List<int> b) => Uint8List.fromList(b);

    ByteData viewOf(Uint8List u) =>
        ByteData.view(u.buffer, u.offsetInBytes, u.lengthInBytes);

    test('omitted lsb arrays are derived from glyf xMin', () {
      // flags=0x03 (both lsb arrays omitted); advanceWidth[2] = 500, 600.
      final Uint8List tx = bytesOf(<int>[0x03, 0x01, 0xF4, 0x02, 0x58]);
      final Uint8List? hmtx =
          Woff2Decoder.reconstructHmtxForTest(tx, 2, <int>[10, 20, 30]);
      expect(hmtx, isNotNull);
      final ByteData bd = viewOf(hmtx!);
      expect(hmtx.length, 2 * 4 + 1 * 2);
      expect(bd.getUint16(0), 500);
      expect(bd.getInt16(2), 10);
      expect(bd.getUint16(4), 600);
      expect(bd.getInt16(6), 20);
      expect(bd.getInt16(8), 30); // mono-glyph lsb taken from xMin
    });

    test('present lsb arrays are read from the stream', () {
      // flags=0x00; advances 500,600; lsb 5,-5; mono lsb 9.
      final Uint8List tx = bytesOf(<int>[
        0x00,
        0x01, 0xF4, 0x02, 0x58, // advances 500, 600
        0x00, 0x05, 0xFF, 0xFB, // lsb 5, -5
        0x00, 0x09, // mono lsb 9
      ]);
      final Uint8List? hmtx =
          Woff2Decoder.reconstructHmtxForTest(tx, 2, <int>[0, 0, 0]);
      expect(hmtx, isNotNull);
      final ByteData bd = viewOf(hmtx!);
      expect(bd.getUint16(0), 500);
      expect(bd.getInt16(2), 5);
      expect(bd.getUint16(4), 600);
      expect(bd.getInt16(6), -5);
      expect(bd.getInt16(8), 9);
    });

    test('rejects numberOfHMetrics greater than numGlyphs', () {
      expect(
        Woff2Decoder.reconstructHmtxForTest(
            bytesOf(<int>[0x03, 0x00, 0x00]), 5, <int>[0, 0]),
        isNull,
      );
    });
  });
}
