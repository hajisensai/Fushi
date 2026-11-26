import 'package:fushi_engine/profile/combo/combo_resolver.dart';
import 'package:fushi_engine/profile/combo/settings_tree.dart';
import 'package:test/test.dart';

const SettingKey kDeck = SettingKey('anki', 'selectedDeckName');
const SettingKey kNoteType = SettingKey('anki', 'selectedNoteTypeName');
const SettingKey kFieldMap = SettingKey('anki', 'fieldMappings');
const SettingKey kTheme = SettingKey('pref', 'app_theme_key');
const SettingKey kFont = SettingKey('pref', 'src:reader_fushi:font_catalog');
const SettingKey kFontSize = SettingKey('pref', 'src:reader_fushi:font_size');
const SettingKey kHomeLayout = SettingKey('pref', 'home_layout');
const SettingKey kDevice = SettingKey('pref', 'app_ui_scale');
const SettingKey kSrsLib = SettingKey(kComboSyntheticCategory, 'srs_library');

SettingsTree buildTree() => SettingsTree(
  roots: const <SettingsNode>[
    SettingsNode.group(
      id: 'mining',
      children: <SettingsNode>[
        SettingsNode.leaf(
          id: 'mining.deck',
          matchers: <SettingKeyMatcher>[
            SettingKeyMatcher(
              category: 'anki',
              keys: <String>{'selectedDeckName'},
            ),
          ],
        ),
        SettingsNode.leaf(
          id: 'mining.note_type',
          matchers: <SettingKeyMatcher>[
            SettingKeyMatcher(
              category: 'anki',
              keys: <String>{'selectedNoteTypeName', 'fieldMappings'},
            ),
          ],
        ),
      ],
    ),
    SettingsNode.group(
      id: 'appearance',
      children: <SettingsNode>[
        SettingsNode.leaf(
          id: 'appearance.theme',
          matchers: <SettingKeyMatcher>[
            SettingKeyMatcher(
              category: 'pref',
              keys: <String>{'app_theme_key'},
            ),
          ],
        ),
        SettingsNode.leaf(
          id: 'appearance.fonts',
          matchers: <SettingKeyMatcher>[
            SettingKeyMatcher(
              category: 'pref',
              keys: <String>{'src:reader_fushi:font_catalog'},
            ),
          ],
        ),
        SettingsNode.leaf(
          id: 'appearance.reader_style',
          matchers: <SettingKeyMatcher>[
            SettingKeyMatcher(
              category: 'pref',
              prefixes: <String>['src:reader_fushi:'],
              except: <String>{'src:reader_fushi:font_catalog'},
            ),
          ],
        ),
      ],
    ),
    SettingsNode.group(
      id: 'srs',
      children: <SettingsNode>[
        SettingsNode.leaf(
          id: 'srs.library',
          splittableAt: <ComboScope>{ComboScope.mediaType, ComboScope.language},
          syntheticDefaults: <String, String>{'srs_library': 'shared'},
          diffable: false,
        ),
      ],
    ),
    SettingsNode.leaf(
      id: 'other',
      splittableAt: <ComboScope>{ComboScope.mediaType, ComboScope.language},
    ),
  ],
  fallbackLeafId: 'other',
  isExcluded: (SettingKey k) => k == kDevice,
);

