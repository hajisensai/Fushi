/// Fushi 的「组合」设置树登记（拍板台 design-combo-node-split，阶段 1：只登记 + 解析，
/// 不接 UI、不改持久化）。
///
/// 每个随 Profile 走的设置键在这里唯一归属一个叶子；没登记的键落「其他设置」兜底叶子，
/// 设备本地 / 凭据键（[ProfileKeys.isExcludedPref]）不归组合管理。键集合一律引用各自的
/// 单一真相源（主题键 [ThemeNotifier.isProfileThemePrefKey]、作品级键集合
/// [WorkProfileScope]、Anki 快照字段 [ProfileKeys.ankiSettingsToMap]），不抄清单。
///
/// 节点 id 是持久化名（组合记「哪些节点单独设置了」按 id 存），定下后冻结；新增设置要么
/// 落进已有叶子的匹配规则，要么新开叶子——`fushi_settings_tree_test.dart` 守卫会查。
/// 设计见 `docs/specs/2026-11-23-combo-settings-tree-design.md`。
library;

import 'package:fushi_engine/media/media_pref_keys.dart'
    show dbSourcePrefKey, kReaderSourcePersistedKey;
import 'package:fushi_engine/profile/combo/settings_tree.dart';

import 'package:fushi/src/models/preferences_repository.dart'
    show PreferencesRepository, kFloatingLyricWindowRectPrefKey;
import 'package:fushi/src/models/theme_notifier.dart' show ThemeNotifier;
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi/src/reader/reader_settings.dart';

/// 叶子 id（持久化名，冻结）。
abstract final class FushiComboNode {
  static const String mining = 'mining';
  static const String miningTarget = 'mining.target';
  static const String miningDeck = 'mining.deck';
  static const String miningNoteType = 'mining.note_type';
  static const String miningTagsDupes = 'mining.tags_dupes';
  static const String miningCardContent = 'mining.card_content';

  static const String appearance = 'appearance';
  static const String appearanceTheme = 'appearance.theme';
  static const String appearanceReaderStyle = 'appearance.reader_style';
  static const String appearanceFonts = 'appearance.fonts';
  static const String appearanceSubtitles = 'appearance.subtitles';

  static const String dictionary = 'dictionary';

  static const String input = 'input';
  static const String inputShortcuts = 'input.shortcuts';

  static const String srs = 'srs';
  static const String srsLibrary = 'srs.library';

  static const String other = 'other';
}

/// 复习库归属的合成设置键（category [kComboSyntheticCategory]）。值见
/// [kComboSrsLibraryShared]；拆成独立复习库的组合在这一叶子上存 [kComboSrsLibraryOwn]，
/// 复习集合沿用该组合自己的 `profiles.uid`（拍板台 design-srs-shared-library 方案 a）。
const String kComboSrsLibraryKey = 'srs_library';

/// 默认：整个用户库共用一份复习库（默认组合的 uid 那份集合）。
const String kComboSrsLibraryShared = 'shared';

/// 这个组合拆出了独立复习库（用它自己的 uid 当集合身份，沿用现有实体归属闸）。
const String kComboSrsLibraryOwn = 'own';

/// 作品层能拆的叶子 = 今天作品会话覆盖层接管的那些（[WorkProfileScope.isWorkScopedPrefKey]
/// 的范围），外加制卡（今天作品会话已覆盖 Anki 字段）与词典（今天作品会话已过滤查词词典）。
const Set<ComboScope> _allLayers = <ComboScope>{
  ComboScope.work,
  ComboScope.mediaType,
  ComboScope.language,
};

/// 「其他设置」与快捷键今天只随整包切换（媒体类型 / 语言绑定）生效，作品会话从不接管——
/// 新模型保持这个边界，不允许在作品上拆。
const Set<ComboScope> _bindingOnlyLayers = <ComboScope>{
  ComboScope.mediaType,
  ComboScope.language,
};

final String _readerPrefix = dbSourcePrefKey(kReaderSourcePersistedKey, '');

String _readerKey(String shortKey) =>
    dbSourcePrefKey(kReaderSourcePersistedKey, shortKey);

const String _pref = ProfileKeys.categoryPref;
const String _anki = ProfileKeys.categoryAnki;

/// Fushi 设置树（进程内单例，结构只读）。
final SettingsTree fushiSettingsTree = _buildFushiSettingsTree();

