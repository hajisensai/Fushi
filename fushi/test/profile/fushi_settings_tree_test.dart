import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart'
    show PreferencesRepository, kFloatingLyricWindowRectPrefKey;
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/profile/combo/fushi_settings_tree.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_pref_keys.dart'
    show dbSourcePrefKey, kReaderSourcePersistedKey;
import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';

import '../helpers/fake_anki_repository.dart';

String _reader(String shortKey) =>
    dbSourcePrefKey(kReaderSourcePersistedKey, shortKey);

SettingKey _p(String key) => SettingKey(ProfileKeys.categoryPref, key);

/// 有代表性的随 Profile 走的偏好键（每个叶子至少一个，含作品级键全部家族）。
final Map<String, String> _profilePrefs = <String, String>{
  'app_theme_key': 'blue',
  'brightness_mode': 'dark',
  ThemeNotifier.readerPaperLightPrefKey: '#fff',
  'custom_theme_legacy': '{}',
  _reader('font_size'): '20',
  _reader('line_height'): '1.8',
  _reader(ReaderSettings.fontCatalogKey): '[]',
  _reader(ReaderSettings.fontTargetsKey): '{}',
  _reader(ReaderSettings.fontKeyVideoSubtitle): '[]',
  ...<String, String>{
    for (final String k in WorkProfileScope.appLevelReaderPrefKeys) k: '1',
  },
  'video_subtitle_style': '{}',
  'video_respect_ass_style': 'true',
  'floating_lyric_font_size': '24',
  PreferencesRepository.srsMiningTargetKey: 'srs',
  'srs_mining_deck_id': 'u:1',
  'srs_mining_note_type_id': 'u:2',
  'srs_mining_field_mappings': '{}',
  'home_layout_style': 'grid',
};

/// 设备本地 / 本安装状态键：绝不进组合。
const List<String> _deviceLocalPrefs = <String>[
  'app_ui_scale',
  'active_profile_id',
  'eink_mode',
  'download_save_root',
  kFloatingLyricWindowRectPrefKey,
];

