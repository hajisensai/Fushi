// G7-5 / G7-2b：迁移 `blocked` 结论按内核 `code` 分类（与 migrate.rs 核对）、状态带旧库 profile 列表、步骤与 Rust
// 一致；刷新键在本机状态行没落盘时稳定。纯 Dart，不加载原生库。
import 'dart:io';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

/// native/fushi_fsrs/src/store/gen4/migrate.rs（测试的工作目录是包目录）。
final File _migrateRs = File(
  '../../native/fushi_fsrs/src/store/gen4/migrate.rs',
);

SrsGen4MigrationOutcome _blocked(String? code, [String reason = '']) =>
    SrsGen4MigrationOutcome.fromJson(<String, Object?>{
      'verdict': 'blocked',
      'code': ?code,
      'reason': reason,
    });

void main() {
  group('blocked reason', () {
    test('the Dart list of codes is exactly migrate.rs BlockCode::wire', () {
      final String src = _migrateRs.readAsStringSync();
      final Set<String> rust = <String>{
        for (final RegExpMatch m in RegExp(
          r'BlockCode::\w+ => "(\w+)",',
        ).allMatches(src))
          m.group(1)!,
      };
      expect(rust, isNotEmpty);
      expect(rust, SrsGen4BlockedReason.kernelCodes.toSet());
    });

    test('the report file name is migrate.rs REPORT_FILE', () {
      final RegExpMatch? m = RegExp(
        r'pub const REPORT_FILE: &str = "([^"]+)";',
      ).firstMatch(_migrateRs.readAsStringSync());
      expect(m?.group(1), SrsGen4Migration.reportFileName);
    });

    test('codes map to kinds; the reason text is never parsed', () {
      final Map<String, SrsGen4BlockedReason> want =
          <String, SrsGen4BlockedReason>{
            'migrating': SrsGen4BlockedReason.migrating,
            'busy': SrsGen4BlockedReason.busy,
            'schemaNewer': SrsGen4BlockedReason.newerBuild,
            'corrupt': SrsGen4BlockedReason.damaged,
            'notProtocol3': SrsGen4BlockedReason.damaged,
            'missingCacheConfig': SrsGen4BlockedReason.precondition,
            'precondition': SrsGen4BlockedReason.precondition,
            'noLibrary': SrsGen4BlockedReason.precondition,
            'sealedWithoutNew': SrsGen4BlockedReason.precondition,
            'legacyBesideNew': SrsGen4BlockedReason.precondition,
          };
      expect(want.keys.toSet(), SrsGen4BlockedReason.kernelCodes.toSet());
      for (final MapEntry<String, SrsGen4BlockedReason> e in want.entries) {
        // 原因原文故意写成别的类的样子：分类只看 code。
        expect(
          _blocked(
            e.key,
            'busy: the protocol 3 library is being written',
          ).blockedReason,
          e.value,
          reason: e.key,
        );
      }
      // 没给 code / 不认识的 code（更新的内核）：按「其余」处理，原文照给。
      expect(_blocked(null).blockedReason, SrsGen4BlockedReason.precondition);
      expect(
        _blocked('somethingNew').blockedReason,
        SrsGen4BlockedReason.precondition,
      );
    });

    test('only kinds a retry can change are retryable', () {
      expect(
        <SrsGen4BlockedReason>[
          for (final SrsGen4BlockedReason r in SrsGen4BlockedReason.values)
            if (r.retryable) r,
        ],
        <SrsGen4BlockedReason>[
          SrsGen4BlockedReason.migrating,
          SrsGen4BlockedReason.busy,
          SrsGen4BlockedReason.precondition,
        ],
      );
    });

    test('other verdicts have no blocked reason', () {
      for (final String v in <String>[
        'committed',
        'aborted',
        'noSpace',
        'cancelled',
      ]) {
        expect(
          SrsGen4MigrationOutcome.fromJson(<String, Object?>{
            'verdict': v,
          }).blockedReason,
          isNull,
        );
      }
    });
  });

  group('status', () {
    test('status carries state and progress only', () {
      final SrsGen4MigrationStatus s = SrsGen4MigrationStatus.fromJson(
        <String, Object?>{
          'state': 'needsMigration',
          'running': <String, Object?>{
            'step': 'prepare',
            'done': 1,
            'total': 2,
          },
        },
      );
      expect(s.state, SrsGenState.needsMigration);
      expect(s.running?.step, SrsGen4MigrationStep.prepare);
      expect(SrsGen4MigrationStep.prepare.cancellable, isTrue);
      expect(
        SrsGen4MigrationStatus.fromJson(<String, Object?>{
          'state': 'ready',
        }).running,
        isNull,
      );
    });

    test('the profile list is its own kernel command, off the UI isolate', () {
      // 状态命令在 UI isolate 上同步轮询，不能读大表：列 profile 是另一条全局命令（kernel.rs `global`），
      // 内核也路由了它（lib.rs）。
      final String kernel = File(
        '${_migrateRs.parent.path}/kernel.rs',
      ).readAsStringSync();
      expect(kernel, contains('"gen4_migrate_profiles" =>'));
      final String lib = File(
        '${_migrateRs.parent.parent.parent.path}/lib.rs',
      ).readAsStringSync();
      expect(lib, contains('"gen4_migrate_profiles"'));
      final String dart = File(
        'lib/src/store/srs_gen4_migration.dart',
      ).readAsStringSync();
      final int at = dart.indexOf("'gen4_migrate_profiles'");
      expect(at, greaterThan(0));
      expect(dart.indexOf('Isolate.run', at), greaterThan(at));
    });

    test('the Dart steps are migrate.rs Step::wire in order', () {
      final String src = _migrateRs.readAsStringSync();
      final List<String> rust = <String>[
        for (final RegExpMatch m in RegExp(
          r'Step::\w+ => "(\w+)",',
        ).allMatches(src))
          m.group(1)!,
      ];
      expect(rust, <String>[
        for (final SrsGen4MigrationStep s in SrsGen4MigrationStep.values)
          s.wire,
      ]);
    });
  });

  group('refresh keys', () {
    // 内核 `refresh_keys` 的回包（gen4/refresh.rs）一次带齐五个键。
    test('the reply carries all five keys', () {
      expect(
        srsRefreshKeysOf(<String, Object?>{
          'content': 'o:1',
          'structure': 'o:1:2',
          'rwkv': 'o:0',
          'stats': 'o:3',
          'landed': 'o:4',
        }),
        (
          content: 'o:1',
          structure: 'o:1:2',
          rwkv: 'o:0',
          stats: 'o:3',
          landed: 'o:4',
        ),
      );
    });

    test('a missing key is a contract error, not a silent default', () {
      expect(
        () => srsRefreshKeysOf(<String, Object?>{
          'content': 'o:1',
          'structure': 'o:1:2',
          'stats': 'o:3',
          'landed': 'o:4',
        }),
        throwsStateError,
      );
    });
  });

  group('failure reason', () {
    test('the Dart reasons are exactly migrate.rs Failure::wire', () {
      final String src = _migrateRs.readAsStringSync();
      final Set<String> rust = <String>{
        for (final RegExpMatch m in RegExp(
          r'(?:AbortReason|Failure)::\w+ => "(\w+)",',
        ).allMatches(src))
          m.group(1)!,
      };
      expect(rust, <String>{'fail', 'incomplete', 'error', 'interrupted'});
      expect(rust, <String>{
        for (final SrsGen4MigrationFailureReason r
            in SrsGen4MigrationFailureReason.values)
          r.wire,
      });
    });

    test('status, open error and aborted outcome carry the same shape', () {
      const SrsGen4MigrationFailure want = SrsGen4MigrationFailure(
        reason: SrsGen4MigrationFailureReason.incomplete,
        reportPath: '/d/srs4-migration-report.json',
      );
      final Map<String, Object?> failure = <String, Object?>{
        'reason': 'incomplete',
        'reportPath': '/d/srs4-migration-report.json',
      };
      expect(
        SrsGen4MigrationStatus.fromJson(<String, Object?>{
          'state': 'migrationFailed',
          'failure': failure,
          'running': null,
        }).failure,
        want,
      );
      expect(
        SrsGen4MigrationOutcome.fromJson(<String, Object?>{
          'verdict': 'aborted',
          'reportPath': '/d/srs4-migration-report.json',
          'failure': failure,
        }).failure,
        want,
      );
      // store/ffi.rs open_error：说明文字 + `GenState::json`（键按字母序，failure 在 state 前）。
      final SrsCoreException e = SrsCoreException.of(
        SrsStoreNotMigrated.statusCode,
        'gen4 store: not migrated yet '
        '{"failure":{"reason":"incomplete","reportPath":"/d/srs4-migration-report.json"},'
        '"state":"migrationFailed"}',
      );
      expect(e, isA<SrsStoreNotMigrated>());
      final SrsStoreNotMigrated n = e as SrsStoreNotMigrated;
      expect(n.state, SrsGenState.migrationFailed);
      expect(n.failure, want);
    });

    test('interrupted has no report; other states have no failure', () {
      expect(
        SrsGen4MigrationFailure.tryParse(<String, Object?>{
          'reason': 'interrupted',
        }),
        const SrsGen4MigrationFailure(
          reason: SrsGen4MigrationFailureReason.interrupted,
        ),
      );
      expect(SrsGen4MigrationFailure.tryParse(null), isNull);
      expect(
        SrsGen4MigrationFailure.tryParse(<String, Object?>{'reason': 'x'}),
        isNull,
      );
      expect(
        SrsGen4MigrationStatus.fromJson(<String, Object?>{
          'state': 'needsMigration',
          'failure': null,
        }).failure,
        isNull,
      );
    });
  });
}