void main() {
  final SettingsTree tree = buildTree();
  final Map<SettingKey, String> defaults = <SettingKey, String>{
    kDeck: 'Default',
    kNoteType: 'Lapis',
    kFieldMap: '{"Sentence":"{sentence}"}',
    kTheme: 'blue',
    kFont: '[a]',
    kFontSize: '20',
    kHomeLayout: 'grid',
    kDevice: '1.2',
  };

  group('SettingsTree', () {
    test('classifies keys into exactly one leaf, fallback and exclusion', () {
      expect(tree.leafOf(kDeck), 'mining.deck');
      expect(tree.leafOf(kFieldMap), 'mining.note_type');
      expect(tree.leafOf(kFont), 'appearance.fonts');
      expect(tree.leafOf(kFontSize), 'appearance.reader_style');
      expect(tree.leafOf(kHomeLayout), 'other');
      expect(tree.leafOf(kDevice), isNull);
      expect(tree.leafOf(kSrsLib), 'srs.library');
      expect(tree.claimingLeaves(kFont), <String>['appearance.fonts']);
    });

    test('leavesUnder expands groups in declaration order', () {
      expect(tree.leavesUnder('mining').map((SettingsNode n) => n.id), <String>[
        'mining.deck',
        'mining.note_type',
      ]);
      expect(tree.parentOf('mining.deck'), 'mining');
      expect(tree.parentOf('mining'), isNull);
    });

    test('rejects malformed trees', () {
      expect(
        () => SettingsTree(
          roots: const <SettingsNode>[
            SettingsNode.group(
              id: 'a',
              children: <SettingsNode>[
                SettingsNode.leaf(
                  id: 'b.x',
                  matchers: <SettingKeyMatcher>[
                    SettingKeyMatcher.category('c'),
                  ],
                ),
              ],
            ),
            SettingsNode.leaf(id: 'other'),
          ],
          fallbackLeafId: 'other',
        ),
        throwsArgumentError,
      );
      expect(
        () => SettingsTree(
          roots: const <SettingsNode>[SettingsNode.leaf(id: 'empty')],
          fallbackLeafId: 'other',
        ),
        throwsArgumentError,
      );
      expect(
        () => SettingsTree(
          roots: const <SettingsNode>[
            SettingsNode.leaf(id: 'other'),
            SettingsNode.leaf(id: 'other'),
          ],
          fallbackLeafId: 'other',
        ),
        throwsArgumentError,
      );
    });
  });

  group('resolveCombos', () {
    test('no layers: everything from defaults, synthetic filled, '
        'device-local dropped', () {
      final ResolvedSettings r = resolveCombos(tree: tree, defaults: defaults);
      expect(r.valueOf(kDeck), 'Default');
      expect(r.valueOf(kSrsLib), 'shared');
      expect(r.values.containsKey(kDevice), isFalse);
      for (final SettingsNode leaf in tree.leaves) {
        expect(r.sourceOf(leaf.id), const ComboSource.defaults());
      }
    });

    test('order is work > media type > language > default, per leaf', () {
      final ResolvedSettings r = resolveCombos(
        tree: tree,
        defaults: defaults,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.language,
            comboRef: 'lang-ja',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'mining.deck': <SettingKey, String>{kDeck: 'Japanese'},
              'appearance.theme': <SettingKey, String>{kTheme: 'red'},
              'appearance.fonts': <SettingKey, String>{kFont: '[ja]'},
            }),
          ),
          ComboLayer(
            scope: ComboScope.mediaType,
            comboRef: 'video',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'mining.deck': <SettingKey, String>{kDeck: 'Audio'},
              'appearance.theme': <SettingKey, String>{kTheme: 'dark'},
            }),
          ),
          ComboLayer(
            scope: ComboScope.work,
            comboRef: 'work-1',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'appearance.theme': <SettingKey, String>{kTheme: 'sepia'},
            }),
          ),
        ],
      );
      expect(r.valueOf(kTheme), 'sepia');
      expect(
        r.sourceOf('appearance.theme'),
        const ComboSource(ComboScope.work, 'work-1'),
      );
      // 媒体类型高于语言（与旧的 作品 → 语言 → 媒体类型 相反，拍板定的新顺序）。
      expect(r.valueOf(kDeck), 'Audio');
      expect(
        r.sourceOf('mining.deck'),
        const ComboSource(ComboScope.mediaType, 'video'),
      );
      expect(r.valueOf(kFont), '[ja]');
      expect(
        r.sourceOf('appearance.fonts'),
        const ComboSource(ComboScope.language, 'lang-ja'),
      );
      // 没人拆的叶子落回默认。
      expect(r.valueOf(kNoteType), 'Lapis');
      expect(r.sourceOf('mining.note_type'), const ComboSource.defaults());
    });

    test('leaf is atomic: keys missing in a split leaf are unset, '
        'never mixed with lower layers', () {
      final ResolvedSettings r = resolveCombos(
        tree: tree,
        defaults: defaults,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.mediaType,
            comboRef: 'manga',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'mining.note_type': <SettingKey, String>{kNoteType: 'Sentence'},
            }),
          ),
        ],
      );
      expect(r.valueOf(kNoteType), 'Sentence');
      // 字段映射不从默认组合「漏」过来：它属于同一个叶子，那一层没设 = 未设置。
      expect(r.valueOf(kFieldMap), isNull);
    });

    test('splits on layers that do not allow the leaf are ignored and '
        'reported', () {
      final ResolvedSettings r = resolveCombos(
        tree: tree,
        defaults: defaults,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.work,
            comboRef: 'w',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'other': <SettingKey, String>{kHomeLayout: 'list'},
              'srs.library': <SettingKey, String>{kSrsLib: 'own'},
            }),
          ),
          ComboLayer(
            scope: ComboScope.language,
            comboRef: 'l',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'other': <SettingKey, String>{kHomeLayout: 'shelf'},
            }),
          ),
        ],
      );
      expect(r.valueOf(kHomeLayout), 'shelf');
      expect(r.sourceOf('other'), const ComboSource(ComboScope.language, 'l'));
      expect(r.valueOf(kSrsLib), 'shared');
      expect(
        r.ignoredSplits,
        unorderedEquals(<IgnoredSplit>[
          const IgnoredSplit(
            leafId: 'other',
            scope: ComboScope.work,
            comboRef: 'w',
          ),
          const IgnoredSplit(
            leafId: 'srs.library',
            scope: ComboScope.work,
            comboRef: 'w',
          ),
        ]),
      );
    });

    test('foreign keys smuggled into a split leaf do not leak', () {
      final ResolvedSettings r = resolveCombos(
        tree: tree,
        defaults: defaults,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.work,
            comboRef: 'w',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'appearance.theme': <SettingKey, String>{
                kTheme: 'green',
                kDeck: 'Hijacked',
                kDevice: '9',
              },
            }),
          ),
        ],
      );
      expect(r.valueOf(kTheme), 'green');
      expect(r.valueOf(kDeck), 'Default');
      expect(r.values.containsKey(kDevice), isFalse);
    });

    test('rejects defaults layer, duplicate layers and unknown leaves', () {
      expect(
        () => resolveCombos(
          tree: tree,
          defaults: defaults,
          layers: <ComboLayer>[
            ComboLayer(
              scope: ComboScope.defaults,
              comboRef: 'd',
              document: ComboDocument.empty,
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => resolveCombos(
          tree: tree,
          defaults: defaults,
          layers: <ComboLayer>[
            ComboLayer(
              scope: ComboScope.work,
              comboRef: 'a',
              document: ComboDocument.empty,
            ),
            ComboLayer(
              scope: ComboScope.work,
              comboRef: 'b',
              document: ComboDocument.empty,
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => resolveCombos(
          tree: tree,
          defaults: defaults,
          layers: <ComboLayer>[
            ComboLayer(
              scope: ComboScope.work,
              comboRef: 'a',
              document: ComboDocument(<String, Map<SettingKey, String>>{
                'mining': <SettingKey, String>{},
              }),
            ),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('editing', () {
    final ResolvedSettings base = resolveCombos(tree: tree, defaults: defaults);

    test('writing an inherited value auto-splits its leaf with current '
        'values', () {
      final ComboDocument doc = writeSetting(
        tree: tree,
        document: ComboDocument.empty,
        scope: ComboScope.work,
        key: kNoteType,
        value: 'Audio card',
        effective: base,
      );
      expect(doc.splitLeafIds, <String>{'mining.note_type'});
      expect(doc.splits['mining.note_type'], <SettingKey, String>{
        kNoteType: 'Audio card',
        kFieldMap: '{"Sentence":"{sentence}"}',
      });
    });

    test('writing null unsets the key on that layer only', () {
      final ComboDocument doc = writeSetting(
        tree: tree,
        document: ComboDocument.empty,
        scope: ComboScope.mediaType,
        key: kFieldMap,
        value: null,
        effective: base,
      );
      final ResolvedSettings r = resolveCombos(
        tree: tree,
        defaults: defaults,
        layers: <ComboLayer>[
          ComboLayer(scope: ComboScope.mediaType, comboRef: 'm', document: doc),
        ],
      );
      expect(r.valueOf(kFieldMap), isNull);
      expect(r.valueOf(kNoteType), 'Lapis');
    });

    test('device-local keys cannot be written into a combo', () {
      expect(
        () => writeSetting(
          tree: tree,
          document: ComboDocument.empty,
          scope: ComboScope.work,
          key: kDevice,
          value: '2',
          effective: base,
        ),
        throwsArgumentError,
      );
    });

    test('splitting a group splits only leaves allowed at that layer and '
        'keeps existing splits', () {
      final ComboDocument pre = ComboDocument(<String, Map<SettingKey, String>>{
        'appearance.theme': <SettingKey, String>{kTheme: 'mine'},
      });
      final ComboDocument doc = splitNode(
        tree: tree,
        document: pre,
        nodeId: 'appearance',
        scope: ComboScope.work,
        effective: base,
      );
      expect(doc.splitLeafIds, <String>{
        'appearance.theme',
        'appearance.fonts',
        'appearance.reader_style',
      });
      expect(doc.splits['appearance.theme'], <SettingKey, String>{
        kTheme: 'mine',
      });
      expect(doc.splits['appearance.reader_style'], <SettingKey, String>{
        kFontSize: '20',
      });
      expect(
        () => splitNode(
          tree: tree,
          document: pre,
          nodeId: 'other',
          scope: ComboScope.work,
          effective: base,
        ),
        throwsArgumentError,
      );
    });

    test('restoreInheritance drops every leaf under the node', () {
      final ComboDocument doc = splitNode(
        tree: tree,
        document: ComboDocument.empty,
        nodeId: 'mining',
        scope: ComboScope.work,
        effective: base,
      );
      expect(
        restoreInheritance(
          tree: tree,
          document: doc,
          nodeId: 'mining.deck',
        ).splitLeafIds,
        <String>{'mining.note_type'},
      );
      expect(
        restoreInheritance(
          tree: tree,
          document: doc,
          nodeId: 'mining',
        ).splitLeafIds,
        isEmpty,
      );
    });
  });

  group('diffAgainstDefaults (migration)', () {
    test('only leaves that differ are split; missing keys count as unset; '
        'synthetic leaves skipped', () {
      final Map<SettingKey, String> snapshot = <SettingKey, String>{
        ...defaults,
        kDeck: 'Sentence deck',
        kDevice: 'whatever',
      }..remove(kFontSize);
      final ComboDocument doc = diffAgainstDefaults(
        tree: tree,
        defaults: defaults,
        snapshot: snapshot,
      );
      expect(doc.splitLeafIds, <String>{
        'mining.deck',
        'appearance.reader_style',
      });
      expect(doc.splits['appearance.reader_style'], isEmpty);
    });

    test('round-trip: resolving the diff over defaults reproduces the '
        'snapshot for leaves allowed at the layer', () {
      final Map<SettingKey, String> snapshot = <SettingKey, String>{
        kDeck: 'Other',
        kNoteType: 'Lapis',
        kTheme: 'blue',
        kFont: '[b]',
        kFontSize: '22',
        kHomeLayout: 'list',
      };
      final ComboDocument doc = diffAgainstDefaults(
        tree: tree,
        defaults: defaults,
        snapshot: snapshot,
      );
      final ResolvedSettings r = resolveCombos(
        tree: tree,
        defaults: defaults,
        layers: <ComboLayer>[
          ComboLayer(scope: ComboScope.mediaType, comboRef: 'p', document: doc),
        ],
      );
      final Map<SettingKey, String> expected = <SettingKey, String>{
        ...snapshot,
        kSrsLib: 'shared',
      };
      expect(r.values, expected);
    });
  });

  group('absentKeysInherit (one row per object, e.g. dictionaries)', () {
    const SettingKey dictA = SettingKey('dictionary_meta', 'A');
    const SettingKey dictB = SettingKey('dictionary_meta', 'B');
    const SettingKey dictC = SettingKey('dictionary_meta', 'C');
    final SettingsTree rowTree = SettingsTree(
      roots: const <SettingsNode>[
        SettingsNode.leaf(
          id: 'dictionary',
          absentKeysInherit: true,
          matchers: <SettingKeyMatcher>[
            SettingKeyMatcher.category('dictionary_meta'),
          ],
        ),
        SettingsNode.leaf(id: 'other'),
      ],
      fallbackLeafId: 'other',
    );
    final Map<SettingKey, String> rowDefaults = <SettingKey, String>{
      dictA: 'on:0',
      dictB: 'on:1',
      dictC: 'on:2',
    };

    test('rows missing from a split inherit per row from lower layers; '
        'source is the highest split layer', () {
      final ResolvedSettings r = resolveCombos(
        tree: rowTree,
        defaults: rowDefaults,
        layers: <ComboLayer>[
          ComboLayer(
            scope: ComboScope.language,
            comboRef: 'ja',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'dictionary': <SettingKey, String>{
                dictA: 'off:0',
                dictB: 'off:1',
              },
            }),
          ),
          ComboLayer(
            scope: ComboScope.mediaType,
            comboRef: 'video',
            document: ComboDocument(<String, Map<SettingKey, String>>{
              'dictionary': <SettingKey, String>{dictA: 'on:5'},
            }),
          ),
        ],
      );
      expect(r.values, <SettingKey, String>{
        dictA: 'on:5',
        dictB: 'off:1',
        dictC: 'on:2',
      });
      expect(
        r.sourceOf('dictionary'),
        const ComboSource(ComboScope.mediaType, 'video'),
      );
    });

    test(
      'diff ignores rows the snapshot lacks (installed later); a changed '
      'row or a row the defaults lack (object not here right now) splits',
      () {
        const SettingKey stale = SettingKey('dictionary_meta', 'Gone');
        final ComboDocument same = diffAgainstDefaults(
          tree: rowTree,
          defaults: rowDefaults,
          snapshot: <SettingKey, String>{dictA: 'on:0'},
        );
        expect(same.splitLeafIds, isEmpty);

        // 默认组合此刻没有这一行（服务器词典目录还没拉到 / 词典以后重装）：快照对它的选择
        // 要留下（BUG-4693），否则对象出现时就丢了这份配置的选择。
        final ComboDocument absent = diffAgainstDefaults(
          tree: rowTree,
          defaults: rowDefaults,
          snapshot: <SettingKey, String>{dictA: 'on:0', stale: 'on:9'},
        );
        expect(absent.splits['dictionary'], <SettingKey, String>{
          dictA: 'on:0',
          stale: 'on:9',
        });

        final Map<SettingKey, String> changedSnapshot = <SettingKey, String>{
          dictA: 'off:0',
          stale: 'on:9',
        };
        final ComboDocument changed = diffAgainstDefaults(
          tree: rowTree,
          defaults: rowDefaults,
          snapshot: changedSnapshot,
        );
        expect(changed.splits['dictionary'], changedSnapshot);
        final ResolvedSettings r = resolveCombos(
          tree: rowTree,
          defaults: rowDefaults,
          layers: <ComboLayer>[
            ComboLayer(
              scope: ComboScope.work,
              comboRef: 'w',
              document: changed,
            ),
          ],
        );
        expect(r.valueOf(dictA), 'off:0');
        expect(r.valueOf(dictB), 'on:1');
      },
    );
  });
}
