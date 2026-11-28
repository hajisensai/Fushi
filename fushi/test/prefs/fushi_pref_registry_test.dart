import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/prefs/fushi_pref_registry.dart';
import 'package:fushi/src/prefs/non_portable_setting_shape.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/settings_sync.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 偏好键登记表（架构重构 F1）在 app 侧的接线：各通道的逐键判定与派生名单 / SQL 必须出自
/// 同一份生效策略，固定键与键族一视同仁。
void main() {
  /// 真实登记表上的一批样本键：全部固定键、只登记了名字的存量键、每个键族各造一个键
  /// （含带凭据形状与不可移植形状的运行时段）、未登记的键。
  List<String> sampleKeys() => <String>[
    ...kFushiPrefRegistry.keys.map((PrefKey<Object?> k) => k.name),
    ...kKnownPreferenceKeys,
    for (final PrefKeyFamily<Object?> f in kFushiPrefRegistry.families) ...[
      '${f.prefix}x${f.marker}y${f.suffix}',
      '${f.prefix}my_token${f.marker}window_rect${f.suffix}',
    ],
    'nobody_registered_me',
    'some_future_api_key',
    'some_window_size',
  ];

  group('真实登记表', () {
    test('每条性质：select 的枚举形态 ⇔ has 的逐键判定', () {
      final List<String> keys = sampleKeys();
      expect(keys.length, greaterThan(800));
      for (final PrefTrait trait in PrefTrait.values) {
        final PrefKeySelection selection = kFushiPrefRegistry.select(trait);
        for (final String key in keys) {
          final bool enumerated =
              selection.keys.contains(key) ||
              selection.families.any(
                (PrefKeyFamily<Object?> f) => f.matches(key),
              ) ||
              selection.shapes.any((PrefShapeRule r) => r.matches(key)) ||
              (selection.coversUnregistered &&
                  kFushiPrefRegistry.lookup(key) == null);
          expect(
            kFushiPrefRegistry.has(key, trait),
            enumerated,
            reason: '${trait.name} / $key',
          );
        }
      }
    });

    test('各通道入口都只是登记表生效策略的一个字段', () {
      for (final String key in sampleKeys()) {
        final PrefPolicy policy = kFushiPrefRegistry.policyOf(key);
        expect(ProfileKeys.isExcludedPref(key), !policy.profileScoped);
        expect(
          PrefRedactionPolicy.isDeviceLocalOrCredential(key),
          policy.redacted,
        );
        expect(PortableSettingsPolicy.isPortable(key), policy.syncable);
        expect(
          SyncRepository.deviceLocalPrefKeys.contains(key),
          policy.deviceLocal,
        );
        expect(
          SyncRepository.installScopedPrefKeys.contains(key),
          policy.installScoped,
        );
      }
    });

    test('形状兜底只有两条：凭据、不可移植设置（后者只收紧同步）', () {
      expect(kFushiPrefRegistry.shapeRules, <PrefShapeRule>[
        PrefKeyRegistry.credentialShapeRule,
        kNonPortableSettingShapeRule,
      ]);
      final PrefPolicy p = kFushiPrefRegistry.policyOf('some_window_size');
      expect(p.syncable, isFalse);
      expect(p.profileScoped, isTrue);
      expect(p.backedUp, isTrue);
      expect(p.backup, PrefBackup.settings);
      expect(p.redacted, isFalse);
    });

    test('备份 SQL 条件由登记表拼出，文本与迁移前逐字一致（持久化行为不变）', () {
      expect(
        settingsPrefPredicate,
        "key NOT LIKE 'audiobook_pos_%' AND key NOT IN ("
        "'favorite_sentences', 'local_audio_dbs', 'audio_source_configs', "
        "'src:reader_fushi:font_catalog', 'src:reader_fushi:custom_fonts', "
        "'src:reader_fushi:app_ui_fonts', 'src:reader_fushi:dict_fonts', "
        "'src:reader_fushi:video_sub_fonts', "
        "'src:reader_fushi:game_lookup_fonts', "
        "'src:reader_fushi:floating_lyric_fonts', "
        "'src:reader_fushi:srs_card_fonts') "
        "AND instr(key, 'override_title://') = 0",
      );
      expect(progressPrefPredicate, "key LIKE 'audiobook_pos_%'");
    });
  });

  group('prefSelectionSql（合成登记表）', () {
    PrefKeyRegistry build(List<PrefKeyDef> defs) => PrefKeyRegistry(defs);

    test('进度类固定键：排除出设置类别，并归进度类处理', () {
      final PrefKeyRegistry r = build(<PrefKeyDef>[
        PrefKey.untyped(
          'reading_streak_position',
          policy: PrefPolicy.progress,
          kind: PrefKind.state,
        ),
        PrefKey.untyped(
          'favorite_things',
          policy: PrefPolicy.profileContent,
          kind: PrefKind.setting,
        ),
        PrefKeyFamily.untyped(
          prefix: 'pos_',
          policy: PrefPolicy.progress,
          kind: PrefKind.state,
        ),
      ]);
      expect(
        prefSelectionSql(
          r.select(PrefTrait.outsideSettingsBackup),
          matching: false,
        ),
        "key NOT LIKE 'pos_%' AND key NOT IN "
        "('reading_streak_position', 'favorite_things')",
      );
      expect(
        prefSelectionSql(r.select(PrefTrait.progressBackup), matching: true),
        "key LIKE 'pos_%' OR key IN ('reading_streak_position')",
      );
      expect(
        r.has('reading_streak_position', PrefTrait.outsideSettingsBackup),
        isTrue,
      );
    });

    test('被入选键族包住的键族不重复出子句；子串族出 instr', () {
      final PrefKeyRegistry r = build(<PrefKeyDef>[
        PrefKeyFamily.untyped(
          prefix: 'pos_',
          policy: PrefPolicy.progress,
          kind: PrefKind.state,
        ),
        PrefKeyFamily.untyped(
          prefix: 'pos_at_',
          policy: PrefPolicy.progress,
          kind: PrefKind.state,
        ),
        PrefKeyFamily.untyped(
          marker: 'title://',
          policy: PrefPolicy.content,
          kind: PrefKind.state,
        ),
      ]);
      expect(
        prefSelectionSql(
          r.select(PrefTrait.outsideSettingsBackup),
          matching: false,
        ),
        "key NOT LIKE 'pos_%' AND instr(key, 'title://') = 0",
      );
      expect(
        prefSelectionSql(
          r.select(PrefTrait.outsideSettingsBackup),
          matching: true,
        ),
        "key LIKE 'pos_%' OR instr(key, 'title://') > 0",
      );
    });

    test('空选择：matching 恒假 / 取反恒真', () {
      final PrefKeySelection none = build(
        <PrefKeyDef>[],
      ).select(PrefTrait.progressBackup);
      expect(prefSelectionSql(none, matching: true), '0');
      expect(prefSelectionSql(none, matching: false), '1');
    });

    test('SQL 表达不了的选择直接抛错，不静默漏键', () {
      // 带后缀的族。
      expect(
        () => prefSelectionSql(
          build(<PrefKeyDef>[
            PrefKeyFamily.untyped(
              prefix: 'a_',
              suffix: '_pos',
              policy: PrefPolicy.progress,
              kind: PrefKind.state,
            ),
          ]).select(PrefTrait.progressBackup),
          matching: true,
        ),
        throwsStateError,
      );
      // 带形状兜底的性质（凭据）枚举不完。
      expect(
        () => prefSelectionSql(
          build(<PrefKeyDef>[]).select(PrefTrait.redacted),
          matching: true,
        ),
        throwsStateError,
      );
    });

    test('安装级键族与固定键一视同仁（导入时清掉靠 contains，不靠固定键名单）', () {
      final PrefKeyRegistry r = build(<PrefKeyDef>[
        PrefKey.untyped(
          'first_run_verdict',
          policy: PrefPolicy.installScopedLocal,
          kind: PrefKind.state,
        ),
        PrefKeyFamily.untyped(
          prefix: 'install_verdict::',
          policy: PrefPolicy.installScopedLocal,
          kind: PrefKind.state,
        ),
      ]);
      final PrefKeySelection installScoped = r.select(PrefTrait.installScoped);
      expect(installScoped.contains('first_run_verdict'), isTrue);
      expect(installScoped.contains('install_verdict::srs'), isTrue);
      expect(installScoped.contains('reader_font'), isFalse);
      // 设备本地名单同样带上它们。
      expect(
        r.select(PrefTrait.deviceLocal).contains('install_verdict::srs'),
        isTrue,
      );
    });
  });
}