SettingsTree _buildFushiSettingsTree() {
  final Set<String> fontKeys = <String>{
    for (final String k in ReaderSettings.fontPersistenceKeys) _readerKey(k),
  };
  return SettingsTree(
    roots: <SettingsNode>[
      SettingsNode.group(
        id: FushiComboNode.mining,
        children: <SettingsNode>[
          const SettingsNode.leaf(
            id: FushiComboNode.miningTarget,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _pref,
                keys: <String>{PreferencesRepository.srsMiningTargetKey},
              ),
            ],
          ),
          const SettingsNode.leaf(
            id: FushiComboNode.miningDeck,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _anki,
                keys: <String>{'selectedDeckId', 'selectedDeckName'},
              ),
              SettingKeyMatcher(
                category: _pref,
                keys: <String>{'srs_mining_deck_id'},
              ),
            ],
          ),
          // 笔记类型与字段映射必须同进同出：字段映射只对它那个笔记类型有意义。
          const SettingsNode.leaf(
            id: FushiComboNode.miningNoteType,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _anki,
                keys: <String>{
                  'selectedNoteTypeId',
                  'selectedNoteTypeName',
                  'fieldMappings',
                },
              ),
              SettingKeyMatcher(
                category: _pref,
                keys: <String>{
                  'srs_mining_note_type_id',
                  'srs_mining_field_mappings',
                },
              ),
            ],
          ),
          const SettingsNode.leaf(
            id: FushiComboNode.miningTagsDupes,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _anki,
                keys: <String>{
                  'tags',
                  'tagIncludeHibiki',
                  'tagIncludeCategory',
                  'tagNestTitleUnderCategory',
                  'allowDupes',
                  'overwriteScope',
                  'duplicateScope',
                },
              ),
            ],
          ),
          const SettingsNode.leaf(
            id: FushiComboNode.miningCardContent,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _anki,
                keys: <String>{'compactGlossaries', 'embedMedia'},
              ),
            ],
          ),
        ],
      ),
      SettingsNode.group(
        id: FushiComboNode.appearance,
        children: <SettingsNode>[
          const SettingsNode.leaf(
            id: FushiComboNode.appearanceTheme,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _pref,
                test: ThemeNotifier.isProfileThemePrefKey,
              ),
            ],
          ),
          SettingsNode.leaf(
            id: FushiComboNode.appearanceFonts,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(category: _pref, keys: fontKeys),
            ],
          ),
          SettingsNode.leaf(
            id: FushiComboNode.appearanceReaderStyle,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _pref,
                prefixes: <String>[_readerPrefix],
                except: <String>{
                  ...fontKeys,
                  ...WorkProfileScope.appLevelReaderPrefKeys,
                },
              ),
            ],
          ),
          const SettingsNode.leaf(
            id: FushiComboNode.appearanceSubtitles,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _pref,
                keys: WorkProfileScope.videoSubtitleStylePrefKeys,
                prefixes: <String>['floating_lyric_'],
                except: <String>{kFloatingLyricWindowRectPrefKey},
              ),
            ],
          ),
        ],
      ),
      // 一行一本词典：Profile 只拥有「怎么排、开不开」，不拥有「装了哪些」（BUG-1994，
      // `applyProfile` 对快照里没有的词典行保持当前值）——缺行逐行继承。
      const SettingsNode.leaf(
        id: FushiComboNode.dictionary,
        absentKeysInherit: true,
        matchers: <SettingKeyMatcher>[
          SettingKeyMatcher.category(ProfileKeys.categoryDictionaryMeta),
          SettingKeyMatcher.category(ProfileKeys.categoryRemoteDictionaryMeta),
        ],
      ),
      SettingsNode.group(
        id: FushiComboNode.input,
        children: <SettingsNode>[
          SettingsNode.leaf(
            id: FushiComboNode.inputShortcuts,
            splittableAt: _bindingOnlyLayers,
            matchers: <SettingKeyMatcher>[
              SettingKeyMatcher(
                category: _pref,
                keys: WorkProfileScope.appLevelReaderPrefKeys,
              ),
            ],
          ),
        ],
      ),
      const SettingsNode.group(
        id: FushiComboNode.srs,
        children: <SettingsNode>[
          SettingsNode.leaf(
            id: FushiComboNode.srsLibrary,
            splittableAt: _allLayers,
            syntheticDefaults: <String, String>{
              kComboSrsLibraryKey: kComboSrsLibraryShared,
            },
            diffable: false,
          ),
        ],
      ),
      const SettingsNode.leaf(
        id: FushiComboNode.other,
        splittableAt: _bindingOnlyLayers,
      ),
    ],
    fallbackLeafId: FushiComboNode.other,
    isExcluded: _isExcludedFromCombos,
  );
}

/// 不归组合管理的键：设备本地 / 凭据 / 本安装状态（与 Profile 快照同一判据），以及只在
/// 旧快照里出现、迁移前要先 [normalizeLegacySettingKey] 的旧 category。
bool _isExcludedFromCombos(SettingKey key) {
  if (key.category == _pref) return ProfileKeys.isExcludedPref(key.key);
  return key.category == ProfileKeys.categoryDictionary ||
      key.category == ProfileKeys.categoryReader;
}

/// 把 v2 之前快照里的旧 category 行换成今天 `applyProfile` 落到的 pref 键（与
/// `ProfileRepository.applyProfile` 的旧 category 分支同一映射）；其余原样返回。
///
/// 迁移成差异前必须先过这一步，否则旧行会被当作设备本地键丢掉。
SettingKey normalizeLegacySettingKey(SettingKey key) {
  switch (key.category) {
    case ProfileKeys.categoryDictionary:
      return SettingKey(_pref, key.key);
    case ProfileKeys.categoryReader:
      return SettingKey(_pref, _readerKey(key.key));
    default:
      return key;
  }
}
