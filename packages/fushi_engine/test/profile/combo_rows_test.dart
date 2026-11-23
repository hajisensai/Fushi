import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';
import 'package:test/test.dart';

const SettingKey kDeck = SettingKey('anki', 'selectedDeckName');
const SettingKey kTheme = SettingKey('pref', 'app_theme_key');
const SettingKey kOther = SettingKey('pref', 'home_layout');
const SettingKey kSrsLib = SettingKey(kComboSyntheticCategory, 'srs_library');
const SettingKey kRole = SettingKey(kComboSyntheticCategory, kComboRoleKey);

SettingsTree buildTree() => SettingsTree(
  roots: const <SettingsNode>[
    SettingsNode.leaf(
      id: 'deck',
      matchers: <SettingKeyMatcher>[
        SettingKeyMatcher(category: 'anki', keys: <String>{'selectedDeckName'}),
      ],
    ),
    SettingsNode.leaf(
      id: 'theme',
      matchers: <SettingKeyMatcher>[
        SettingKeyMatcher(category: 'pref', keys: <String>{'app_theme_key'}),
      ],
    ),
    SettingsNode.leaf(
      id: 'srs',
      syntheticDefaults: <String, String>{'srs_library': 'shared'},
      diffable: false,
    ),
    SettingsNode.leaf(id: 'other'),
  ],
  fallbackLeafId: 'other',
  // 与 app 的登记同口径：combo category 里除合成项外都是格式元数据。
  isExcluded: (SettingKey k) => k.category == kComboSyntheticCategory,
);

void main() {
  final SettingsTree tree = buildTree();

  test('没有 role 行 = 存量整份快照：值原样、文档为空', () {
    final DecodedComboRows d = decodeComboRows(tree, <SettingKey, String>{
      kDeck: 'Mining',
      kTheme: 'dark',
    });
    expect(d.isComboFormat, isFalse);
    expect(d.document.splits, isEmpty);
    expect(d.values, <SettingKey, String>{kDeck: 'Mining', kTheme: 'dark'});
  });

  test('编码 → 解码往返：被拆叶子（含拆了但键全未设置）原样回来', () {
    final ComboDocument doc = ComboDocument(<String, Map<SettingKey, String>>{
      'theme': <SettingKey, String>{kTheme: 'glass'},
      'deck': const <SettingKey, String>{},
      'srs': <SettingKey, String>{kSrsLib: 'own'},
    });
    final Map<SettingKey, String> rows = encodeComboRows(
      tree,
      doc,
      role: ComboRole.named,
    );
    expect(rows[kRole], 'named');
    expect(rows[const SettingKey(kComboSyntheticCategory, 'split:deck')], '1');
    final DecodedComboRows d = decodeComboRows(tree, rows);
    expect(d.role, ComboRole.named);
    expect(d.document.splitLeafIds, <String>{'theme', 'deck', 'srs'});
    expect(d.document.splits['theme'], <SettingKey, String>{kTheme: 'glass'});
    expect(d.document.splits['deck'], isEmpty);
    expect(d.document.splits['srs'], <SettingKey, String>{kSrsLib: 'own'});
    expect(d.values.containsKey(kRole), isFalse, reason: '元数据行不是设置值');
  });

  test('混进叶子的别家键不写出去；没有标记的叶子的残留行解码时不算拆分', () {
    final Map<SettingKey, String> rows = encodeComboRows(
      tree,
      ComboDocument(<String, Map<SettingKey, String>>{
        'theme': <SettingKey, String>{kTheme: 'glass', kDeck: 'leak'},
      }),
      role: ComboRole.workLocal,
    );
    expect(rows.containsKey(kDeck), isFalse);
    final DecodedComboRows d = decodeComboRows(tree, <SettingKey, String>{
      ...rows,
      kOther: 'stray',
    });
    expect(d.role, ComboRole.workLocal);
    expect(d.document.splitLeafIds, <String>{'theme'});
  });

  test('不认识的叶子标记（更新版本加的叶子）忽略，不抛', () {
    final DecodedComboRows d = decodeComboRows(tree, <SettingKey, String>{
      kRole: 'named',
      const SettingKey(kComboSyntheticCategory, 'split:future.leaf'): '1',
    });
    expect(d.document.splits, isEmpty);
  });

  test('默认组合存全量值：解码得值、不当差异；不能按差异编码', () {
    final DecodedComboRows d = decodeComboRows(tree, <SettingKey, String>{
      kRole: 'default',
      const SettingKey(kComboSyntheticCategory, kComboSrsSharedUidKey): 'u1',
      kTheme: 'dark',
    });
    expect(d.role, ComboRole.defaults);
    expect(d.srsSharedUid, 'u1');
    expect(d.document.splits, isEmpty);
    expect(d.values, <SettingKey, String>{kTheme: 'dark'});
    expect(
      () =>
          encodeComboRows(tree, ComboDocument.empty, role: ComboRole.defaults),
      throwsArgumentError,
    );
  });

  test('不认识的 role 值按「不认识的格式」：isComboFormat 为 false', () {
    final DecodedComboRows d = decodeComboRows(tree, <SettingKey, String>{
      kRole: 'from_the_future',
      kTheme: 'dark',
    });
    expect(d.isComboFormat, isFalse);
  });
}
