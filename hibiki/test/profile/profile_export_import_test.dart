import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Hermetic in-process Anki repo (keeps AnkiSettings in memory) — mirrors the
/// fake in profile_repository_test.dart so snapshot/apply runs without platform
/// channels.
class _FakeAnkiRepository extends BaseAnkiRepository {
  AnkiSettings _settings = const AnkiSettings();

  @override
  Future<AnkiSettings> loadSettings() async => _settings;

  @override
  Future<void> saveSettings(AnkiSettings settings) async {
    _settings = settings;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();
}

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

ProfileRepository _repo(HibikiDatabase db) =>
    ProfileRepository(db, _FakeAnkiRepository());

/// The full set of sync credential pref keys that MUST never leave the device
/// in a profile export. Enumerated explicitly (not derived) so the red-line
/// test fails loudly if any one starts leaking.
const List<String> _allNineCredentialKeys = <String>[
  'sync_desktop_credentials', // Google OAuth refresh token bundle
  'sync_webdav_password',
  'sync_ftp_password',
  'sync_sftp_password',
  'sync_sftp_private_key',
  'sync_server_password',
  'sync_onedrive_token',
  'sync_dropbox_token',
  'sync_hibiki_client_token',
];

void main() {
  group('ProfileRepository export — credential red line', () {
    test(
        'export of active profile strips EVERY sync credential key '
        '(white-list + LIKE fallback)', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('A');
      await repo.setActiveProfileId(pid);

      // A genuine user setting that SHOULD survive export.
      await db.setPref('font_size', '16');
      // All nine credentials live in the preferences table; snapshot grabs them
      // (snapshotCurrentSettings does not exclude sync_ keys — that is by design
      // for the profile-switch round-trip, hence the export must strip them).
      for (final String key in _allNineCredentialKeys) {
        await db.setPref(key, 'BASE64SECRET==');
      }

      // Active profile → export autosnapshots then reads.
      final String json = await repo.exportProfileToJson(pid);
      final Map<String, dynamic> doc = jsonDecode(json) as Map<String, dynamic>;
      final List<dynamic> settings = doc['settings'] as List<dynamic>;
      final Set<String> exportedKeys = settings
          .map((dynamic e) => (e as Map<String, dynamic>)['key'] as String)
          .toSet();

      // The user setting survives.
      expect(exportedKeys, contains('font_size'));

      // RED LINE: not a single sync_ key — enumerated one by one so the failure
      // names the exact leaking credential.
      for (final String key in _allNineCredentialKeys) {
        expect(
          exportedKeys,
          isNot(contains(key)),
          reason: 'credential leaked into profile export: $key',
        );
      }
      // And nothing with a sync_ prefix at all.
      expect(
        exportedKeys.where((k) => k.startsWith('sync_')),
        isEmpty,
        reason: 'no sync_ pref should ever appear in a profile export',
      );

      // The serialized JSON text itself must not contain the secret payload.
      expect(json.contains('BASE64SECRET'), isFalse);
    });

    test('export carries the type magic + format/schema headers', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('Reader');
      await repo.setActiveProfileId(pid);
      await db.setPref('font_size', '20');

      final String json = await repo.exportProfileToJson(pid);
      final Map<String, dynamic> doc = jsonDecode(json) as Map<String, dynamic>;
      expect(doc['type'], ProfileExport.fileType);
      expect(doc['formatVersion'], ProfileExport.currentFormatVersion);
      expect(doc['schemaVersion'], db.schemaVersion);
      expect(doc['profileName'], 'Reader');
    });

    test(
        'export of a NON-active profile reads its snapshot without polluting it',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      final active = await repo.createProfile('Active');
      final other = await repo.createProfile('Other');
      await repo.setActiveProfileId(active);

      // Snapshot 'Other' with its own value, then make the live state differ.
      await db.setPref('font_size', '10');
      await repo.snapshotCurrentSettings(other);
      await db.setPref('font_size', '99'); // live state for the active profile

      final String json = await repo.exportProfileToJson(other);
      final Map<String, dynamic> doc = jsonDecode(json) as Map<String, dynamic>;
      final List<dynamic> settings = doc['settings'] as List<dynamic>;
      final Map<String, String> kv = <String, String>{
        for (final dynamic e in settings)
          (e as Map<String, dynamic>)['key'] as String: e['value'] as String,
      };
      // Reads the snapshot (10), NOT the current live value (99).
      expect(kv['font_size'], '10');

      // 'Other' snapshot is untouched by the export.
      final rows = await db.getProfileSettings(other);
      final other10 = rows.firstWhere((r) => r.key == 'font_size');
      expect(other10.value, '10');
    });

