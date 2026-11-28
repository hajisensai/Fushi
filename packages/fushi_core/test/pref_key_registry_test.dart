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
        policy: PrefPolicy.profile,
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

    test('policyOf：命中的登记按更严合并，具体声明放不宽外层族', () {
      // audiobook_pos_at_ 声明成 profile，但它也在 audiobook_pos_（进度）里。
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

    test('派生名单按声明策略取固定键', () {
      expect(registry.keyNamesWhere((PrefPolicy p) => p.deviceLocal), <String>[
        'sync_device_id',
      ]);
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
          backup: PrefBackup.never,
          deviceLocal: true,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PrefPolicy(
          profileScoped: false,
          syncable: false,
          backup: PrefBackup.never,
          installScoped: true,
        ),
        throwsA(isA<AssertionError>()),
      );
      final PrefPolicy merged = PrefPolicy.profile.merge(PrefPolicy.local);
      expect(merged, PrefPolicy.local);
      expect(PrefPolicy.deviceVisible.redacted, isFalse);
      expect(PrefPolicy.deviceVisible.backupIncluded, isFalse);
    });
  });
}
