import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Hermetic in-process Anki repo: keeps settings in memory instead of
/// SharedPreferences so ProfileRepository's snapshot/apply Anki round-trip runs
/// without platform channels. ProfileRepository only ever calls
/// loadSettings/saveSettings, so the network methods are never exercised.
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

/// Collects the 'pref'-category keys of a profile's snapshot.
Future<Set<String>> _prefKeys(HibikiDatabase db, int profileId) async {
  final rows = await db.getProfileSettings(profileId);
  return rows.where((r) => r.category == 'pref').map((r) => r.key).toSet();
}

void main() {
  group('ProfileRepository orchestration', () {
    test('snapshot + apply round-trips non-excluded prefs', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('A');

      await db.setPref('font_size', '16');
      await db.setPref('theme', 'dark');
      await repo.snapshotCurrentSettings(pid);

      // Clear live state, then restore from the snapshot.
      await db.deletePref('font_size');
      await db.deletePref('theme');
      await repo.applyProfile(pid);

      expect(await db.getPref('font_size'), '16');
      expect(await db.getPref('theme'), 'dark');
      expect(await _prefKeys(db, pid),
          containsAll(<String>['font_size', 'theme']));
    });

    test('snapshot excludes app-state keys (active id, current_source/*)',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('A');

      await db.setPref('active_profile_id', '5');
      await db.setPref('current_source/reader', 'x');
      await db.setPref('font_size', '16');
      await repo.snapshotCurrentSettings(pid);

      final keys = await _prefKeys(db, pid);
      expect(keys, contains('font_size'));
      expect(keys, isNot(contains('active_profile_id')));
      expect(keys, isNot(contains('current_source/reader')));
    });

    test('snapshot and apply keep app UI scale prefs device-local', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('A');
      final legacyScale = PrefCodec.encode(1.5);
      final legacyMode = PrefCodec.encode('custom');
      final liveScale = PrefCodec.encode(2.0);
      final liveMode = PrefCodec.encode('auto');

      await db.setPref('app_ui_scale', legacyScale);
      await db.setPref('app_ui_scale_mode', legacyMode);
      await db.setPref('font_size', '16');
      await repo.snapshotCurrentSettings(pid);

      final keys = await _prefKeys(db, pid);
      expect(keys, contains('font_size'));
      expect(keys, isNot(contains('app_ui_scale')));
      expect(keys, isNot(contains('app_ui_scale_mode')));

      await db.setPref('font_size', '99');
      await db.setPref('app_ui_scale', liveScale);
      await db.setPref('app_ui_scale_mode', liveMode);
      await repo.applyProfile(pid);

      expect(await db.getPref('font_size'), '16');
      expect(await db.getPref('app_ui_scale'), liveScale);
      expect(await db.getPref('app_ui_scale_mode'), liveMode);
    });

    test('apply prunes orphan live prefs but preserves excluded ones',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('A');

      await db.setPref('font_size', '16');
      await repo.snapshotCurrentSettings(pid); // snapshot = {font_size: 16}

      // Mutate live state AFTER the snapshot so a no-op apply would fail.
      await db.setPref('font_size', '99');
      await db.setPref('stray_key', 'leftover');
      await db.setPref('active_profile_id', '7');

      await repo.applyProfile(pid);

      expect(await db.getPref('font_size'), '16'); // restored over live 99
      expect(await db.getPref('stray_key'), isNull); // pruned (not in snapshot)
      expect(await db.getPref('active_profile_id'), '7'); // excluded → kept
    });

    test('resolveProfileId precedence: book > mediaType > active', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final a = await repo.createProfile('A');
      final b = await repo.createProfile('B');
      final c = await repo.createProfile('C');
      await repo.setActiveProfileId(c);
      await repo.setMediaTypeBinding('reader', b);
      await repo.setBookProfile('book/1', a);

      expect(
          await repo.resolveProfileId(bookUid: 'book/1', mediaType: 'reader'),
          a); // book binding wins
      expect(
          await repo.resolveProfileId(
              bookUid: 'book/none', mediaType: 'reader'),
          b); // mediaType wins when no book binding
      expect(await repo.resolveProfileId(bookUid: null, mediaType: null),
          c); // active fallback
      expect(
          await repo.resolveProfileId(
              bookUid: 'book/none', mediaType: 'unbound'),
          c); // full fallthrough to active
    });

    test('deleteProfile of the active profile reassigns AND applies remaining',
        () async {
      final db = await _openDb();
      final repo = _repo(db);

      final a = await repo.createProfile('A');
      await db.setPref('font_size', '10');
      await repo.snapshotCurrentSettings(a);

      final b = await repo.createProfile('B');
      await db.setPref('font_size', '22');
      await repo.snapshotCurrentSettings(b);
      await repo.setActiveProfileId(b);

      await repo.deleteProfile(b);

      expect(await repo.getActiveProfileId(), a);
      expect(await db.getProfileById(b), isNull);
      // font_size == '10' proves applyProfile(a) ran, not just the id swap.
      expect(await db.getPref('font_size'), '10');
    });

    test('deleteProfile is a no-op when only one profile remains', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final a = await repo.createProfile('Only');
      await repo.setActiveProfileId(a);

      await repo.deleteProfile(a);

      expect(await db.getProfileById(a), isNotNull);
      expect(await repo.getActiveProfileId(), a);
    });

    test('copyProfile duplicates snapshot rows under a new id', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final src = await repo.createProfile('Src');
      await db.setPref('font_size', '16');
      await repo.snapshotCurrentSettings(src);

      final dst = await repo.copyProfile(src, 'Dst');

      expect(dst, isNot(src));
      expect((await db.getProfileById(dst))!.name, 'Dst');
      final fontRows = (await db.getProfileSettings(dst))
          .where((r) => r.category == 'pref' && r.key == 'font_size');
      expect(fontRows, hasLength(1));
      expect(fontRows.single.value, '16');
    });

    test('ensureDefaultProfile bootstraps an empty DB from live settings',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      await db.setPref('font_size', '13');

      await repo.ensureDefaultProfile();

      final profiles = await db.getAllProfiles();
      expect(profiles, hasLength(1));
      expect(profiles.single.name, 'Default');
      expect(await repo.getActiveProfileId(), profiles.single.id);
      final fontRows = (await db.getProfileSettings(profiles.single.id))
          .where((r) => r.category == 'pref' && r.key == 'font_size');
      expect(fontRows.single.value, '13');
    });
  });

  group('ProfileRepository invalid-id guard (HBK regression)', () {
    test('snapshotCurrentSettings(-1) is a no-op, writes no orphan rows',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      await db.setPref('font_size', '16');

      // Must not throw and must not write profile_settings for the sentinel id.
      await repo.snapshotCurrentSettings(-1);

      expect(await db.getProfileSettings(-1), isEmpty);
    });

    test('applyProfile(-1) must NOT wipe live prefs (data-loss guard)',
        () async {
      final db = await _openDb();
      final repo = _repo(db);
      await db.setPref('font_size', '16');
      await db.setPref('theme', 'dark');

      // Without the guard, the empty snapshot would prune every non-excluded
      // pref, silently deleting the user's live settings.
      await repo.applyProfile(-1);

      expect(await db.getPref('font_size'), '16');
      expect(await db.getPref('theme'), 'dark');
    });
  });

  group('applyProfile bumps prefs_version (TODO-855)', () {
    test(
        'a profile switch increments the cross-process prefs-version so the '
        'warm-reuse popup detects it', () async {
      final db = await _openDb();
      final repo = _repo(db);

      // Profile A: font_size = 16, snapshot it.
      final pidA = await repo.createProfile('A');
      await db.setPref('font_size', '16');
      await repo.snapshotCurrentSettings(pidA);

      // Profile B: font_size = 24, snapshot it.
      final pidB = await repo.createProfile('B');
      await db.setPref('font_size', '24');
      await repo.snapshotCurrentSettings(pidB);

      Future<int> readVersion() async {
        final String? raw =
            await db.getPref(PreferencesRepository.prefsVersionKey);
        return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
      }

      final int before = await readVersion();

      // Switch to A: applyProfile writes prefs straight through _db.setPref,
      // bypassing PreferencesRepository.setPref, so the bump must be done by
      // applyProfile itself.
      await repo.applyProfile(pidA);
      expect(await db.getPref('font_size'), '16');

      final int after = await readVersion();
      expect(after, greaterThan(before),
          reason:
              'profile switch must bump prefs_version for :popup detection');

      // A second switch bumps again (monotonic).
      await repo.applyProfile(pidB);
      final int after2 = await readVersion();
      expect(after2, greaterThan(after));
    });

    test(
        'prefs_version is NOT captured into a profile snapshot (stays '
        'app-global and monotonic)', () async {
      final db = await _openDb();
      final repo = _repo(db);
      final pid = await repo.createProfile('A');

      await db.setPref('font_size', '16');
      // Bump the version a few times via the repository write path.
      final prefs = PreferencesRepository(db);
      addTearDown(prefs.dispose);
      await prefs.loadFromDb();
      await prefs.setPref('font_size', '16');
      await prefs.setPref('theme', 'dark');

      await repo.snapshotCurrentSettings(pid);

      final rows = await db.getProfileSettings(pid);
      final hasVersion = rows.any((r) =>
          r.category == 'pref' &&
          r.key == PreferencesRepository.prefsVersionKey);
      expect(hasVersion, isFalse,
          reason: 'prefs_version must be excluded from profile snapshots');
    });
  });
}
