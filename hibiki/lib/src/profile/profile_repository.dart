import 'package:hibiki/src/anki/anki_repository.dart';
import 'package:hibiki/src/database/database.dart';
import 'package:hibiki/src/profile/profile_keys.dart';

class ProfileRepository {

  ProfileRepository(this._db, this._ankiRepo);
  final HibikiDatabase _db;
  final AnkiRepository _ankiRepo;

  Future<List<ProfileRow>> getAllProfiles() => _db.getAllProfiles();

  Future<ProfileRow?> getProfileById(int id) => _db.getProfileById(id);

  Future<int> getActiveProfileId() async {
    final raw = await _db.getPref('active_profile_id');
    return raw != null ? (int.tryParse(raw) ?? -1) : -1;
  }

  Future<void> setActiveProfileId(int id) =>
      _db.setPref('active_profile_id', id.toString());

  Future<int> createProfile(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.insertProfile(
      ProfilesCompanion.insert(
        name: name,
        createdAt: now,
        updatedAt: now,
      ),
    );
    return id;
  }

  Future<void> renameProfile(int id, String name) =>
      _db.updateProfileName(id, name);

  Future<void> deleteProfile(int id) async {
    final count = await _db.countProfiles();
    if (count <= 1) return;

    final activeId = await getActiveProfileId();
    await _db.deleteProfile(id);

    if (activeId == id) {
      final remaining = await _db.getAllProfiles();
      if (remaining.isNotEmpty) {
        await setActiveProfileId(remaining.first.id);
        await applyProfile(remaining.first.id);
      }
    }
  }

  Future<void> snapshotCurrentSettings(int profileId) async {
    final entries = <ProfileSettingsCompanion>[];

    // Anki settings (SharedPreferences)
    final ankiSettings = await _ankiRepo.loadSettings();
    final ankiMap = ProfileKeys.ankiSettingsToMap(ankiSettings);
    for (final entry in ankiMap.entries) {
      entries.add(ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: ProfileKeys.categoryAnki,
        key: entry.key,
        value: entry.value,
      ));
    }

    // ALL Drift prefs (excluding app-state keys)
    final allPrefs = await _db.getAllPrefs();
    for (final entry in allPrefs.entries) {
      if (ProfileKeys.isExcludedPref(entry.key)) continue;
      entries.add(ProfileSettingsCompanion.insert(
        profileId: profileId,
        category: ProfileKeys.categoryPref,
        key: entry.key,
        value: entry.value,
      ));
    }

    await _db.replaceProfileSettings(profileId, entries);
  }

  Future<void> applyProfile(int profileId) async {
    final rows = await _db.getProfileSettings(profileId);

    final ankiMap = <String, String>{};
    final prefMap = <String, String>{};
    for (final row in rows) {
      switch (row.category) {
        case ProfileKeys.categoryAnki:
          ankiMap[row.key] = row.value;
        case ProfileKeys.categoryPref:
          prefMap[row.key] = row.value;
        // Legacy categories from old snapshots
        case ProfileKeys.categoryDictionary:
          prefMap[row.key] = row.value;
        case ProfileKeys.categoryReader:
          prefMap['src:reader_ttu:${row.key}'] = row.value;
        default:
          break;
      }
    }

    // Wrap DB writes in transaction for consistency
    await _db.transaction(() async {
      final currentPrefs = await _db.getAllPrefs();
      for (final key in currentPrefs.keys) {
        if (ProfileKeys.isExcludedPref(key)) continue;
        if (!prefMap.containsKey(key)) {
          await _db.deletePref(key);
        }
      }
      for (final entry in prefMap.entries) {
        await _db.setPref(entry.key, entry.value);
      }
    });

    // Anki settings (SharedPreferences)
    if (ankiMap.isNotEmpty) {
      final current = await _ankiRepo.loadSettings();
      final updated = ProfileKeys.mapToAnkiSettings(ankiMap, current);
      await _ankiRepo.saveSettings(updated);
    }
  }

  Future<int> copyProfile(int sourceId, String newName) async {
    final newId = await createProfile(newName);
    final sourceSettings = await _db.getProfileSettings(sourceId);
    final copies = sourceSettings
        .map((s) => ProfileSettingsCompanion.insert(
              profileId: newId,
              category: s.category,
              key: s.key,
              value: s.value,
            ))
        .toList();
    await _db.replaceProfileSettings(newId, copies);
    return newId;
  }

  Future<Map<String, int>> getAllMediaTypeBindings() async {
    final rows = await _db.getAllMediaTypeProfiles();
    return {for (final r in rows) r.mediaType: r.profileId};
  }

  Future<void> setMediaTypeBinding(String mediaType, int profileId) =>
      _db.setMediaTypeProfile(mediaType, profileId);

  Future<void> removeMediaTypeBinding(String mediaType) =>
      _db.deleteMediaTypeProfile(mediaType);

  Future<int?> getBookProfileId(String bookUid) async {
    final row = await _db.getBookProfile(bookUid);
    return row?.profileId;
  }

  Future<void> setBookProfile(String bookUid, int profileId) =>
      _db.setBookProfile(bookUid, profileId);

  Future<void> removeBookProfile(String bookUid) =>
      _db.deleteBookProfile(bookUid);

  Future<int> resolveProfileId({
    required String? bookUid,
    required String? mediaType,
  }) async {
    if (bookUid != null) {
      final bookProfileId = await getBookProfileId(bookUid);
      if (bookProfileId != null) return bookProfileId;
    }

    if (mediaType != null) {
      final mtRow = await _db.getMediaTypeProfile(mediaType);
      if (mtRow != null) return mtRow.profileId;
    }

    return getActiveProfileId();
  }

  Future<void> ensureDefaultProfile() async {
    final existing = await _db.getAllProfiles();
    if (existing.isNotEmpty) return;

    final id = await createProfile('Default');
    await setActiveProfileId(id);
    await snapshotCurrentSettings(id);
  }
}
