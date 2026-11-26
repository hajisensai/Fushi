import 'package:fushi_engine/profile/combo/combo_migration.dart';
import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';
import 'package:test/test.dart';

const SettingKey kDeck = SettingKey('anki', 'selectedDeckName');
const SettingKey kTheme = SettingKey('pref', 'app_theme_key');
const SettingKey kOther = SettingKey('pref', 'home_layout');
const SettingKey kRole = SettingKey(kComboSyntheticCategory, kComboRoleKey);
const SettingKey kShared = SettingKey(
  kComboSyntheticCategory,
  kComboSrsSharedUidKey,
);
const SettingKey kSrsLib = SettingKey(
  kComboSyntheticCategory,
  kComboSrsLibrarySettingKey,
);

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
    SettingsNode.group(
      id: 'srs',
      children: <SettingsNode>[
        SettingsNode.leaf(
          id: kComboSrsLibraryLeafId,
          syntheticDefaults: <String, String>{
            kComboSrsLibrarySettingKey: 'shared',
          },
          diffable: false,
        ),
      ],
    ),
    // 与 app 的「其他设置」同口径：作品层不可拆。
    SettingsNode.leaf(
      id: 'other',
      splittableAt: <ComboScope>{ComboScope.mediaType, ComboScope.language},
    ),
  ],
  fallbackLeafId: 'other',
  isExcluded: (SettingKey k) => k.category == kComboSyntheticCategory,
);

ComboMigrationProfile legacy(int id, Map<SettingKey, String> rows) =>
    ComboMigrationProfile(id: id, uid: 'u$id', name: 'P$id', rows: rows);

final Map<SettingKey, String> base = <SettingKey, String>{
  kDeck: 'Mining',
  kTheme: 'dark',
  kOther: 'grid',
};

/// 把规划结果落回输入（模拟落库），再规划一次用。
List<ComboMigrationProfile> applyPlan(
  List<ComboMigrationProfile> before,
  ComboMigrationPlan plan,
) => <ComboMigrationProfile>[
  for (final ComboMigrationProfile p in before)
    ComboMigrationProfile(
      id: p.id,
      uid: p.uid,
      name: p.name,
      rows: plan.rewrites[p.id] ?? p.rows,
    ),
];

