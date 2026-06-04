import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_progress_resolver.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

void main() {
  group('resolveProgressSync', () {
    test('both null -> synced', () {
      expect(resolveProgressSync(local: null, remote: null, base: null),
          ProgressResolution.synced());
    });
    test('only remote -> import (single side)', () {
      expect(resolveProgressSync(local: null, remote: 100, base: null).direction,
          SyncDirection.importFromTtu);
    });
    test('only local -> export (single side)', () {
      expect(resolveProgressSync(local: 100, remote: null, base: null).direction,
          SyncDirection.exportToTtu);
    });
    test('local==remote -> synced', () {
      final r = resolveProgressSync(local: 100, remote: 100, base: 50);
      expect(r.isConflict, isFalse);
      expect(r.direction, SyncDirection.synced);
    });
    test('local==base, remote moved -> import (remote single-side)', () {
      expect(
          resolveProgressSync(local: 50, remote: 100, base: 50).direction,
          SyncDirection.importFromTtu);
    });
    test('remote==base, local moved -> export (local single-side)', () {
      expect(
          resolveProgressSync(local: 100, remote: 50, base: 50).direction,
          SyncDirection.exportToTtu);
    });
    test('both moved off base, differ -> CONFLICT', () {
      final r = resolveProgressSync(local: 120, remote: 100, base: 50);
      expect(r.isConflict, isTrue);
    });
    test('no base, differ -> CONFLICT (legacy bootstrap)', () {
      final r = resolveProgressSync(local: 120, remote: 100, base: null);
      expect(r.isConflict, isTrue);
    });
    test('no base, equal -> synced', () {
      expect(resolveProgressSync(local: 100, remote: 100, base: null).direction,
          SyncDirection.synced);
    });
  });
}
