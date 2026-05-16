import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/database/database.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

ProfilesCompanion _profile({String name = 'Default'}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ProfilesCompanion.insert(
    name: name,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('Profiles table', () {
    test('insertProfile and getProfileById round-trip', () async {
      final db = await _openDb();

      final id = await db.insertProfile(_profile(name: 'Test'));

      final row = await db.getProfileById(id);
      expect(row, isNotNull);
      expect(row!.name, 'Test');
    });

    test('getProfileById returns null for absent id', () async {
      final db = await _openDb();
      expect(await db.getProfileById(999), isNull);
    });

    test('getAllProfiles returns all', () async {
      final db = await _openDb();
      await db.insertProfile(_profile(name: 'A'));
      await db.insertProfile(_profile(name: 'B'));

      expect(await db.getAllProfiles(), hasLength(2));
    });

    test('countProfiles reflects actual count', () async {
      final db = await _openDb();
      expect(await db.countProfiles(), 0);

      await db.insertProfile(_profile());
      expect(await db.countProfiles(), 1);
    });

    test('updateProfileName changes the name', () async {
      final db = await _openDb();
      final id = await db.insertProfile(_profile(name: 'Old'));

      await db.updateProfileName(id, 'New');

      final row = await db.getProfileById(id);
      expect(row!.name, 'New');
    });

    test('deleteProfile removes the row', () async {
      final db = await _openDb();
      final id = await db.insertProfile(_profile());

      await db.deleteProfile(id);

      expect(await db.getProfileById(id), isNull);
    });
  });

  group('ProfileSettings table', () {
    test('upsert and retrieve settings for a profile', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());

      await db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: pid,
          category: 'pref',
          key: 'font_size',
          value: '16',
        ),
      );

      final settings = await db.getProfileSettings(pid);
      expect(settings, hasLength(1));
      expect(settings.single.key, 'font_size');
      expect(settings.single.value, '16');
    });

    test('upsert replaces on same composite key', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());

      await db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: pid,
          category: 'pref',
          key: 'theme',
          value: 'light',
        ),
      );
      await db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: pid,
          category: 'pref',
          key: 'theme',
          value: 'dark',
        ),
      );

      final settings = await db.getProfileSettings(pid);
      expect(settings, hasLength(1));
      expect(settings.single.value, 'dark');
    });

    test('replaceProfileSettings replaces all settings atomically', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());
      await db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: pid,
          category: 'pref',
          key: 'old_key',
          value: 'old_val',
        ),
      );

      await db.replaceProfileSettings(pid, [
        ProfileSettingsCompanion.insert(
          profileId: pid,
          category: 'pref',
          key: 'new_key',
          value: 'new_val',
        ),
      ]);

      final settings = await db.getProfileSettings(pid);
      expect(settings, hasLength(1));
      expect(settings.single.key, 'new_key');
    });
  });

  group('MediaTypeProfiles table', () {
    test('set and get media type profile', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());

      await db.setMediaTypeProfile('reader', pid);

      final row = await db.getMediaTypeProfile('reader');
      expect(row, isNotNull);
      expect(row!.profileId, pid);
    });

    test('getMediaTypeProfile returns null for unset type', () async {
      final db = await _openDb();
      expect(await db.getMediaTypeProfile('reader'), isNull);
    });

    test('getAllMediaTypeProfiles lists all bindings', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());
      await db.setMediaTypeProfile('reader', pid);
      await db.setMediaTypeProfile('dictionary', pid);

      final all = await db.getAllMediaTypeProfiles();
      expect(all, hasLength(2));
    });

    test('deleteMediaTypeProfile removes the binding', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());
      await db.setMediaTypeProfile('reader', pid);

      await db.deleteMediaTypeProfile('reader');

      expect(await db.getMediaTypeProfile('reader'), isNull);
    });
  });

  group('BookProfiles table', () {
    test('set and get book profile', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());

      await db.setBookProfile('book/123', pid);

      final row = await db.getBookProfile('book/123');
      expect(row, isNotNull);
      expect(row!.profileId, pid);
    });

    test('getBookProfile returns null for unset book', () async {
      final db = await _openDb();
      expect(await db.getBookProfile('ghost'), isNull);
    });

    test('deleteBookProfile removes the binding', () async {
      final db = await _openDb();
      final pid = await db.insertProfile(_profile());
      await db.setBookProfile('book/1', pid);

      await db.deleteBookProfile('book/1');

      expect(await db.getBookProfile('book/1'), isNull);
    });
  });
}
