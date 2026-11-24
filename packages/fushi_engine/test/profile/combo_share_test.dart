import 'dart:convert';

import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/combo_rows.dart';
import 'package:fushi_engine/profile/combo/combo_share.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';
import 'package:fushi_engine/profile/profile_document.dart';
import 'package:test/test.dart';

const SettingKey kDeck = SettingKey('anki', 'selectedDeckName');
const SettingKey kNoteType = SettingKey('anki', 'selectedNoteTypeName');
const SettingKey kFields = SettingKey('anki', 'fieldMappings');
const SettingKey kTheme = SettingKey('pref', 'app_theme_key');
const SettingKey kOther = SettingKey('pref', 'home_layout');
const SettingKey kSrsLib = SettingKey(kComboSyntheticCategory, 'srs_library');
const SettingKey kRole = SettingKey(kComboSyntheticCategory, kComboRoleKey);
const SettingKey kShared = SettingKey(
  kComboSyntheticCategory,
  kComboSrsSharedUidKey,
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
      id: 'note_type',
      matchers: <SettingKeyMatcher>[
        SettingKeyMatcher(
          category: 'anki',
          keys: <String>{'selectedNoteTypeName', 'fieldMappings'},
        ),
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
          id: 'srs.library',
          syntheticDefaults: <String, String>{'srs_library': 'shared'},
          diffable: false,
        ),
      ],
    ),
    SettingsNode.leaf(id: 'other'),
  ],
  fallbackLeafId: 'other',
  isExcluded: (SettingKey k) => k.category == kComboSyntheticCategory,
);

