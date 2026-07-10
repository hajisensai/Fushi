import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/reader/reader_settings.dart';

/// TODO-1393 / BUG-705 integration: [ReaderSettings.healMissingFontFilePaths]
/// repairs a real Drift-persisted font catalog whose paths went stale after the
/// data folder moved, and persists the healed values back.
///
/// Scenario: the stored `font_catalog` + legacy shadow lists point at an OLD
/// custom_fonts root whose files are gone; the SAME-basename font files now live
/// under the current `<documents>/custom_fonts`. Heal relocates every entry and
/// writes it back, so a later read (reader / font page) sees valid paths.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String prefix = 'src:reader_ttu:';
  late Directory tmp;
  late Directory fontsDir; // current <documents>/custom_fonts
  late HibikiDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hibiki_font_heal_');
    fontsDir = Directory(p.join(tmp.path, 'documents', 'custom_fonts'))
      ..createSync(recursive: true);
    final Directory dbDir = Directory(p.join(tmp.path, 'db'))
      ..createSync(recursive: true);
    db = HibikiDatabase(dbDir.path);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('relocates stale catalog + shadow paths onto present files and persists',
      () async {
    // Real font files present in the CURRENT dir under their basenames.
    final String kleeNew = p.join(fontsDir.path, 'Klee One_1782285150702.ttf');
    final String notoNew =
        p.join(fontsDir.path, 'Noto Sans SC_1781248919842.ttf');
    File(kleeNew).writeAsBytesSync(<int>[0, 1, 2, 3]);
    File(notoNew).writeAsBytesSync(<int>[4, 5, 6, 7]);

    // Stale stored paths under an OLD root that is never created on disk, so
    // the files do not resolve. Built with p.join so separators are host-correct
    // (real Windows/POSIX paths), not a literal-backslash source constant.
    final String oldDir = p.join(tmp.path, 'OLD_GONE', 'custom_fonts');
    final String kleeOld = p.join(oldDir, 'Klee One_1782285150702.ttf');
    final String notoOld = p.join(oldDir, 'Noto Sans SC_1781248919842.ttf');

    final String catalog = jsonEncode(<String, dynamic>{
      'version': 1,
      'fonts': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'font_3', 'name': 'Klee One', 'path': kleeOld},
        <String, dynamic>{
          'id': 'font_2',
          'name': 'Noto Sans SC',
          'path': notoOld
        },
      ],
    });
    final String bodyList = jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{'name': 'Klee One', 'path': kleeOld, 'enabled': true},
    ]);
    final String appUiList = jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'Noto Sans SC',
        'path': notoOld,
        'enabled': true
      },
    ]);

    await db.setPref('${prefix}font_catalog', catalog);
    await db.setPref(
        '${prefix}font_targets',
        jsonEncode(
            <String, dynamic>{'version': 1, 'targets': <String, dynamic>{}}));
    await db.setPref('${prefix}custom_fonts', bodyList);
    await db.setPref('${prefix}app_ui_fonts', appUiList);

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    final int healed = await settings.healMissingFontFilePaths(fontsDir.path);
    // catalog(2) + custom_fonts(1) + app_ui_fonts(1) = 4 relocated entries.
    expect(healed, 4);

    // Healed values are PERSISTED back to the DB (survive a fresh read).
    final Map<String, dynamic> healedCatalog =
        jsonDecode((await db.getPref('${prefix}font_catalog'))!)
            as Map<String, dynamic>;
    final List<dynamic> healedFonts = healedCatalog['fonts'] as List<dynamic>;
    expect((healedFonts[0] as Map)['path'], kleeNew);
    expect((healedFonts[1] as Map)['path'], notoNew);
    // ids + names preserved so font_targets refs stay valid.
    expect((healedFonts[0] as Map)['id'], 'font_3');
    expect((healedFonts[1] as Map)['name'], 'Noto Sans SC');

    final List<dynamic> healedBody =
        jsonDecode((await db.getPref('${prefix}custom_fonts'))!)
            as List<dynamic>;
    expect((healedBody[0] as Map)['path'], kleeNew);
    expect((healedBody[0] as Map)['enabled'], true);

    // Idempotent: a second heal (all paths now valid) touches nothing.
    final ReaderSettings again = ReaderSettings(db);
    await again.refreshFromDb();
    expect(await again.healMissingFontFilePaths(fontsDir.path), 0);
  });

  test('no-op when every stored font path already resolves', () async {
    final String klee = p.join(fontsDir.path, 'Klee_1.ttf');
    File(klee).writeAsBytesSync(<int>[9]);
    final String catalog = jsonEncode(<String, dynamic>{
      'version': 1,
      'fonts': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'font_1', 'name': 'Klee', 'path': klee},
      ],
    });
    await db.setPref('${prefix}font_catalog', catalog);
    await db.setPref(
        '${prefix}font_targets',
        jsonEncode(
            <String, dynamic>{'version': 1, 'targets': <String, dynamic>{}}));

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    expect(await settings.healMissingFontFilePaths(fontsDir.path), 0);
    // Catalog unchanged.
    expect(await db.getPref('${prefix}font_catalog'), catalog);
  });
}
