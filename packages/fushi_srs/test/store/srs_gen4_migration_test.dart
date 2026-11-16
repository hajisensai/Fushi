// G7-5 复核修复：迁移 `blocked` 结论按原因分类、刷新键在本机状态行没落盘时稳定。纯 Dart，不加载原生库。
import 'dart:io';

import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

/// native/fushi_fsrs/src/store/gen4/migrate.rs（测试的工作目录是包目录）。
final File _migrateRs = File(
  '../../native/fushi_fsrs/src/store/gen4/migrate.rs',
);

SrsGen4MigrationOutcome _blocked(String reason) =>
    SrsGen4MigrationOutcome.fromJson(<String, Object?>{
      'verdict': 'blocked',
      'reason': reason,
    });

void main() {
  group('blocked reason', () {
    test('the two retryable reasons match the Rust constants verbatim', () {
      final String src = _migrateRs.readAsStringSync();
      expect(
        src,
        contains(
          'pub const BLOCKED_MIGRATING: &str = '
          '"${SrsGen4BlockedReason.migratingWire}";',
        ),
      );
      expect(
        src,
        contains(
          'pub const BLOCKED_BUSY: &str = '
          '"${SrsGen4BlockedReason.busyWire}";',
        ),
      );
    });

    test('lock held elsewhere / legacy being written are retryable kinds', () {
      expect(
        _blocked(SrsGen4BlockedReason.migratingWire).blockedReason,
        SrsGen4BlockedReason.migrating,
      );
      expect(
        _blocked(SrsGen4BlockedReason.busyWire).blockedReason,
        SrsGen4BlockedReason.busy,
      );
    });

    test('unfinished protocol 3 work is a precondition, not "busy"', () {
      // migrate.rs `with_snapshot`：各 profile 的前提原因用 "; " 连起来。
      for (final String reason in <String>[
        'p1: legacy rows are not migrated into the op log yet',
        'p1: legacy rows are not migrated into the op log yet; '
            'p2: no cache configuration was given for this profile',
        'the protocol 3 library is at schema 40001; open it with this '
            "build's protocol 3 kernel first (schema 40019)",
        'srs.db is not a protocol 3 library',
        '',
      ]) {
        expect(
          _blocked(reason).blockedReason,
          SrsGen4BlockedReason.precondition,
          reason: reason,
        );
      }
      expect(
        SrsGen4MigrationOutcome.fromJson(<String, Object?>{
          'verdict': 'blocked',
        }).blockedReason,
        SrsGen4BlockedReason.precondition,
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

  group('refresh key', () {
    test('a stored epoch keys as epoch:revision', () {
      expect(
        srsRefreshKeyOf(<String, Object?>{
          'epoch': 'abcd',
          'epochStored': true,
          'revision': 7,
        }),
        'abcd:7',
      );
    });

    test('an unstored epoch (fresh every read) gives a stable key', () {
      // local_state.rs `view`：没有行时每读一次给一个新纪元。键不能跟着变。
      final String a = srsRefreshKeyOf(<String, Object?>{
        'epoch': 'e1',
        'epochStored': false,
        'exists': false,
        'revision': 0,
      });
      final String b = srsRefreshKeyOf(<String, Object?>{
        'epoch': 'e2',
        'epochStored': false,
        'exists': false,
        'revision': 0,
      });
      expect(a, b);
      // 与任何落了盘的键都不相等（落盘后整份重读一次）。
      expect(a, isNot(contains('e1')));
      expect(
        srsRefreshKeyOf(<String, Object?>{
          'epoch': 'x',
          'epochStored': false,
          'revision': 3,
        }),
        isNot(a),
        reason: '修订号仍然区分',
      );
    });
  });
}