void main() {
  final SettingsTree tree = fushiSettingsTree;

  group('fushiSettingsTree registry', () {
    test('every Anki snapshot field lands in a mining leaf, none in the '
        'fallback', () {
      final Map<String, String> anki = ProfileKeys.ankiSettingsToMap(
        const AnkiSettings(),
      );
      for (final String k in anki.keys) {
        final SettingKey key = SettingKey(ProfileKeys.categoryAnki, k);
        final List<String> claimed = tree.claimingLeaves(key);
        expect(claimed, hasLength(1), reason: '$key');
        expect(claimed.single, startsWith('${FushiComboNode.mining}.'));
      }
      // 笔记类型与字段映射同一叶子：字段映射只对它那个笔记类型有意义。
      expect(
        tree.leafOf(const SettingKey('anki', 'fieldMappings')),
        tree.leafOf(const SettingKey('anki', 'selectedNoteTypeId')),
      );
      expect(
        tree.leafOf(_p('srs_mining_field_mappings')),
        FushiComboNode.miningNoteType,
      );
    });

    test('every work-scoped key lands in a leaf splittable at the work '
        'layer; non-work keys do not', () {
      for (final String k in _profilePrefs.keys) {
        final SettingKey key = _p(k);
        final String? leaf = tree.leafOf(key);
        expect(leaf, isNotNull, reason: k);
        final bool workSplittable = tree
            .node(leaf!)
            .splittableAt
            .contains(ComboScope.work);
        expect(
          workSplittable,
          WorkProfileScope.isWorkScopedPrefKey(k),
          reason: '$k -> $leaf',
        );
      }
    });

    test('font keys split from reader style; shortcuts are their own leaf', () {
      for (final String k in ReaderSettings.fontPersistenceKeys) {
        expect(tree.claimingLeaves(_p(_reader(k))), <String>[
          FushiComboNode.appearanceFonts,
        ]);
      }
      expect(
        tree.leafOf(_p(_reader('font_size'))),
        FushiComboNode.appearanceReaderStyle,
      );
      for (final String k in WorkProfileScope.appLevelReaderPrefKeys) {
        expect(tree.claimingLeaves(_p(k)), <String>[
          FushiComboNode.inputShortcuts,
        ]);
      }
      expect(tree.leafOf(_p('home_layout_style')), FushiComboNode.other);
    });

    test('device-local keys and credentials are never combo-managed', () {
      for (final String k in _deviceLocalPrefs) {
        expect(tree.leafOf(_p(k)), isNull, reason: k);
      }
      expect(tree.leafOf(_p('sync_webdav_password')), isNull);
    });

    test('dictionary snapshot categories map to the dictionary leaf', () {
      expect(
        tree.leafOf(
          const SettingKey(ProfileKeys.categoryDictionaryMeta, 'JMdict'),
        ),
        FushiComboNode.dictionary,
      );
      expect(
        tree.leafOf(
          const SettingKey(
            ProfileKeys.categoryRemoteDictionaryMeta,
            'host/JMdict',
          ),
        ),
        FushiComboNode.dictionary,
      );
    });

    test('srs library is a synthetic leaf defaulting to shared, excluded '
        'from snapshot diffs', () {
      final SettingsNode node = tree.node(FushiComboNode.srsLibrary);
      expect(node.diffable, isFalse);
      final ResolvedSettings r = resolveCombos(
        tree: tree,
        defaults: const <SettingKey, String>{},
      );
      expect(
        r.valueOf(
          const SettingKey(kComboSyntheticCategory, kComboSrsLibraryKey),
        ),
        kComboSrsLibraryShared,
      );
    });

    test('legacy snapshot categories normalize to the pref keys applyProfile '
        'restores', () {
      expect(
        normalizeLegacySettingKey(
          const SettingKey(ProfileKeys.categoryReader, 'font_size'),
        ),
        _p(_reader('font_size')),
      );
      expect(
        normalizeLegacySettingKey(
          const SettingKey(ProfileKeys.categoryDictionary, 'x'),
        ),
        _p('x'),
      );
      expect(
        tree.leafOf(const SettingKey(ProfileKeys.categoryReader, 'font_size')),
        isNull,
      );
    });
  });

  group('real ProfileRepository snapshot', () {
    test('every snapshot row is claimed by at most one leaf, and diffing two '
        'snapshots splits only the changed leaves', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final FakeAnkiRepository anki = FakeAnkiRepository();
      final ProfileRepository repo = ProfileRepository(db, anki);
      await db.upsertDictionaryMeta(
        const DictionaryMetadataCompanion(
          name: Value('JMdict'),
          formatKey: Value('yomitan'),
          order: Value(0),
          type: Value('term'),
        ),
      );
      for (final MapEntry<String, String> e in _profilePrefs.entries) {
        await db.setPref(e.key, e.value);
      }
      for (final String k in _deviceLocalPrefs) {
        await db.setPref(k, '1');
      }
      await anki.saveSettings(
        const AnkiSettings(selectedDeckName: 'Default', tags: 'fushi'),
      );

      final int a = await repo.createProfile('A');
      await repo.snapshotCurrentSettings(a);
      final Map<SettingKey, String> snapA = <SettingKey, String>{
        for (final ProfileSettingRow row in await db.getProfileSettings(a))
          normalizeLegacySettingKey(SettingKey(row.category, row.key)):
              row.value,
      };
      expect(snapA, isNotEmpty);
      for (final SettingKey k in snapA.keys) {
        expect(
          tree.claimingLeaves(k).length,
          lessThanOrEqualTo(1),
          reason: '$k claimed by ${tree.claimingLeaves(k)}',
        );
      }
      // 快照本身已剔除设备本地键：分类结果与之一致（没有快照行被判成设备本地）。
      expect(
        snapA.keys.where((SettingKey k) => tree.leafOf(k) == null),
        isEmpty,
      );

      // 建 A 之后才导入的词典：A 的快照里没有这一行。
      await db.upsertDictionaryMeta(
        const DictionaryMetadataCompanion(
          name: Value('Daijirin'),
          formatKey: Value('yomitan'),
          order: Value(1),
          type: Value('term'),
        ),
      );
      await db.setPref('app_theme_key', 'red');
      await anki.saveSettings(
        const AnkiSettings(selectedDeckName: 'Audio cards', tags: 'fushi'),
      );
      final int b = await repo.createProfile('B');
      await repo.snapshotCurrentSettings(b);
      final Map<SettingKey, String> snapB = <SettingKey, String>{
        for (final ProfileSettingRow row in await db.getProfileSettings(b))
          normalizeLegacySettingKey(SettingKey(row.category, row.key)):
              row.value,
      };

      final ComboDocument diff = diffAgainstDefaults(
        tree: tree,
        defaults: snapA,
        snapshot: snapB,
      );
      expect(diff.splitLeafIds, <String>{
        FushiComboNode.appearanceTheme,
        FushiComboNode.miningDeck,
      });
      // 反过来以较新的 B 为默认：A 缺 Daijirin 那一行 = 沿用，不能把 A 误判成「单独
      // 设置了词典」（BUG-1994：Profile 不拥有「装了哪些」）。
      expect(tree.node(FushiComboNode.dictionary).absentKeysInherit, isTrue);
      expect(
        diffAgainstDefaults(
          tree: tree,
          defaults: snapB,
          snapshot: snapA,
        ).splitLeafIds,
        <String>{FushiComboNode.appearanceTheme, FushiComboNode.miningDeck},
      );
      final ResolvedSettings resolved = resolveCombos(
        tree: tree,
        defaults: snapA,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.mediaType,
            comboRef: 'B',
            document: diff,
          ),
        ],
      );
      expect(resolved.valueOf(_p('app_theme_key')), 'red');
      expect(
        resolved.valueOf(const SettingKey('anki', 'selectedDeckName')),
        'Audio cards',
      );
      expect(
        resolved.sourceOf(FushiComboNode.dictionary),
        const ComboSource.defaults(),
      );
    });
  });
}
