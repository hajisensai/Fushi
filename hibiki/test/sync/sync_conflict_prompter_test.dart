import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_conflict_prompter.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';

SyncConflict _c(String k, int l, int r) =>
    SyncConflict(assetKey: k, dimension: 'progress', title: k, localVersion: l, remoteVersion: r);

void main() {
  test('empty conflicts never prompt', () {
    final p = SyncConflictPrompter();
    expect(p.shouldPrompt(conflicts: const [], source: ConflictSource.manual, inBook: false), isFalse);
  });
  test('manual source always prompts (ignores in-book gate & snooze)', () {
    final p = SyncConflictPrompter();
    expect(p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.manual, inBook: true), isTrue);
  });
  test('auto source does not prompt while in book', () {
    final p = SyncConflictPrompter();
    expect(p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.auto, inBook: true), isFalse);
  });
  test('auto source does not prompt on background', () {
    final p = SyncConflictPrompter();
    expect(p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.background, inBook: false), isFalse);
  });
  test('auto prompts when out of book, then snoozes same fingerprint after dismiss', () {
    final p = SyncConflictPrompter();
    final cs = [_c('A', 1, 2)];
    expect(p.shouldPrompt(conflicts: cs, source: ConflictSource.auto, inBook: false), isTrue);
    p.markDismissed(cs);
    expect(p.shouldPrompt(conflicts: cs, source: ConflictSource.auto, inBook: false), isFalse);
    final cs2 = [_c('A', 1, 3)]; // 版本变化 -> 新指纹 -> 重新弹
    expect(p.shouldPrompt(conflicts: cs2, source: ConflictSource.auto, inBook: false), isTrue);
  });
  test('snoozed auto still prompts via manual', () {
    final p = SyncConflictPrompter();
    final cs = [_c('A', 1, 2)];
    p.markDismissed(cs);
    expect(p.shouldPrompt(conflicts: cs, source: ConflictSource.auto, inBook: false), isFalse);
    expect(p.shouldPrompt(conflicts: cs, source: ConflictSource.manual, inBook: false), isTrue);
  });
  test('single-flight: not while a dialog is open', () {
    final p = SyncConflictPrompter();
    p.dialogOpen = true;
    expect(p.shouldPrompt(conflicts: [_c('A', 1, 2)], source: ConflictSource.manual, inBook: false), isFalse);
  });
  test('partial snooze still prompts if any conflict is fresh', () {
    final p = SyncConflictPrompter();
    p.markDismissed([_c('A', 1, 2)]);
    // 组里有一个新指纹 B -> 整组仍应弹
    expect(p.shouldPrompt(conflicts: [_c('A', 1, 2), _c('B', 5, 6)], source: ConflictSource.auto, inBook: false), isTrue);
  });
}
