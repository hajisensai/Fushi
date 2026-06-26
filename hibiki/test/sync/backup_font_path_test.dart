import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  // ── BUG-183 unit: pure font-list path rebasing ──────────────────────────
  //
  // A full-data backup captures custom-font paths as absolute paths under the
  // SOURCE device's `<appDoc>/custom_fonts`. On the importing device that root
  // differs, so the stored paths would not resolve → fonts "imported & enabled
  // but never apply". rebaseFontListJson rewrites every file-font path onto the
  // new root, leaving system fonts (path == null) and unrelated paths alone.
  group('rebaseFontListJson', () {
    test('rebases each file-font path from old root onto the new root', () {
      const String json = '['
          '{"name":"Klee One","path":"/old/app/custom_fonts/Klee_1.ttf",'
          '"enabled":true},'
          '{"name":"Mincho","path":"/old/app/custom_fonts/Mincho_2.otf",'
          '"enabled":false}'
          ']';
      final String out = rebaseFontListJson(
        json,
        '/old/app/custom_fonts',
        '/new/app/custom_fonts',
      );
      final List<dynamic> decoded = jsonDecode(out) as List<dynamic>;
      expect((decoded[0] as Map)['path'], '/new/app/custom_fonts/Klee_1.ttf');
      expect((decoded[1] as Map)['path'], '/new/app/custom_fonts/Mincho_2.otf');
      expect((decoded[0] as Map)['name'], 'Klee One');
      expect((decoded[0] as Map)['enabled'], true);
      expect((decoded[1] as Map)['enabled'], false);
    });

    test('leaves a system font (null path) untouched', () {
      const String json = '[{"name":"Yu Gothic","path":null,"enabled":true}]';
      final String out = rebaseFontListJson(
        json,
        '/old/app/custom_fonts',
        '/new/app/custom_fonts',
      );
      final List<dynamic> decoded = jsonDecode(out) as List<dynamic>;
      expect((decoded[0] as Map)['path'], isNull);
      expect((decoded[0] as Map)['name'], 'Yu Gothic');
    });

    test('leaves a path that is not under the old root unchanged', () {
      const String json =
          '[{"name":"Sys","path":"/usr/share/fonts/X.ttf","enabled":true}]';
      final String out = rebaseFontListJson(
        json,
        '/old/app/custom_fonts',
        '/new/app/custom_fonts',
      );
      final List<dynamic> decoded = jsonDecode(out) as List<dynamic>;
      expect((decoded[0] as Map)['path'], '/usr/share/fonts/X.ttf');
    });

    test('rebases windows backslash paths', () {
      const String json =
          r'[{"name":"F","path":"C:\\OldA\\custom_fonts\\F_1.ttf",'
          r'"enabled":true}]';
      final String out = rebaseFontListJson(
        json,
        r'C:\OldA\custom_fonts',
        r'D:\NewB\custom_fonts',
      );
      final List<dynamic> decoded = jsonDecode(out) as List<dynamic>;
      expect((decoded[0] as Map)['path'], r'D:\NewB\custom_fonts\F_1.ttf');
    });

    test('returns the input verbatim on malformed JSON (never throws)', () {
      const String junk = 'not json at all';
      expect(
        rebaseFontListJson(junk, '/old/custom_fonts', '/new/custom_fonts'),
        junk,
      );
    });

    test('returns the input verbatim when JSON is not a list', () {
      const String obj = '{"name":"x"}';
      expect(
        rebaseFontListJson(obj, '/old/custom_fonts', '/new/custom_fonts'),
        obj,
      );
    });
  });

  group('BackupMeta fontsRoot', () {
    test('round-trips fontsRoot through json', () {
      final BackupMeta m = BackupMeta(
        appVersion: '1.0',
        schemaVersion: 16,
        createdAt: DateTime(2026, 6, 11),
        bookCount: 0,
        statsCount: 0,
        fontsRoot: '/old/app/custom_fonts',
      );
      final BackupMeta back = BackupMeta.fromJson(m.toJson());
      expect(back.fontsRoot, '/old/app/custom_fonts');
    });

    test('legacy backup with no fontsRoot → null and key omitted', () {
      final BackupMeta legacy = BackupMeta.fromJson(<String, dynamic>{
        'appVersion': '0.9',
        'schemaVersion': 14,
        'createdAt': DateTime(2026).toIso8601String(),
      });
      expect(legacy.fontsRoot, isNull);
      expect(legacy.toJson().containsKey('fontsRoot'), isFalse);
    });
  });

  // ── BUG-183 integration: export packs fonts + import restores & rebases ──
  group('BackupService custom-font round-trip', () {
    test(
        'export packs the custom_fonts tree and import restores files + '
        'rebases font config keys onto this device', () async {
      final Directory srcDir =
          await Directory.systemTemp.createTemp('bug183_src_db_');
      final Directory srcFontsDir =
          await Directory.systemTemp.createTemp('bug183_src_fonts_');
      addTearDown(() async {
        if (srcDir.existsSync()) await srcDir.delete(recursive: true);
        if (srcFontsDir.existsSync()) await srcFontsDir.delete(recursive: true);
      });

      final String bodyFontPath = '${srcFontsDir.path}/Klee_1.ttf';
      final String uiFontPath = '${srcFontsDir.path}/Mincho_2.otf';
      await File(bodyFontPath).writeAsString('FAKE-BODY-FONT');
      await File(uiFontPath).writeAsString('FAKE-UI-FONT');

      final HibikiDatabase srcDb = HibikiDatabase(srcDir.path);
      await srcDb.setPref(
        'src:reader_ttu:custom_fonts',
        jsonEncode(<Map<String, dynamic>>[
          {'name': 'Klee One', 'path': bodyFontPath, 'enabled': true},
        ]),
      );
      await srcDb.setPref(
        'src:reader_ttu:app_ui_fonts',
        jsonEncode(<Map<String, dynamic>>[
          {'name': 'Mincho', 'path': uiFontPath, 'enabled': true},
          {'name': 'Yu Gothic', 'path': null, 'enabled': true},
        ]),
      );
      await srcDb.setPref(
        'src:reader_ttu:dict_fonts',
        jsonEncode(<Map<String, dynamic>>[
          {'name': 'Klee One', 'path': bodyFontPath, 'enabled': false},
        ]),
      );
      // TODO-864: video subtitle font target also carries an absolute path that
      // must be stripped/rebased on export+import.
      await srcDb.setPref(
        'src:reader_ttu:video_sub_fonts',
        jsonEncode(<Map<String, dynamic>>[
          {'name': 'Mincho', 'path': uiFontPath, 'enabled': true},
        ]),
      );
      await srcDb.setPref(
        'src:reader_ttu:font_catalog',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'fonts': <Map<String, dynamic>>[
            {'id': 'font_1', 'name': 'Klee One', 'path': bodyFontPath},
            {'id': 'font_2', 'name': 'Mincho', 'path': uiFontPath},
            {'id': 'font_3', 'name': 'Yu Gothic', 'path': null},
          ],
        }),
      );
      await srcDb.setPref(
        'src:reader_ttu:font_targets',
        jsonEncode(<String, dynamic>{
          'version': 1,
          'targets': <String, dynamic>{
            'custom_fonts': <Map<String, dynamic>>[
              {'fontId': 'font_1', 'enabled': true},
            ],
            'app_ui_fonts': <Map<String, dynamic>>[
              {'fontId': 'font_2', 'enabled': true},
              {'fontId': 'font_3', 'enabled': true},
            ],
            'dict_fonts': <Map<String, dynamic>>[
              {'fontId': 'font_1', 'enabled': false},
            ],
          },
        }),
      );

      final Directory zipDir =
          await Directory.systemTemp.createTemp('bug183_zip_');
      addTearDown(() async {
        if (zipDir.existsSync()) await zipDir.delete(recursive: true);
      });
      final String zipPath = '${zipDir.path}/backup.zip';

      final BackupService service = BackupService(
        db: srcDb,
        dbDirectory: srcDir.path,
        appVersion: '1.0.0',
        fontsRootDirectory: srcFontsDir.path,
      );
      final BackupMeta meta = await service.exportBackup(zipPath);
      await srcDb.close();

      expect(meta.fontsRoot, srcFontsDir.path);

      final result = await service.validateBackup(zipPath);
      expect(result, isNotNull);

      final Directory dstDir =
          await Directory.systemTemp.createTemp('bug183_dst_db_');
      final Directory dstFontsDir =
          await Directory.systemTemp.createTemp('bug183_dst_fonts_');
      addTearDown(() async {
        if (dstDir.existsSync()) await dstDir.delete(recursive: true);
        if (dstFontsDir.existsSync()) await dstFontsDir.delete(recursive: true);
      });

      await BackupService.importBackupFiles(
        dbDirectory: dstDir.path,
        zipPath: zipPath,
        fontsRootDirectory: dstFontsDir.path,
      );

      expect(await File('${dstFontsDir.path}/Klee_1.ttf').exists(), isTrue);
      expect(await File('${dstFontsDir.path}/Mincho_2.otf').exists(), isTrue);
      expect(
        await File('${dstFontsDir.path}/Klee_1.ttf').readAsString(),
        'FAKE-BODY-FONT',
      );

      final HibikiDatabase dstDb = HibikiDatabase(dstDir.path);
      addTearDown(dstDb.close);
      final Map<String, String> prefs = await dstDb.getAllPrefs();

      final List<dynamic> body =
          jsonDecode(prefs['src:reader_ttu:custom_fonts']!) as List<dynamic>;
      expect((body[0] as Map)['path'], '${dstFontsDir.path}/Klee_1.ttf');
      expect(
        await File((body[0] as Map)['path'] as String).exists(),
        isTrue,
        reason: 'rebased body-font path must resolve to a real file',
      );

      final List<dynamic> ui =
          jsonDecode(prefs['src:reader_ttu:app_ui_fonts']!) as List<dynamic>;
      expect((ui[0] as Map)['path'], '${dstFontsDir.path}/Mincho_2.otf');
      expect((ui[1] as Map)['path'], isNull);

      final List<dynamic> dict =
          jsonDecode(prefs['src:reader_ttu:dict_fonts']!) as List<dynamic>;
      expect((dict[0] as Map)['path'], '${dstFontsDir.path}/Klee_1.ttf');
      expect((dict[0] as Map)['enabled'], false);

      // TODO-864: the video subtitle font's source-device absolute path must be
      // rebased onto this device's root (not leaked), proving the new key is in
      // both `_legacyFontPrefKeys` whitelists.
      final List<dynamic> videoSub =
          jsonDecode(prefs['src:reader_ttu:video_sub_fonts']!) as List<dynamic>;
      expect((videoSub[0] as Map)['path'], '${dstFontsDir.path}/Mincho_2.otf');
      expect(
        (videoSub[0] as Map)['path'],
        isNot(contains(srcFontsDir.path)),
        reason: 'video subtitle font absolute path must not leak the source '
            'device root',
      );

      final Map<String, dynamic> catalog =
          jsonDecode(prefs['src:reader_ttu:font_catalog']!)
              as Map<String, dynamic>;
      final List<dynamic> catalogFonts = catalog['fonts'] as List<dynamic>;
      final Map<String, Object?> catalogPathById = <String, Object?>{
        for (final dynamic row in catalogFonts)
          (row as Map<dynamic, dynamic>)['id'] as String: row['path'],
      };
      expect(catalogPathById['font_1'], '${dstFontsDir.path}/Klee_1.ttf');
      expect(catalogPathById['font_2'], '${dstFontsDir.path}/Mincho_2.otf');
      expect(catalogPathById['font_3'], isNull);

      final Map<String, dynamic> targets =
          jsonDecode(prefs['src:reader_ttu:font_targets']!)
              as Map<String, dynamic>;
      final Map<String, dynamic> targetRows =
          (targets['targets'] as Map<dynamic, dynamic>).cast<String, dynamic>();
      final List<dynamic> dictRows = targetRows['dict_fonts'] as List<dynamic>;
      expect((dictRows.single as Map<dynamic, dynamic>)['fontId'], 'font_1');
      expect((dictRows.single as Map<dynamic, dynamic>)['enabled'], false);
    });

    test('legacy backup (no fontsRoot) imports without crashing', () async {
      final Directory srcDir =
          await Directory.systemTemp.createTemp('bug183_legacy_src_');
      addTearDown(() async {
        if (srcDir.existsSync()) await srcDir.delete(recursive: true);
      });
      final HibikiDatabase onDisk = HibikiDatabase(srcDir.path);
      final BackupService realLegacy = BackupService(
        db: onDisk,
        dbDirectory: srcDir.path,
        appVersion: '0.9.0',
      );
      final Directory zipDir =
          await Directory.systemTemp.createTemp('bug183_legacy_zip_');
      addTearDown(() async {
        if (zipDir.existsSync()) await zipDir.delete(recursive: true);
      });
      final String zipPath = '${zipDir.path}/legacy.zip';
      final BackupMeta meta = await realLegacy.exportBackup(zipPath);
      expect(meta.fontsRoot, isNull);
      await onDisk.close();

      final Directory dstDir =
          await Directory.systemTemp.createTemp('bug183_legacy_dst_');
      final Directory dstFontsDir =
          await Directory.systemTemp.createTemp('bug183_legacy_dst_fonts_');
      addTearDown(() async {
        if (dstDir.existsSync()) await dstDir.delete(recursive: true);
        if (dstFontsDir.existsSync()) await dstFontsDir.delete(recursive: true);
      });

      await BackupService.importBackupFiles(
        dbDirectory: dstDir.path,
        zipPath: zipPath,
        fontsRootDirectory: dstFontsDir.path,
      );
      expect(File('${dstDir.path}/hibiki.db').existsSync(), isTrue);
    });
  });
}