void main() {
  final SettingsTree tree = buildTree();

  test('单 Profile：成为默认组合、共享库就是它，不出报告；再跑是空操作', () {
    final List<ComboMigrationProfile> input = <ComboMigrationProfile>[
      legacy(1, base),
    ];
    final ComboMigrationPlan plan = planComboMigration(
      tree: tree,
      profiles: input,
      preferredDefaultIds: const <int>[1],
    );
    expect(plan.defaultId, 1);
    expect(plan.rewrites[1], <SettingKey, String>{
      ...base,
      kRole: 'default',
      kShared: 'u1',
    });
    expect(plan.report, isNull);
    expect(plan.srs?.sharedProfile, 'P1');
    expect(
      planComboMigration(
        tree: tree,
        profiles: applyPlan(input, plan),
        preferredDefaultIds: const <int>[1],
      ).isNoop,
      isTrue,
    );
  });

  test('多 Profile：激活的当默认，其余只留与默认不同的叶子；单层解析与原快照逐键一致', () {
    final Map<SettingKey, String> b = <SettingKey, String>{
      ...base,
      kTheme: 'glass',
    };
    final List<ComboMigrationProfile> input = <ComboMigrationProfile>[
      legacy(1, b),
      legacy(2, base),
    ];
    final ComboMigrationPlan plan = planComboMigration(
      tree: tree,
      profiles: input,
      preferredDefaultIds: const <int>[2],
      srsUidsWithData: const <String>{},
    );
    expect(plan.defaultId, 2);
    final DecodedComboRows one = decodeComboRows(tree, plan.rewrites[1]!);
    expect(one.role, ComboRole.named);
    expect(one.document.splitLeafIds, <String>{'theme'});
    final ResolvedSettings resolved = resolveCombos(
      tree: tree,
      defaults: base,
      layers: <ComboLayer>[
        ComboLayer(
          scope: ComboScope.language,
          comboRef: 'u1',
          document: one.document,
        ),
      ],
    );
    for (final MapEntry<SettingKey, String> e in b.entries) {
      expect(resolved.valueOf(e.key), e.value, reason: '${e.key}');
    }
    expect(plan.report!.defaultName, 'P2');
    expect(plan.report!.combos.single.splitLeaves, <String>['theme']);
    expect(
      planComboMigration(
        tree: tree,
        profiles: applyPlan(input, plan),
        preferredDefaultIds: const <int>[2],
      ).isNoop,
      isTrue,
      reason: '幂等',
    );
  });

  test('回退点优先于激活配置；都不中取 id 最小的', () {
    final List<ComboMigrationProfile> input = <ComboMigrationProfile>[
      legacy(1, base),
      legacy(2, base),
      legacy(3, base),
    ];
    expect(
      planComboMigration(
        tree: tree,
        profiles: input,
        preferredDefaultIds: const <int>[3, 2],
      ).defaultId,
      3,
    );
    expect(
      planComboMigration(
        tree: tree,
        profiles: input,
        preferredDefaultIds: const <int>[9],
      ).defaultId,
      1,
    );
  });

  group('复习库（§4.2）', () {
    final List<ComboMigrationProfile> input = <ComboMigrationProfile>[
      legacy(1, base),
      legacy(2, <SettingKey, String>{...base, kDeck: 'Other'}),
      legacy(3, base),
    ];

    test('只有一份有复习数据（不是默认组合）：共享库指向它，谁也不拆', () {
      final ComboMigrationPlan plan = planComboMigration(
        tree: tree,
        profiles: input,
        preferredDefaultIds: const <int>[1],
        srsUidsWithData: const <String>{'u2'},
      );
      expect(plan.rewrites[1]![kShared], 'u2');
      expect(plan.srs!.sharedProfile, 'P2');
      expect(plan.srs!.ownProfiles, isEmpty);
      for (final int id in <int>[2, 3]) {
        expect(
          decodeComboRows(
            tree,
            plan.rewrites[id]!,
          ).document.isSplit(kComboSrsLibraryLeafId),
          isFalse,
        );
      }
    });

    test('多份各有数据：默认组合那份当共享库，其余有数据的拆成独立库', () {
      final ComboMigrationPlan plan = planComboMigration(
        tree: tree,
        profiles: input,
        preferredDefaultIds: const <int>[1],
        srsUidsWithData: const <String>{'u1', 'u2', 'u3'},
      );
      expect(plan.rewrites[1]![kShared], 'u1');
      expect(plan.srs!.ownProfiles, <String>['P2', 'P3']);
      for (final int id in <int>[2, 3]) {
        expect(
          decodeComboRows(
            tree,
            plan.rewrites[id]!,
          ).document.splits[kComboSrsLibraryLeafId],
          <SettingKey, String>{kSrsLib: 'own'},
        );
      }
      expect(
        decodeComboRows(tree, plan.rewrites[3]!).document.splitLeafIds,
        <String>{kComboSrsLibraryLeafId},
        reason: '设置与默认相同，只拆复习库',
      );
    });

    test('复习库读不了：设置照迁，共享库不写（待定），能读时再补定且只加复习库拆分', () {
      final ComboMigrationPlan first = planComboMigration(
        tree: tree,
        profiles: input,
        preferredDefaultIds: const <int>[1],
      );
      expect(first.rewrites[1]!.containsKey(kShared), isFalse);
      expect(first.srs, isNull);
      expect(first.report!.srs, isNull);
      final List<ComboMigrationProfile> migrated = applyPlan(input, first);
      final ComboMigrationPlan second = planComboMigration(
        tree: tree,
        profiles: migrated,
        preferredDefaultIds: const <int>[1],
        srsUidsWithData: const <String>{'u1', 'u2'},
      );
      expect(second.report, isNull, reason: '只补复习库，不重出设置报告');
      expect(second.srs!.ownProfiles, <String>['P2']);
      expect(second.rewrites.keys.toSet(), <int>{1, 2});
      final DecodedComboRows two = decodeComboRows(tree, second.rewrites[2]!);
      expect(two.document.splitLeafIds, <String>{
        'deck',
        kComboSrsLibraryLeafId,
      });
      expect(two.document.splits['deck'], <SettingKey, String>{kDeck: 'Other'});
    });
  });

  test('两份默认组合（各有默认的合并）：留偏好的那份，另一份降级成差异', () {
    final List<ComboMigrationProfile> input = <ComboMigrationProfile>[
      ComboMigrationProfile(
        id: 1,
        uid: 'u1',
        name: 'Mine',
        rows: <SettingKey, String>{...base, kRole: 'default', kShared: 'u1'},
      ),
      ComboMigrationProfile(
        id: 2,
        uid: 'u2',
        name: 'Theirs',
        rows: <SettingKey, String>{
          ...base,
          kTheme: 'light',
          kRole: 'default',
          kShared: 'u2',
        },
      ),
    ];
    final ComboMigrationPlan plan = planComboMigration(
      tree: tree,
      profiles: input,
      preferredDefaultIds: const <int>[1],
    );
    expect(plan.defaultId, 1);
    expect(plan.rewrites.containsKey(1), isFalse, reason: '留下的默认一行不动');
    final DecodedComboRows two = decodeComboRows(tree, plan.rewrites[2]!);
    expect(two.role, ComboRole.named);
    expect(two.document.splitLeafIds, <String>{
      'theme',
      kComboSrsLibraryLeafId,
    });
    expect(two.document.splits[kComboSrsLibraryLeafId], <SettingKey, String>{
      kSrsLib: 'own',
    }, reason: '它的复习库不是留下那份的共享库：保持独立');
  });

  test('更新版本写的角色（不认识）：一行不碰，也不能当默认', () {
    final List<ComboMigrationProfile> input = <ComboMigrationProfile>[
      ComboMigrationProfile(
        id: 1,
        uid: 'u1',
        name: 'Future',
        rows: <SettingKey, String>{kRole: 'quantum', kTheme: 'x'},
      ),
      legacy(2, base),
    ];
    final ComboMigrationPlan plan = planComboMigration(
      tree: tree,
      profiles: input,
      preferredDefaultIds: const <int>[1],
    );
    expect(plan.defaultId, 2);
    expect(plan.rewrites.containsKey(1), isFalse);
  });

  test('报告：语言 + 媒体类型冲突列出生效值变了的叶子；作品层不可拆的拆分列为忽略', () {
    final List<ComboMigrationProfile> input = <ComboMigrationProfile>[
      legacy(1, base),
      // 语言层：换了主题。
      legacy(2, <SettingKey, String>{...base, kTheme: 'glass'}),
      // 媒体类型层：换了牌组（旧版整包取语言那份 = 牌组是默认的；新版取它的）。
      legacy(3, <SettingKey, String>{...base, kDeck: 'Video'}),
      // 绑在作品上、改了「其他设置」：作品层不接管。
      legacy(4, <SettingKey, String>{...base, kOther: 'list'}),
    ];
    final ComboMigrationPlan plan = planComboMigration(
      tree: tree,
      profiles: input,
      preferredDefaultIds: const <int>[1],
      bindings: const ComboMigrationBindings(
        language: <String, int>{'ja': 2},
        mediaType: <String, int>{'video': 3, 'epub': 2},
        work: <String, int>{'book-a': 4, 'book-b': 4},
      ),
    );
    final ComboMigrationReport report = plan.report!;
    expect(report.conflicts, hasLength(1));
    final ComboBindingConflict c = report.conflicts.single;
    expect(c.languageTag, 'ja');
    expect(c.mediaType, 'video');
    expect(c.languageProfile, 'P2');
    expect(c.mediaTypeProfile, 'P3');
    expect(c.leaves, <String>['deck'], reason: '主题两层都取语言那份，没变');
    expect(report.ignored, hasLength(1));
    expect(report.ignored.single.profile, 'P4');
    expect(report.ignored.single.scope, ComboScope.work);
    expect(report.ignored.single.bindings, 2);
    expect(report.ignored.single.leaves, <String>['other']);

    final ComboMigrationReport? back = ComboMigrationReport.tryParse(
      report.toJson(),
    );
    expect(back!.toJson(), report.toJson(), reason: 'JSON 往返');
    expect(ComboMigrationReport.tryParse(<String, Object?>{'v': 99}), isNull);
  });

  test('rebaseComboDocument：已拆的保持拆分、新差异拆出、合成叶子沿用原值', () {
    final ComboDocument existing = ComboDocument(
      <String, Map<SettingKey, String>>{
        'deck': <SettingKey, String>{kDeck: 'Mining'},
        kComboSrsLibraryLeafId: <SettingKey, String>{kSrsLib: 'own'},
      },
    );
    final ComboDocument doc = rebaseComboDocument(
      tree: tree,
      existing: existing,
      base: base,
      effective: <SettingKey, String>{...base, kTheme: 'glass'},
    );
    expect(doc.splitLeafIds, <String>{'deck', 'theme', kComboSrsLibraryLeafId});
    expect(doc.splits['deck'], <SettingKey, String>{kDeck: 'Mining'});
    expect(doc.splits['theme'], <SettingKey, String>{kTheme: 'glass'});
    expect(doc.splits[kComboSrsLibraryLeafId], <SettingKey, String>{
      kSrsLib: 'own',
    });
  });
}
