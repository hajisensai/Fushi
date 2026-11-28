import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

void main() {
  group('PrefKeyRegistry', () {
    final PrefKeyRegistry registry = PrefKeyRegistry(<PrefKeyDef>[
      const PrefKey<bool>(
        'reader_follow_layout',
        defaultValue: true,
        policy: PrefPolicy.profile,
        kind: PrefKind.setting,
      ),
      PrefKey.raw(
        'sync_device_id',
        policy: PrefPolicy.local,
        kind: PrefKind.state,
      ),
      const PrefKeyFamily<int>(
        prefix: 'audiobook_pos_',
        defaultValue: 0,
        policy: PrefPolicy.progress,
        kind: PrefKind.state,
      ),
      PrefKeyFamily.untyped(
        prefix: 'audiobook_pos_at_',
        policy: PrefPolicy.progress,
        kind: PrefKind.state,
      ),
      PrefKeyFamily.untyped(
        prefix: 'src:',
        policy: PrefPolicy.profile,
        kind: PrefKind.setting,
      ),
      PrefKeyFamily.untyped(
        marker: 'override_title://',
        policy: PrefPolicy.content,
        kind: PrefKind.state,
      ),
      PrefKeyFamily.untyped(
        prefix: 'media_tracking_',
        suffix: '_declined_v1',
        policy: PrefPolicy.local,
        kind: PrefKind.state,
      ),
    ]);

    test('lookup：固定键优先，键族取最具体的一条，未登记 null', () {
      expect(registry.lookup('reader_follow_layout'), isA<PrefKey<bool>>());
      expect(
        (registry.lookup('audiobook_pos_at_x') as PrefKeyFamily<Object?>)
            .prefix,
        'audiobook_pos_at_',
      );
      expect(
        (registry.lookup('src:7:override_title://a') as PrefKeyFamily<Object?>)
            .marker,
        'override_title://',
      );
      expect(registry.lookup('media_tracking_bgm_declined_v1'), isNotNull);
      expect(registry.lookup('media_tracking_bgm'), isNull);
      expect(registry.lookup('nobody_registered_me'), isNull);
    });

    test('policyOf：命中的登记按更严合并', () {
      final PrefPolicy p = registry.policyOf('audiobook_pos_at_book');
      expect(p.profileScoped, isFalse);
      expect(p.backup, PrefBackup.progress);
      // src: 默认随 Profile，书名改名 marker 收紧成内容。
      final PrefPolicy title = registry.policyOf('src:1:override_title://x');
      expect(title.profileScoped, isFalse);
      expect(title.backup, PrefBackup.content);
      expect(registry.policyOf('src:1:font'), PrefPolicy.profile);
      expect(registry.policyOf('unknown_key'), PrefPolicy.profile);
    });

    test('形状兜底：未登记或运行时段带凭据形状的键照样按凭据拦', () {
      expect(registry.policyOf('some_new_api_key').redacted, isTrue);
      expect(registry.policyOf('src:my_token_source:x').redacted, isTrue);
      expect(registry.policyOf('Some_PASSWORD').credential, isTrue);
      expect(registry.policyOf('reader_follow_layout').redacted, isFalse);
    });

    test('select 与 has 同源：枚举形态（固定键 + 键族 + 形状兜底）等于逐键判定', () {
      final PrefKeySelection local = registry.select(PrefTrait.deviceLocal);
      expect(local.keys, <String>['sync_device_id']);
      expect(
        local.families.map((PrefKeyFamily<Object?> f) => f.pattern),
        <String>['media_tracking_*_declined_v1'],
      );
      expect(local.shapes, isEmpty);
      expect(local.isEnumerable, isTrue);
      // 凭据这条性质带着形状兜底，枚举不完。
      expect(registry.select(PrefTrait.redacted).isEnumerable, isFalse);

      const List<String> samples = <String>[
        'reader_follow_layout',
        'sync_device_id',
        'audiobook_pos_book',
        'audiobook_pos_at_book',
        'audiobook_pos_src:1:override_title://x',
        'src:1:override_title://x',
        'src:1:font',
        'src:my_token_source:x',
        'media_tracking_bgm_declined_v1',
        'media_tracking_bgm',
        'some_new_api_key',
        'nobody_registered_me',
      ];
      for (final PrefTrait trait in PrefTrait.values) {
        final PrefKeySelection selection = registry.select(trait);
        for (final String key in samples) {
          final bool enumerated =
              selection.keys.contains(key) ||
              selection.families.any(
                (PrefKeyFamily<Object?> f) => f.matches(key),
              ) ||
              selection.shapes.any((PrefShapeRule r) => r.matches(key)) ||
              (selection.coversUnregistered && registry.lookup(key) == null);
          expect(
            selection.contains(key),
            enumerated,
            reason: '${trait.name} / $key',
          );
          expect(selection.contains(key), registry.has(key, trait));
        }
      }
    });

    test('PrefTrait 对 merge 单调：合并后成立 ⇔ 至少一侧成立（全部合法策略两两穷举）', () {
      const List<bool> bools = <bool>[false, true];
      final List<PrefPolicy> all = <PrefPolicy>[
        for (final bool profileScoped in bools)
          for (final bool syncable in bools)
            for (final bool backedUp in bools)
              for (final PrefBackup backup in PrefBackup.values)
                for (final bool deviceLocal in bools)
                  for (final bool credential in bools)
                    for (final bool installScoped in bools)
                      if ((!(deviceLocal || credential) ||
                              (!profileScoped && !syncable && !backedUp)) &&
                          (!installScoped || deviceLocal))
                        PrefPolicy(
                          profileScoped: profileScoped,
                          syncable: syncable,
                          backedUp: backedUp,
                          backup: backup,
                          deviceLocal: deviceLocal,
                          credential: credential,
                          installScoped: installScoped,
                        ),
      ];
      expect(all.length, greaterThan(30));
      for (final PrefPolicy a in all) {
        for (final PrefPolicy b in all) {
          final PrefPolicy merged = a.merge(b);
          expect(merged, b.merge(a), reason: 'merge 可交换');
          for (final PrefTrait trait in PrefTrait.values) {
            expect(
              trait.of(merged),
              trait.of(a) || trait.of(b),
              reason: '${trait.name}: $a + $b',
            );
          }
        }
      }
    });

    test('备份类别的严格顺序：进度 > 内容 > 设置（同时落在进度族和内容族里仍算进度）', () {
      expect(PrefBackup.values, <PrefBackup>[
        PrefBackup.settings,
        PrefBackup.content,
        PrefBackup.progress,
      ]);
      const String key = 'audiobook_pos_src:1:override_title://x';
      expect(registry.policyOf(key).backup, PrefBackup.progress);
      expect(registry.has(key, PrefTrait.progressBackup), isTrue);
      expect(registry.has(key, PrefTrait.outsideSettingsBackup), isTrue);
    });

    test('lookup 同具体度的键族按模式字典序取，不依赖登记顺序', () {
      final PrefKeyFamily<Object?> byPrefix = PrefKeyFamily.untyped(
        prefix: 'ab_',
        policy: PrefPolicy.profile,
        kind: PrefKind.state,
      );
      final PrefKeyFamily<Object?> bySuffix = PrefKeyFamily.untyped(
        suffix: '_zz',
        policy: PrefPolicy.profile,
        kind: PrefKind.state,
      );
      expect(byPrefix.specificity, bySuffix.specificity);
      String pick(List<PrefKeyDef> defs) =>
          (PrefKeyRegistry(defs).lookup('ab__zz')! as PrefKeyFamily<Object?>)
              .pattern;
      expect(
        pick(<PrefKeyDef>[byPrefix, bySuffix]),
        pick(<PrefKeyDef>[bySuffix, byPrefix]),
      );
    });

    test('编解码：标签 / 裸字符串 / 未声明类型', () {
      final PrefKey<bool> flag =
          registry.keyNamed('reader_follow_layout')! as PrefKey<bool>;
      expect(flag.decode(null), isTrue);
      expect(flag.decode('b:false'), isFalse);
      expect(flag.encode(false), 'b:false');
      final PrefKey<String?> raw =
          registry.keyNamed('sync_device_id')! as PrefKey<String?>;
      expect(raw.decode('abc'), 'abc');
      expect(raw.decode(null), isNull);
      expect(raw.isUntyped, isFalse);
      // 写 null = 删行（缺行读回 null），不是写一行空串；空串是另一个值。
      expect(raw.encode(null), isNull);
      expect(raw.decode(raw.encode(null)), isNull);
      expect(raw.encode(''), '');
      expect(raw.decode(raw.encode('')), '');
      final PrefKey<Object?> untyped = PrefKey.untyped(
        'x',
        policy: PrefPolicy.profile,
        kind: PrefKind.setting,
      );
      expect(untyped.isUntyped, isTrue);
      expect(untyped.decode('i:3'), 3);
      expect(
        const PrefKeyFamily<int>(
          prefix: 'a_',
          defaultValue: 0,
          policy: PrefPolicy.profile,
          kind: PrefKind.state,
        ).keyFor('b'),
        'a_b',
      );
    });

    test('构造期校验：声明不得比生效策略宽（固定键落在更严的键族里、内层族比外层族宽）', () {
      // 固定键声明成普通设置，却落在设备本地族里：各通道会把它当设备本地，声明在说谎。
      expect(
        () => PrefKeyRegistry(<PrefKeyDef>[
          PrefKeyFamily.untyped(
            prefix: 'dev_',
            policy: PrefPolicy.local,
            kind: PrefKind.state,
          ),
          PrefKey.untyped(
            'dev_scale',
            policy: PrefPolicy.unscoped,
            kind: PrefKind.setting,
          ),
        ]),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(contains('dev_scale'), contains('family "dev_*"')),
          ),
        ),
      );
      // 声明得和族一样严（或更严）才过；派生名单随之带上它。
      final PrefKeyRegistry ok = PrefKeyRegistry(<PrefKeyDef>[
        PrefKeyFamily.untyped(
          prefix: 'dev_',
          policy: PrefPolicy.local,
          kind: PrefKind.state,
        ),
        PrefKey.untyped(
          'dev_install',
          policy: PrefPolicy.installScopedLocal,
          kind: PrefKind.state,
        ),
      ]);
      expect(ok.select(PrefTrait.installScoped).keys, <String>['dev_install']);
      expect(ok.select(PrefTrait.deviceLocal).contains('dev_anything'), isTrue);
      // 内层族比包住它的外层族宽。
      expect(
        () => PrefKeyRegistry(<PrefKeyDef>[
          PrefKeyFamily.untyped(
            prefix: 'pos_',
            policy: PrefPolicy.progress,
            kind: PrefKind.state,
          ),
          PrefKeyFamily.untyped(
            prefix: 'pos_at_',
            policy: PrefPolicy.profile,
            kind: PrefKind.state,
          ),
        ]),
        throwsStateError,
      );
      // 备份类别冲突同理：内容类固定键落在进度族里，生效是进度，声明不符。
      expect(
        () => PrefKeyRegistry(<PrefKeyDef>[
          PrefKeyFamily.untyped(
            prefix: 'pos_',
            policy: PrefPolicy.progress,
            kind: PrefKind.state,
          ),
          PrefKey.untyped(
            'pos_title',
            policy: PrefPolicy.content,
            kind: PrefKind.state,
          ),
        ]),
        throwsStateError,
      );
    });

    test('形状兜底可扩展：只收紧同步的规则不动其它通道，声明成可同步的固定键被拦', () {
      const PrefShapeRule windowShape = PrefSubstringShapeRule(
        name: 'non-portable',
        policy: PrefPolicy.unsyncableOnly,
        substrings: <String>['window'],
      );
      final PrefKeyRegistry r = PrefKeyRegistry(
        const <PrefKeyDef>[
          PrefKey<bool>(
            'reader_follow_layout',
            defaultValue: true,
            policy: PrefPolicy.profile,
            kind: PrefKind.setting,
          ),
        ],
        shapeRules: const <PrefShapeRule>[
          PrefKeyRegistry.credentialShapeRule,
          windowShape,
        ],
      );
      final PrefPolicy p = r.policyOf('some_window_size');
      expect(p.syncable, isFalse);
      expect(p.profileScoped, isTrue);
      expect(p.backedUp, isTrue);
      expect(p.redacted, isFalse);
      expect(r.policyOf('reader_follow_layout').syncable, isTrue);
      expect(r.select(PrefTrait.unsyncable).shapes, <PrefShapeRule>[
        PrefKeyRegistry.credentialShapeRule,
        windowShape,
      ]);
      expect(
        () => PrefKeyRegistry(
          const <PrefKeyDef>[
            PrefKey<bool>(
              'main_window_pinned',
              defaultValue: true,
              policy: PrefPolicy.profile,
              kind: PrefKind.setting,
            ),
          ],
          shapeRules: const <PrefShapeRule>[windowShape],
        ),
        throwsStateError,
      );
    });

    test('构造期校验：重复键、重复键族、像凭据却没声明凭据', () {
      const PrefKey<bool> a = PrefKey<bool>(
        'dup',
        defaultValue: false,
        policy: PrefPolicy.profile,
        kind: PrefKind.setting,
      );
      expect(() => PrefKeyRegistry(<PrefKeyDef>[a, a]), throwsStateError);
      expect(
        () => PrefKeyRegistry(<PrefKeyDef>[
          PrefKeyFamily.untyped(
            prefix: 'p_',
            policy: PrefPolicy.profile,
            kind: PrefKind.state,
          ),
          PrefKeyFamily.untyped(
            prefix: 'p_',
            policy: PrefPolicy.local,
            kind: PrefKind.state,
          ),
        ]),
        throwsStateError,
      );
      expect(
        () => PrefKeyRegistry(<PrefKeyDef>[
          PrefKey.untyped(
            'webdav_password',
            policy: PrefPolicy.local,
            kind: PrefKind.setting,
          ),
        ]),
        throwsStateError,
      );
    });

    test('策略不变式：设备本地 / 凭据不出境，安装级蕴含设备本地', () {
      expect(
        () => PrefPolicy(
          profileScoped: true,
          syncable: false,
          backedUp: false,
          deviceLocal: true,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PrefPolicy(
          profileScoped: false,
          syncable: false,
          backedUp: false,
          installScoped: true,
        ),
        throwsA(isA<AssertionError>()),
      );
      final PrefPolicy merged = PrefPolicy.profile.merge(PrefPolicy.local);
      expect(merged, PrefPolicy.local);
      expect(PrefPolicy.deviceVisible.redacted, isFalse);
      expect(PrefPolicy.deviceVisible.backedUp, isFalse);
    });
  });
}
