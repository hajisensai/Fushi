// SRS 重活账本（BUG-4075 取证）：内存采样每 30 s 取走一个窗口的汇总。
import 'dart:async';

import 'package:fushi_engine/srs/srs_op_ledger.dart';
import 'package:test/test.dart';

void main() {
  setUp(SrsOpLedger.reset);
  tearDown(SrsOpLedger.reset);

  test('空窗口没有汇总', () {
    expect(SrsOpLedger.takeSummary(), isNull);
  });

  test('按操作名归并次数 / 字节 / 行数，取走后清零', () async {
    await SrsOpLedger.track(
      'core:stats_bundle',
      () async => 1,
      measure: (int _) => (3 << 20, 1000),
    );
    await SrsOpLedger.track(
      'core:stats_bundle',
      () async => 2,
      measure: (int _) => (1 << 20, 500),
    );
    final int t = SrsOpLedger.begin('sql:SELECT srs_field_edits');
    SrsOpLedger.end(t, bytes: 2048, rows: 3);
    SrsOpLedger.mark('rev');
    SrsOpLedger.mark('rev');
    SrsOpLedger.mark('home_stats');

    final String summary = SrsOpLedger.takeSummary()!;
    expect(summary, contains('core:stats_bundle 2x'));
    expect(summary, contains('4.0MB rows=1500'));
    expect(summary, contains('sql:SELECT srs_field_edits 1x'));
    expect(summary, contains('2KB rows=3'));
    expect(summary, contains('marks=['));
    expect(summary, contains('rev+2'));
    expect(summary, contains('home_stats+1'));
    expect(SrsOpLedger.takeSummary(), isNull);
  });

  test('cancel 的操作不记账', () {
    final int t = SrsOpLedger.begin('sql:SELECT x');
    SrsOpLedger.cancel(t);
    SrsOpLedger.end(t, bytes: 10);
    expect(SrsOpLedger.takeSummary(), isNull);
  });

  test('抛异常的操作照样记一笔，异常照常抛出', () async {
    await expectLater(
      SrsOpLedger.track<int>('core:sync2', () async => throw StateError('x')),
      throwsStateError,
    );
    expect(SrsOpLedger.takeSummary(), contains('core:sync2 1x'));
  });

  test('正在跑超过阈值的操作列进 busy，跨窗口保留直到结束', () async {
    final int t = SrsOpLedger.begin('core:rwkv_replay');
    await Future<void>.delayed(
      kSrsOpBusyAfter + const Duration(milliseconds: 50),
    );
    expect(SrsOpLedger.takeSummary(), contains('busy=[core:rwkv_replay '));
    expect(SrsOpLedger.takeSummary(), contains('busy=[core:rwkv_replay '));
    SrsOpLedger.end(t);
    final String done = SrsOpLedger.takeSummary()!;
    expect(done, contains('core:rwkv_replay 1x'));
    expect(done, isNot(contains('busy=')));
  });

  test('读回超过阈值的单次操作回调 onHeavy；回调抛异常不影响记账', () {
    final List<String> heavy = <String>[];
    SrsOpLedger.onHeavy = heavy.add;
    final int big = SrsOpLedger.begin('core:stats_bundle');
    SrsOpLedger.end(big, bytes: kSrsOpHeavyBytes, rows: 7);
    final int small = SrsOpLedger.begin('core:study');
    SrsOpLedger.end(small, bytes: 10);
    expect(heavy, hasLength(1));
    expect(heavy.single, startsWith('core:stats_bundle '));
    expect(heavy.single, contains('32.0MB rows=7'));

    SrsOpLedger.onHeavy = (String _) => throw StateError('sink');
    final int again = SrsOpLedger.begin('core:stats_bundle');
    SrsOpLedger.end(again, bytes: kSrsOpHeavyBytes);
    expect(SrsOpLedger.takeSummary(), contains('core:stats_bundle 2x'));
  });

  test('汇总最多列 kSrsOpSummaryTop 项，按总用时排序，多的记 +N', () {
    for (int i = 0; i < kSrsOpSummaryTop + 2; i++) {
      SrsOpLedger.end(SrsOpLedger.begin('op$i'));
    }
    expect(SrsOpLedger.takeSummary(), contains('; +2]'));
  });

  test('SQL 归名：动词 + 首个表，不带参数', () {
    expect(
      srsSqlLedgerName(
        '  SELECT e.entity_kind AS k FROM (SELECT 1 FROM srs_field_edits) m',
      ),
      'sql:SELECT srs_field_edits',
    );
    expect(
      srsSqlLedgerName('UPDATE srs_field_edits SET jslim = ? WHERE rowid = ?'),
      'sql:UPDATE srs_field_edits',
    );
    expect(
      srsSqlLedgerName('INSERT INTO "srs_event_local" (a) VALUES (?)'),
      'sql:INSERT srs_event_local',
    );
    expect(srsSqlLedgerName('PRAGMA user_version'), 'sql:PRAGMA');
  });
}
