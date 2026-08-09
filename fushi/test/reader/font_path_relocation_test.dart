import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/reader/font_catalog.dart';

/// TODO-1393 / BUG-705 unit: pure font-path self-heal (relocate) helpers.
///
/// A stored custom-font absolute path can go stale after a data-root move, a
/// pre-fix backup restore (the shadow-only window that never rebased
/// `font_catalog`), an iOS reinstall's new container UUID, or a profile-import
/// stripped path — while the font FILE is still present under the current
/// `<documents>/custom_fonts` under the same basename. These helpers relocate a
/// missing path onto that same-basename file; they never touch a still-valid
/// path, a system font (null), or an entry with no recoverable file.
void main() {
  // A fake filesystem: only the paths in [present] "exist".
  bool Function(String) existsIn(Set<String> present) =>
      (String path) => present.contains(path);

  group('fontPathBasename', () {
    test('splits on the last separator regardless of style', () {
      expect(fontPathBasename(r'D:\app\custom_fonts\Klee_1.ttf'), 'Klee_1.ttf');
      expect(fontPathBasename('/app/custom_fonts/Noto_2.otf'), 'Noto_2.otf');
      // profile-export stripped-to-empty-root leading-separator relative path
      expect(fontPathBasename(r'\Klee_1.ttf'), 'Klee_1.ttf');
      expect(fontPathBasename('/Klee_1.ttf'), 'Klee_1.ttf');
      expect(fontPathBasename('Klee_1.ttf'), 'Klee_1.ttf');
    });
  });

  group('relocateMissingFontCatalogPaths', () {
    test('relocates a missing path onto the same-basename file in the new dir',
        () {
      const String oldPath = r'C:\Users\me\Documents\custom_fonts\Klee_1.ttf';
      const String newDir = r'D:\data\documents\custom_fonts';
      // Build the recovered path the SAME way the helper does (p.join uses
      // the host separator) so this asserts real behavior on Windows AND on
      // Linux/Android CI, never a hardcoded separator (BUG-710).
      final String newPath = p.join(newDir, 'Klee_1.ttf');
      final String json = jsonEncode(<String, dynamic>{
        'version': 1,
        'fonts': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'font_2',
            'name': 'Klee One',
            'path': oldPath
          },
        ],
      });
      final ({String json, int relocated}) out =
          relocateMissingFontCatalogPaths(
        json,
        newDir,
        existsIn(<String>{newPath}),
      );
      expect(out.relocated, 1);
      final Map<String, dynamic> decoded =
          jsonDecode(out.json) as Map<String, dynamic>;
      final Map<String, dynamic> font =
          (decoded['fonts'] as List<dynamic>).first as Map<String, dynamic>;
      expect(font['path'], newPath);
      expect(font['id'], 'font_2'); // id + name preserved
      expect(font['name'], 'Klee One');
    });

    test('leaves a still-valid path untouched (never relocates a working file)',
        () {
      const String valid = r'D:\data\documents\custom_fonts\Klee_1.ttf';
      final String json = jsonEncode(<String, dynamic>{
        'version': 1,
        'fonts': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'font_2', 'name': 'Klee One', 'path': valid},
        ],
      });
      final ({String json, int relocated}) out =
          relocateMissingFontCatalogPaths(
        json,
        r'D:\data\documents\custom_fonts',
        existsIn(<String>{valid}),
      );
      expect(out.relocated, 0);
      expect(out.json, json); // returned verbatim
    });
  });

  group('relocateMissingFontCatalogPaths edge cases', () {
    test('leaves a missing path with no recoverable file untouched', () {
      const String missing = r'C:\old\custom_fonts\Gone_9.ttf';
      final String json = jsonEncode(<String, dynamic>{
        'version': 1,
        'fonts': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'font_2', 'name': 'Gone', 'path': missing},
        ],
      });
      final ({String json, int relocated}) out =
          relocateMissingFontCatalogPaths(
        json,
        r'D:\data\documents\custom_fonts',
        existsIn(<String>{}), // nothing exists
      );
      expect(out.relocated, 0);
      final Map<String, dynamic> font =
          (jsonDecode(out.json)['fonts'] as List<dynamic>).first
              as Map<String, dynamic>;
      expect(
          font['path'], missing); // entry preserved, loader keeps skipping it
    });

    test('leaves a system font (null path) untouched', () {
      final String json = jsonEncode(<String, dynamic>{
        'version': 1,
        'fonts': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'font_1', 'name': 'Yu Gothic', 'path': null},
        ],
      });
      final ({String json, int relocated}) out =
          relocateMissingFontCatalogPaths(
        json,
        r'D:\data\documents\custom_fonts',
        existsIn(<String>{}),
      );
      expect(out.relocated, 0);
    });

    test('relocates a profile-export stripped leading-separator path', () {
      const String stripped = '/Klee_1.ttf';
      const String newDir = '/data/documents/custom_fonts';
      // Build the recovered path the SAME way the helper does (p.join uses the
      // host separator) so this asserts real behavior on every platform.
      final String recovered = p.join(newDir, fontPathBasename(stripped));
      final String json = jsonEncode(<String, dynamic>{
        'version': 1,
        'fonts': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'f', 'name': 'Klee', 'path': stripped},
        ],
      });
      final ({String json, int relocated}) out =
          relocateMissingFontCatalogPaths(
        json,
        newDir,
        existsIn(<String>{recovered}),
      );
      expect(out.relocated, 1);
      final Map<String, dynamic> font =
          (jsonDecode(out.json)['fonts'] as List<dynamic>).first
              as Map<String, dynamic>;
      expect(font['path'], recovered);
    });

    test('relocates onto a POSIX current dir (Android/Linux data-root move)',
        () {
      // Regression guard for the CI-only failure (BUG-710) where the stored
      // path is relocated onto a POSIX <documents>/custom_fonts: the helper
      // must build the recovered path with p.join (host separator); a
      // hardcoded Windows separator would never match on Linux/Android.
      // fontPathBasename splits on either separator so the basename survives.
      const String oldPath = '/old/container/custom_fonts/Gothic_7.ttf';
      const String newDir = '/data/user/0/app.fushi.reader/custom_fonts';
      final String newPath = p.join(newDir, fontPathBasename(oldPath));
      final String json = jsonEncode(<String, dynamic>{
        'version': 1,
        'fonts': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'f', 'name': 'Gothic', 'path': oldPath},
        ],
      });
      final ({String json, int relocated}) out =
          relocateMissingFontCatalogPaths(
        json,
        newDir,
        existsIn(<String>{newPath}),
      );
      expect(out.relocated, 1);
      final Map<String, dynamic> font =
          (jsonDecode(out.json)['fonts'] as List<dynamic>).first
              as Map<String, dynamic>;
      expect(font['path'], newPath);
    });

    test('returns malformed JSON verbatim', () {
      const String bad = 'not json {';
      final ({String json, int relocated}) out =
          relocateMissingFontCatalogPaths(bad, '/dir', existsIn(<String>{}));
      expect(out.relocated, 0);
      expect(out.json, bad);
    });
  });

  group('relocateMissingFontListPaths', () {
    test('relocates missing shadow-list paths and keeps other fields', () {
      const String oldPath = r'C:\old\custom_fonts\Noto_2.ttf';
      const String newDir = r'D:\data\documents\custom_fonts';
      // p.join (host separator), matching the helper's own construction, so
      // the assertion holds on Windows AND Linux/Android CI (BUG-710).
      final String newPath = p.join(newDir, 'Noto_2.ttf');
      final String json = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'name': 'Noto', 'path': oldPath, 'enabled': false},
      ]);
      final ({String json, int relocated}) out = relocateMissingFontListPaths(
        json,
        newDir,
        existsIn(<String>{newPath}),
      );
      expect(out.relocated, 1);
      final Map<String, dynamic> row =
          (jsonDecode(out.json) as List<dynamic>).first as Map<String, dynamic>;
      expect(row['path'], newPath);
      expect(row['name'], 'Noto');
      expect(row['enabled'], false); // enabled flag preserved
    });

    test('leaves a system font (null path) untouched', () {
      const String json = '[{"name":"Yu Gothic","path":null,"enabled":true}]';
      final ({String json, int relocated}) out =
          relocateMissingFontListPaths(json, '/dir', existsIn(<String>{}));
      expect(out.relocated, 0);
    });
  });
}
