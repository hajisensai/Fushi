import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-816: a backup meant to be SHARED must not leak this device's personal
/// data. Every personal item follows its OWNING feature category — untick the
/// feature and its data disappears from the export — and the LAN pairing
/// credential (`hibiki_paired_peers.token`) plus device-local sync baselines
/// never travel at all. The overwrite import mirrors each strip by preserving
/// THIS device's rows from bak, so a category-excluded backup never wipes them.
void main() {
  late Directory src;
  late Directory work;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('share_src_');
    work = await Directory.systemTemp.createTemp('share_work_');
  });
  tearDown(() async {
    for (final Directory d in <Directory>[src, work]) {
      if (d.existsSync()) await cleanupTempDir(d);
    }
  });

  Future<Archive> readZip(String zipPath) async {
    final InputFileStream input = InputFileStream(zipPath);
    try {
      return ZipDecoder().decodeBuffer(input);
    } finally {
      await input.close();
    }
  }

  int seq = 0;
  Future<HibikiDatabase> openBackupDb(String zipPath) async {
    final Archive archive = await readZip(zipPath);
    final ArchiveFile dbFile = archive.findFile('hibiki.db')!;
    final Directory dir = Directory(p.join(work.path, 'exdb${seq++}'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'hibiki.db'))
        .writeAsBytesSync(dbFile.content as List<int>);
    return HibikiDatabase(dir.path);
  }

  Future<int> tableCount(HibikiDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) c FROM $table').getSingle())
          .data['c'] as int;

  Future<int> prefCount(HibikiDatabase db, String key) async =>
      (await db.customSelect('SELECT COUNT(*) c FROM preferences WHERE key = ?',
              variables: <Variable<Object>>[Variable<String>(key)]).getSingle())
          .data['c'] as int;

  Future<String?> prefRaw(HibikiDatabase db, String key) async {
    final rows = await db.customSelect(
        'SELECT value v FROM preferences WHERE key = ?',
        variables: <Variable<Object>>[Variable<String>(key)]).get();
    if (rows.isEmpty) return null;
    return rows.first.read<String?>('v');
  }

  /// Seeds an in-memory source device carrying every personal item, plus a
  /// throwaway db dir the export copy is VACUUMed into.
  Future<({BackupService service, HibikiDatabase db})> buildSensitiveSource(
      {String favMarker = 'srcfav'}) async {
    final String dbDir = p.join(src.path, 'db');
    Directory(dbDir).createSync(recursive: true);
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'Bk',
      title: 'Bk',
      epubPath: 'x',
      extractDir: 'y',
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ));
    // Device-local: LAN pairing (with plaintext token) + sync baseline.
    await db.upsertPairedPeer(HibikiPairedPeersCompanion.insert(
        peerId: 'peer-1', token: 'SECRET_PAIR_TOKEN', pairedAtMs: 1));
    await db.into(db.syncBaselines).insert(SyncBaselinesCompanion.insert(
        assetKey: 'Bk', dimension: 'progress', baseVersion: 7));
    await db.upsertMangaExtensionStore(
      MangaExtensionStoresCompanion.insert(
        indexUrl: 'https://repo.example/index.json',
        name: 'Private repository',
        format: 'currentJson',
        signingKey: const Value('SIGNING_KEY'),
      ),
    );
    await db.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'org.example.extension',
        name: 'Private extension',
        versionCode: 1,
        versionName: '1.0.0',
        libVersion: '1.6',
        language: 'en',
        apkPath: 'extensions/org.example.extension.ext',
        apkSha256: 'apk-sha',
        signerSha256: 'signer-sha',
        installedAt: 1,
      ),
    );
    await db.replaceMangaOnlineSources(
      'org.example.extension',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'org.example.extension',
          sourceId: '9223372036854775807',
          name: 'Private source',
          language: 'en',
        ),
      ],
    );
    await db.upsertMangaSourcePreference(
      MangaSourcePreferencesCompanion.insert(
        extensionPackage: 'org.example.extension',
        sourceId: '9223372036854775807',
        preferenceKey: 'api_token',
        preferenceType: 'text',
        valueJson: '"SECRET_SOURCE_TOKEN"',
        updatedAt: 1,
      ),
    );
    await db.trustMangaSigner(
      MangaTrustedSignersCompanion.insert(
        fingerprint: 'signer-sha',
        label: 'Private signer',
        origin: 'local',
        trustedAt: 1,
      ),
    );
    // Content-registry prefs, each owned by a content category.
    await db.setPref(
        'favorite_sentences',
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{'id': favMarker, 'text': 'a sentence'}
        ]));
    await db.setPref('src:reader_ttu:font_catalog',
        jsonEncode(<String, Object?>{'version': 1, 'fonts': <Object?>[]}));
    await db.setPref('src:reader_ttu:custom_fonts', jsonEncode(<Object?>[]));
    await db.setPref(
        'local_audio_dbs',
        jsonEncode(<Map<String, Object?>>[
          <String, Object?>{'path': r'D:\HIBIKI\support\local_audio_1.db'}
        ]));
    // Stored the way PreferencesRepository writes it: a PrefCodec `j:`-tagged
    // JSON list, so the export-side B-filter can parse & filter its entries.
    await db.setPref(
      'audio_source_configs',
      PrefCodec.encode(<Map<String, Object?>>[
        <String, Object?>{
          'kind': 'localAudio',
          'path': r'D:\HIBIKI\support\local_audio_1.db',
          'enabled': true,
        },
        <String, Object?>{
          'kind': 'hibikiRemote',
          'url': 'http://server.example/',
          'enabled': true,
        },
      ]),
    );
    // Sync behaviour toggles (settings) — `b:`-tagged like the real app.
    await db.setPref('sync_content_enabled', PrefCodec.encode(true));
    await db.setPref('sync_auto_enabled', PrefCodec.encode(true));

    final BackupService service =
        BackupService(db: db, dbDirectory: dbDir, appVersion: '1.0.0');
    return (service: service, db: db);
  }

  Set<BackupCategory> allExcept(BackupCategory c) =>
      BackupCategory.values.toSet()..remove(c);

  group('export sanitization', () {
    test(
        'device-local pairing token + sync baselines never travel (even with '
        'all categories)', () async {
      final built = await buildSensitiveSource();
      final String zip = p.join(work.path, 'all.zip');
      await built.service.createBackup(zip); // null = every category
      await built.db.close();

      final HibikiDatabase ex = await openBackupDb(zip);
      addTearDown(ex.close);
      expect(await tableCount(ex, 'hibiki_paired_peers'), 0,
          reason: 'LAN pairing token must never leave the device');
      expect(await tableCount(ex, 'sync_baselines'), 0,
          reason: 'sync baselines are device-local causality');
      for (final String table in <String>[
        'manga_extension_stores',
        'manga_extensions',
        'manga_online_sources',
        'manga_source_preferences',
        'manga_trusted_signers',
      ]) {
        expect(
          await tableCount(ex, table),
          0,
          reason: '$table must not travel without the private APK/runtime data',
        );
      }
    });

    test('favorites follow books: unticking books strips favorite_sentences',
        () async {
      final built = await buildSensitiveSource();
      final String zip = p.join(work.path, 'nobooks.zip');
      await built.service
          .createBackup(zip, categories: allExcept(BackupCategory.books));
      await built.db.close();

      final HibikiDatabase ex = await openBackupDb(zip);
      addTearDown(ex.close);
      expect(await prefCount(ex, 'favorite_sentences'), 0);
    });

    test('favorites survive when books ticked', () async {
      final built = await buildSensitiveSource();
      final String zip = p.join(work.path, 'books.zip');
      await built.service.createBackup(zip,
          categories: <BackupCategory>{BackupCategory.books});
      await built.db.close();

      final HibikiDatabase ex = await openBackupDb(zip);
      addTearDown(ex.close);
      expect(await prefCount(ex, 'favorite_sentences'), 1);
    });

    test('font registry follows fonts: unticking fonts strips catalog + legacy',
        () async {
      final built = await buildSensitiveSource();
      final String zip = p.join(work.path, 'nofonts.zip');
      await built.service
          .createBackup(zip, categories: allExcept(BackupCategory.fonts));
      await built.db.close();

      final HibikiDatabase ex = await openBackupDb(zip);
      addTearDown(ex.close);
      expect(await prefCount(ex, 'src:reader_ttu:font_catalog'), 0);
      expect(await prefCount(ex, 'src:reader_ttu:custom_fonts'), 0);
    });

    test(
        'local-audio registry follows localAudio; audio_source_configs keeps '
        'only remote entries (option B)', () async {
      final built = await buildSensitiveSource();
      final String zip = p.join(work.path, 'noaudio.zip');
      await built.service
          .createBackup(zip, categories: allExcept(BackupCategory.localAudio));
      await built.db.close();

      final HibikiDatabase ex = await openBackupDb(zip);
      addTearDown(ex.close);
      expect(await prefCount(ex, 'local_audio_dbs'), 0);
      final String? raw = await prefRaw(ex, 'audio_source_configs');
      expect(raw, isNotNull);
      final dynamic decoded = PrefCodec.decodeUntyped(raw!);
      expect(decoded, isA<List<dynamic>>());
      final List<dynamic> entries = decoded as List<dynamic>;
      expect(entries.length, 1, reason: 'only the remote entry survives');
      expect((entries.single as Map)['kind'], 'hibikiRemote');
    });

    test('sync toggles follow settings: unticking settings strips them',
        () async {
      final built = await buildSensitiveSource();
      final String zip = p.join(work.path, 'nosettings.zip');
      await built.service
          .createBackup(zip, categories: allExcept(BackupCategory.settings));
      await built.db.close();

      final HibikiDatabase ex = await openBackupDb(zip);
      addTearDown(ex.close);
      expect(await prefCount(ex, 'sync_content_enabled'), 0);
      expect(await prefCount(ex, 'sync_auto_enabled'), 0);
    });

    test('sync toggles survive when settings ticked', () async {
      final built = await buildSensitiveSource();
      final String zip = p.join(work.path, 'withsettings.zip');
      await built.service.createBackup(zip,
          categories: <BackupCategory>{BackupCategory.settings});
      await built.db.close();

      final HibikiDatabase ex = await openBackupDb(zip);
      addTearDown(ex.close);
      expect(await prefCount(ex, 'sync_content_enabled'), 1);
    });
  });

  group('overwrite import preserves this device (mirror of the strip)', () {
    /// A source backup exported with [cats]; the source favorites are marked
    /// 'srcfav' so a preserve test can tell them from the device's 'mine'.
    Future<String> buildBackup(Set<BackupCategory>? cats) async {
      final built = await buildSensitiveSource(favMarker: 'srcfav');
      final String zip = p.join(work.path, 'src_${seq++}.zip');
      await built.service.createBackup(zip, categories: cats);
      await built.db.close();
      return zip;
    }

    /// Seeds an on-disk current device DB carrying its OWN pairing + favorites,
    /// then overwrite-imports [zip]. Returns the re-opened current DB.
    Future<HibikiDatabase> seedAndImport(String zip,
        {required Set<BackupCategory> importCats}) async {
      final String curDbDir = p.join(work.path, 'cur${seq++}', 'support');
      Directory(curDbDir).createSync(recursive: true);
      final HibikiDatabase cur0 = HibikiDatabase(curDbDir);
      await cur0.upsertPairedPeer(HibikiPairedPeersCompanion.insert(
          peerId: 'mydev', token: 'MY_DEVICE_TOKEN', pairedAtMs: 9));
      await cur0.setPref(
          'favorite_sentences',
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{'id': 'mine', 'text': 'my own sentence'}
          ]));
      await cur0.close();

      await BackupService.restoreBackup(
        dbDirectory: curDbDir,
        zipPath: zip,
        importSettings: true,
        categories: importCats,
      );
      return HibikiDatabase(curDbDir);
    }

    test(
        'device pairing (token) survives an overwrite import of a normal '
        'backup', () async {
      final String zip = await buildBackup(null);
      final HibikiDatabase cur =
          await seedAndImport(zip, importCats: BackupCategory.values.toSet());
      addTearDown(cur.close);
      final rows = await cur
          .customSelect('SELECT peer_id, token FROM hibiki_paired_peers')
          .get();
      expect(rows.length, 1);
      expect(rows.single.read<String>('peer_id'), 'mydev');
      expect(rows.single.read<String>('token'), 'MY_DEVICE_TOKEN',
          reason: 'restored from this device bak, not the (empty) backup');
    });

    test('books-excluded backup does not wipe this device favorites', () async {
      final String zip = await buildBackup(allExcept(BackupCategory.books));
      final HibikiDatabase cur =
          await seedAndImport(zip, importCats: BackupCategory.values.toSet());
      addTearDown(cur.close);
      final String? raw = await prefRaw(cur, 'favorite_sentences');
      expect(raw, isNotNull);
      expect(raw!.contains('mine'), isTrue,
          reason: 'device favorites preserved from bak');
      expect(raw.contains('srcfav'), isFalse,
          reason: 'the excluded backup carried no favorites');
    });

    test(
        'full backup (books ticked) overwrites favorites with the backup '
        'copy (normal migration unchanged)', () async {
      final String zip = await buildBackup(null);
      final HibikiDatabase cur =
          await seedAndImport(zip, importCats: BackupCategory.values.toSet());
      addTearDown(cur.close);
      final String? raw = await prefRaw(cur, 'favorite_sentences');
      expect(raw, isNotNull);
      expect(raw!.contains('srcfav'), isTrue,
          reason: 'backup favorites win in overwrite when books included');
    });
  });
}