    test('A1 font path strip: catalog absolute paths become root-relative',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('Fonts');
      await repo.setActiveProfileId(pid);

      const String fontsRoot = '/data/app/custom_fonts';
      final String catalog = jsonEncode(<String, dynamic>{
        'version': 1,
        'fonts': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'a',
            'name': 'MyFont',
            'path': '$fontsRoot/MyFont.ttf',
          },
        ],
      });
      await db.setPref('src:reader_ttu:font_catalog', catalog);

      final String json =
          await repo.exportProfileToJson(pid, fontsRootDirectory: fontsRoot);
      final Map<String, dynamic> doc = jsonDecode(json) as Map<String, dynamic>;
      final List<dynamic> settings = doc['settings'] as List<dynamic>;
      final Map<String, String> kv = <String, String>{
        for (final dynamic e in settings)
          (e as Map<String, dynamic>)['key'] as String: e['value'] as String,
      };
      final Map<String, dynamic> exportedCatalog =
          jsonDecode(kv['src:reader_ttu:font_catalog']!)
              as Map<String, dynamic>;
      final String exportedPath =
          (exportedCatalog['fonts'] as List<dynamic>).first['path'] as String;
      // Absolute device root stripped → device topology not leaked, missing
      // font degrades gracefully on import.
      expect(exportedPath.contains(fontsRoot), isFalse);
      expect(exportedPath, '/MyFont.ttf');
    });
  });

  group('ProfileRepository import', () {
    Future<String> exportFixture(
      HibikiDatabase db,
      ProfileRepository repo,
      String name,
      Map<String, String> prefs,
    ) async {
      final pid = await repo.createProfile(name);
      await repo.setActiveProfileId(pid);
      for (final entry in prefs.entries) {
        await db.setPref(entry.key, entry.value);
      }
      final String json = await repo.exportProfileToJson(pid);
      // Remove the source profile so re-import creates a fresh one.
      await repo.deleteProfile(pid);
      return json;
    }

    test('default mode creates a NEW profile with the exported settings',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      // Seed a default so deleting the fixture profile is allowed.
      await repo.ensureDefaultProfile();
      final String json = await exportFixture(
        db,
        repo,
        'Imported',
        <String, String>{'font_size': '24', 'theme': 'sepia'},
      );

      final int newId = await repo.importProfileFromJson(json);
      final row = await db.getProfileById(newId);
      expect(row, isNotNull);
      expect(row!.name, 'Imported');

      final settings = await db.getProfileSettings(newId);
      final kv = <String, String>{for (final s in settings) s.key: s.value};
      expect(kv['font_size'], '24');
      expect(kv['theme'], 'sepia');
    });

    test('duplicate name gets a numeric suffix', () async {
      final db = await _openDb();
      final repo = _repo(db);
      await repo.ensureDefaultProfile();
      final String json = await exportFixture(
        db,
        repo,
        'Dup',
        <String, String>{'font_size': '12'},
      );
      // Re-create a profile named 'Dup' so the import collides.
      await repo.createProfile('Dup');

      final int newId = await repo.importProfileFromJson(json);
      final row = await db.getProfileById(newId);
      expect(row!.name, 'Dup (2)');
    });

    test('overwrite mode replaces the target profile settings', () async {
      final db = await _openDb();
      final repo = _repo(db);
      await repo.ensureDefaultProfile();
      final target = await repo.createProfile('Target');
      await db.setPref('font_size', '8');
      await repo.snapshotCurrentSettings(target);

      final String json = await exportFixture(
        db,
        repo,
        'Source',
        <String, String>{'font_size': '32', 'new_key': 'v'},
      );

      final int writtenId = await repo.importProfileFromJson(
        json,
        mode: ProfileImportMode.overwrite,
        targetProfileId: target,
      );
      expect(writtenId, target);
      final settings = await db.getProfileSettings(target);
      final kv = <String, String>{for (final s in settings) s.key: s.value};
      expect(kv['font_size'], '32');
      expect(kv['new_key'], 'v');
    });

    test('corrupt JSON throws ProfileImportException before touching the DB',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      await repo.ensureDefaultProfile();
      final before = (await db.getAllProfiles()).length;

      expect(
        () => repo.importProfileFromJson('{ not valid json'),
        throwsA(isA<ProfileImportException>()),
      );
      // No partial profile created.
      expect((await db.getAllProfiles()).length, before);
    });

    test('wrong type magic is rejected (not any JSON file)', () async {
      final db = await _openDb();
      final repo = _repo(db);
      await repo.ensureDefaultProfile();
      final String alien = jsonEncode(<String, dynamic>{
        'type': 'hibiki.backup',
        'formatVersion': 1,
        'profileName': 'X',
        'settings': <dynamic>[],
      });
      expect(
        () => repo.importProfileFromJson(alien),
        throwsA(isA<ProfileImportException>()),
      );
    });

    test('unsupported (future) format version is rejected', () async {
      final db = await _openDb();
      final repo = _repo(db);
      await repo.ensureDefaultProfile();
      final String future = jsonEncode(<String, dynamic>{
        'type': ProfileExport.fileType,
        'formatVersion': ProfileExport.currentFormatVersion + 1,
        'profileName': 'X',
        'settings': <dynamic>[],
      });
      expect(
        () => repo.importProfileFromJson(future),
        throwsA(isA<ProfileImportException>()),
      );
    });

    test('overwrite without targetProfileId throws (DB untouched)', () async {
      final db = await _openDb();
      final repo = _repo(db);
      await repo.ensureDefaultProfile();
      final String json = jsonEncode(<String, dynamic>{
        'type': ProfileExport.fileType,
        'formatVersion': ProfileExport.currentFormatVersion,
        'schemaVersion': db.schemaVersion,
        'profileName': 'X',
        'settings': <dynamic>[],
      });
      expect(
        () => repo.importProfileFromJson(
          json,
          mode: ProfileImportMode.overwrite,
        ),
        throwsA(isA<ProfileImportException>()),
      );
    });

    test('round-trip: export then import reproduces non-credential settings',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      await repo.ensureDefaultProfile();
      final String json = await exportFixture(
        db,
        repo,
        'RT',
        <String, String>{
          'font_size': '18',
          'theme': 'dark',
          'sync_ftp_password': 'leak', // must be stripped on export
        },
      );
      final int newId = await repo.importProfileFromJson(json);
      final settings = await db.getProfileSettings(newId);
      final kv = <String, String>{for (final s in settings) s.key: s.value};
      expect(kv['font_size'], '18');
      expect(kv['theme'], 'dark');
      expect(kv.containsKey('sync_ftp_password'), isFalse);
    });
  });
}
