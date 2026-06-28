import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/profile/profile_keys.dart';
import 'package:hibiki/src/profile/profile_repository.dart';

// TODO-930 M1-M3: behaviour guards for the multi-custom-theme UI integration
// layer. M0 (data model + legacy migration) is covered by
// theme_notifier_test.dart; this file pins what the swatch row and editor
// depend on: pinned-id selection (M1), new+delete flow (M2), per-Profile
// snapshot carry of the new keys (M3).

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

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

ThemeNotifier _notifier(HibikiDatabase db) {
  int counter = 0;
  return ThemeNotifier(
    db,
    () => const TextTheme(),
    customThemeIdGenerator: () => 'ct-${counter++}',
  );
}

void main() {
  late HibikiDatabase db;
  late ThemeNotifier n;

  setUp(() async {
    db = _testDb();
    n = _notifier(db);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    n.dispose();
    await db.close();
  });

  group('M1: per-swatch pinned selection', () {
    test(
        'setAppThemeKey(custom-theme:id) pins activeCustomThemeEntry to that '
        'id regardless of selectedCustomThemeId', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      expect(n.selectedCustomThemeId, 'b');

      await n.setAppThemeKey('custom-theme:a');
      expect(n.appThemeKey, 'custom-theme:a');
      final CustomThemeEntry? active = n.activeCustomThemeEntry;
      expect(active, isNotNull);
      expect(active!.id, 'a');
      expect(active.seed, 0xFF111111);
    });

    test('bare custom-theme key falls back to selected entry', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      await n.selectCustomTheme('a');
      await n.setAppThemeKey('custom-theme');
      expect(n.activeCustomThemeEntry!.id, 'a');
    });

    test('pinned key for a deleted id falls back to selected/first', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      await n.setAppThemeKey('custom-theme:zzz');
      expect(n.activeCustomThemeEntry!.id, 'b');
    });
  });

  group('M2: editor new + delete flow', () {
    test('upsert of a brand-new entry adds it and selects it', () async {
      const CustomThemeEntry fresh =
          CustomThemeEntry(id: 'new', name: 'My theme', seed: 0xFF445566);
      await n.upsertCustomTheme(fresh);
      expect(n.customThemes.map((CustomThemeEntry e) => e.id), <String>['new']);
      expect(n.selectedCustomThemeId, 'new');
      expect(n.customThemeById('new')!.name, 'My theme');
    });

    test('upsert replacing an existing id keeps selection + replaces fields',
        () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A renamed', seed: 0xFF999999));
      expect(n.customThemes, hasLength(1));
      expect(n.customThemeById('a')!.name, 'A renamed');
      expect(n.customThemeById('a')!.seed, 0xFF999999);
      expect(n.selectedCustomThemeId, 'a');
    });

    test(
        'deleting the selected entry falls back to the first remaining '
        '(decision 1)', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b', name: 'B', seed: 0xFF222222));
      await n.selectCustomTheme('b');
      await n.deleteCustomTheme('b');
      expect(n.customThemes.map((CustomThemeEntry e) => e.id), <String>['a']);
      expect(n.selectedCustomThemeId, 'a');
    });

    test('deleting the last entry clears selection (decision 1/4)', () async {
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a', name: 'A', seed: 0xFF111111));
      await n.deleteCustomTheme('a');
      expect(n.customThemes, isEmpty);
      expect(n.selectedCustomThemeId, isNull);
    });
  });

  group('M3: per-Profile snapshot carries multi-theme keys', () {
    test(
        'custom_themes + selected_custom_theme_id are NOT excluded from '
        'profile snapshots', () {
      expect(
        ProfileKeys.isExcludedPref(ThemeNotifier.customThemesPrefKey),
        isFalse,
      );
      expect(
        ProfileKeys.isExcludedPref(ThemeNotifier.selectedCustomThemeIdPrefKey),
        isFalse,
      );
    });

    test('two profiles keep independent custom theme lists across a switch',
        () async {
      final ProfileRepository repo =
          ProfileRepository(db, _FakeAnkiRepository());

      final int profileA = await repo.createProfile('A');
      final int profileB = await repo.createProfile('B');

      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a1', name: 'A1', seed: 0xFF111111));
      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'a2', name: 'A2', seed: 0xFF222222));
      await n.selectCustomTheme('a1');
      await repo.snapshotCurrentSettings(profileA);

      await repo.applyProfile(profileB);
      await n.refreshFromDb();
      expect(n.customThemes, isEmpty,
          reason: 'switching to a fresh profile should not leak A themes');

      await n.upsertCustomTheme(
          const CustomThemeEntry(id: 'b1', name: 'B1', seed: 0xFF333333));
      await repo.snapshotCurrentSettings(profileB);

      await repo.applyProfile(profileA);
      await n.refreshFromDb();
      expect(n.customThemes.map((CustomThemeEntry e) => e.id),
          <String>['a1', 'a2']);
      expect(n.selectedCustomThemeId, 'a1');
      expect(n.customThemeById('a2')!.seed, 0xFF222222);

      await repo.applyProfile(profileB);
      await n.refreshFromDb();
      expect(n.customThemes.map((CustomThemeEntry e) => e.id), <String>['b1']);
    });
  });
}