void main() {
  final SettingsTree tree = buildTree();
  final Map<SettingKey, String> localDefaults = <SettingKey, String>{
    kDeck: 'Mining',
    kNoteType: 'Lapis',
    kFields: '{"a":1}',
    kTheme: 'light',
    kOther: 'grid',
  };

  group('分享 JSON v2', () {
    test('单独设置的叶子按树序列出，合成叶子（复习库归属）不出本机', () {
      final ComboDocument doc = ComboDocument(<String, Map<SettingKey, String>>{
        'theme': <SettingKey, String>{kTheme: 'dark'},
        'deck': <SettingKey, String>{kDeck: 'Video'},
        'srs.library': <SettingKey, String>{kSrsLib: 'own'},
      });
      expect(sharedSplitNodesOf(tree, doc), <String>['deck', 'theme']);
    });

    test('导入：与本机默认不同的叶子 ∪ 对方单独设置的叶子；同值的声明拆分也保留', () {
      final ComboDocument doc = comboDocumentFromShared(
        tree: tree,
        localDefaults: localDefaults,
        values: <SettingKey, String>{...localDefaults, kTheme: 'dark'},
        // deck 与本机默认同值，但对方是有意单独设置的。
        splitNodes: <String>['deck', 'future.leaf', 'srs.library', 'srs'],
      );
      expect(doc.splitLeafIds, <String>{'theme', 'deck'});
      expect(doc.splits['deck'], <SettingKey, String>{kDeck: 'Mining'});
      expect(doc.splits['theme'], <SettingKey, String>{kTheme: 'dark'});
    });

    test('v1 文件（没有声明）：只按本机默认 diff', () {
      final ComboDocument doc = comboDocumentFromShared(
        tree: tree,
        localDefaults: localDefaults,
        values: <SettingKey, String>{...localDefaults, kOther: 'list'},
      );
      expect(doc.splitLeafIds, <String>{'other'});
    });

    test('信封：v2 带 splitNodes 往返；v1 没有（null）；v2 缺省为空；类型不对拒收', () {
      final String json = encodeProfileDocument(
        profileName: 'Video',
        schemaVersion: 1,
        settings: <ProfileSettingEntry>[
          ProfileSettingEntry(category: 'pref', key: 'k', value: 'v'),
        ],
        splitNodes: <String>['deck'],
      );
      final ProfileExport parsed = parseProfileDocument(json);
      expect(parsed.formatVersion, 2);
      expect(parsed.splitNodes, <String>['deck']);

      Map<String, Object?> doc(int version, [Object? splits]) =>
          <String, Object?>{
            'type': ProfileExport.fileType,
            'formatVersion': version,
            'profileName': 'X',
            'settings': <Object?>[],
            'splitNodes': ?splits,
          };
      expect(parseProfileDocument(jsonEncode(doc(1))).splitNodes, isNull);
      expect(parseProfileDocument(jsonEncode(doc(2))).splitNodes, isEmpty);
      expect(
        () => parseProfileDocument(jsonEncode(doc(2, <Object?>[1]))),
        throwsA(isA<ProfileImportException>()),
      );
      expect(
        () => parseProfileDocument(jsonEncode(doc(3))),
        throwsA(isA<ProfileImportException>()),
      );
    });
  });

  group('备份合并', () {
    Map<SettingKey, String> defaultRows(
      Map<SettingKey, String> values, {
      String? shared,
    }) => <SettingKey, String>{
      ...values,
      kRole: ComboRole.defaults.wire,
      kShared: ?shared,
    };

    test('对端默认组合（本机没有同名）：降级成普通组合、按本机默认 diff；自己承载共享库时拆成独立库', () {
      final Map<SettingKey, String>? rows = mergeComboProfileRows(
        tree: tree,
        local: null,
        incoming: defaultRows(<SettingKey, String>{
          ...localDefaults,
          kTheme: 'dark',
        }, shared: 'uid-phone'),
        incomingUid: 'uid-phone',
        localDefaultValues: localDefaults,
      );
      final DecodedComboRows d = decodeComboRows(tree, rows!);
      expect(d.role, ComboRole.named);
      expect(d.document.splitLeafIds, <String>{'theme', 'srs.library'});
      expect(d.document.splits['srs.library'], <SettingKey, String>{
        kSrsLib: 'own',
      });
      expect(rows.containsKey(kShared), isFalse, reason: '对端的共享库指针不带进来');
    });

    test('对端默认组合的共享库挂在别的配置上：不拆独立库', () {
      final Map<SettingKey, String>? rows = mergeComboProfileRows(
        tree: tree,
        local: null,
        incoming: defaultRows(localDefaults, shared: 'uid-other'),
        incomingUid: 'uid-phone',
        localDefaultValues: localDefaults,
      );
      final DecodedComboRows d = decodeComboRows(tree, rows!);
      expect(d.role, ComboRole.named);
      expect(d.document.splits, isEmpty);
    });

    test('本机同名的是默认组合：原样保留（本机默认保持默认）', () {
      expect(
        mergeComboProfileRows(
          tree: tree,
          local: defaultRows(localDefaults, shared: 'uid-local'),
          incoming: defaultRows(<SettingKey, String>{
            ...localDefaults,
            kTheme: 'dark',
          }),
          incomingUid: 'x',
          localDefaultValues: localDefaults,
        ),
        isNull,
      );
    });

    test('两边同名组合：单独设置的叶子取并集；都拆了的叶子整组取本机（不逐键混拼）；复习库只看本机', () {
      final Map<SettingKey, String> local = encodeComboRows(
        tree,
        ComboDocument(<String, Map<SettingKey, String>>{
          'note_type': <SettingKey, String>{kNoteType: 'Local'},
        }),
        role: ComboRole.named,
      );
      final Map<SettingKey, String> incoming = encodeComboRows(
        tree,
        ComboDocument(<String, Map<SettingKey, String>>{
          'note_type': <SettingKey, String>{
            kNoteType: 'Remote',
            kFields: '{"b":2}',
          },
          'theme': <SettingKey, String>{kTheme: 'dark'},
          'srs.library': <SettingKey, String>{kSrsLib: 'own'},
        }),
        role: ComboRole.named,
      );
      final DecodedComboRows d = decodeComboRows(
        tree,
        mergeComboProfileRows(
          tree: tree,
          local: local,
          incoming: incoming,
          incomingUid: 'x',
          localDefaultValues: localDefaults,
        )!,
      );
      expect(d.role, ComboRole.named);
      expect(d.document.splitLeafIds, <String>{'note_type', 'theme'});
      expect(d.document.splits['note_type'], <SettingKey, String>{
        kNoteType: 'Local',
      }, reason: '字段映射不能从对端混进本机的笔记类型');
      expect(d.document.splits['theme'], <SettingKey, String>{kTheme: 'dark'});
    });

    test('对端没有本机缺的拆分：不用改', () {
      final Map<SettingKey, String> local = encodeComboRows(
        tree,
        ComboDocument(<String, Map<SettingKey, String>>{
          'theme': <SettingKey, String>{kTheme: 'dark'},
        }),
        role: ComboRole.named,
      );
      expect(
        mergeComboProfileRows(
          tree: tree,
          local: local,
          incoming: local,
          incomingUid: 'x',
          localDefaultValues: localDefaults,
        ),
        isNull,
      );
    });

    test('对端同名的是默认 / 整份快照、本机是组合：先 diff 再并', () {
      final Map<SettingKey, String> local = encodeComboRows(
        tree,
        ComboDocument.empty,
        role: ComboRole.named,
      );
      final DecodedComboRows d = decodeComboRows(
        tree,
        mergeComboProfileRows(
          tree: tree,
          local: local,
          incoming: <SettingKey, String>{...localDefaults, kOther: 'list'},
          incomingUid: 'x',
          localDefaultValues: localDefaults,
        )!,
      );
      expect(d.document.splitLeafIds, <String>{'other'});
    });

    test('本机迁移前：键级补缺，对端的默认身份与共享库指针不带进来', () {
      final Map<SettingKey, String>? rows = mergeComboProfileRows(
        tree: tree,
        local: null,
        incoming: defaultRows(localDefaults, shared: 'uid'),
        incomingUid: 'uid',
        localDefaultValues: null,
      );
      expect(rows!.containsKey(kRole), isFalse);
      expect(rows.containsKey(kShared), isFalse);
      expect(rows[kTheme], 'light');

      final Map<SettingKey, String>? merged = mergeComboProfileRows(
        tree: tree,
        local: <SettingKey, String>{kTheme: 'mine'},
        incoming: <SettingKey, String>{kTheme: 'theirs', kOther: 'list'},
        incomingUid: null,
        localDefaultValues: null,
      );
      expect(merged, <SettingKey, String>{kTheme: 'mine', kOther: 'list'});
    });

    test('不认识的角色（更新版本写的）：本机有就不碰，本机没有照原样落', () {
      final Map<SettingKey, String> foreign = <SettingKey, String>{
        kRole: 'future_role',
        kTheme: 'x',
      };
      expect(
        mergeComboProfileRows(
          tree: tree,
          local: null,
          incoming: foreign,
          incomingUid: null,
          localDefaultValues: localDefaults,
        ),
        foreign,
      );
      expect(
        mergeComboProfileRows(
          tree: tree,
          local: foreign,
          incoming: defaultRows(localDefaults),
          incomingUid: null,
          localDefaultValues: localDefaults,
        ),
        isNull,
      );
    });
  });
}
