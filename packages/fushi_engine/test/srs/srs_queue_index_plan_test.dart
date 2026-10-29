// 出卡 / 牌组计数的查询计划（srs.db v9 索引，native/fushi_fsrs/src/store/schema.rs `V9`）：抓下 `nextCard` /
// `deckSummary` / `deckSummaries` 实际发出的 SQL 与参数，逐条 `EXPLAIN QUERY PLAN`，钉住它们走上对应的索引、
// 不回表排序（无 TEMP B-TREE）。复习卡的顺序是「此刻的可提取度」（随此刻变化的表达式），无法建成索引序：
// 只钉候选走到期索引、排序只排到期卡（Rust 侧队列另做）。
//
// 环境变量 SRS_PLAN_OUT 给一个文件路径时，把每条查询与它的计划写进去（汇报用）。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_test_storage.dart';

const String kPlanProfile = '01928c3e-0000-7000-8000-0000000000d7';

/// 记下每条 SELECT（SQL + 参数）。
final class _RecordingInterceptor extends QueryInterceptor {
  final List<(String, List<Object?>)> selects = <(String, List<Object?>)>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects.add((statement, List<Object?>.of(args)));
    return executor.runSelect(statement, args);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final StringBuffer report = StringBuffer();

  tearDownAll(() {
    final String? out = Platform.environment['SRS_PLAN_OUT'];
    if (out != null) File(out).writeAsStringSync(report.toString());
  });

  test(
    'nextCard / deckSummary / deckSummaries 的查询走上 v9 索引，新卡、学习卡、计数无 TEMP B-TREE',
    () async {
      int t = DateTime.utc(2026, 10, 28, 12).millisecondsSinceEpoch;
      final _RecordingInterceptor rec = _RecordingInterceptor();
      final Directory tmp = Directory.systemTemp.createTempSync('srs_plan_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/srs.db',
        interceptor: rec,
      );
      final SrsDbStore s = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: kPlanProfile,
        deviceId: 'dev',
        engine: const FakeFsrsEngine(),
        trustedClock: SrsTrustedClock(
          wallClockMs: () => t,
          monotonicMs: () => t,
          bootId: 'boot-plan',
        ),
        fallbackRolloverHour: () => 4,
      );
      final String root = s.defaultDeckId;
      final String a = await s.createDeck('A', parentId: root);
      final String b = await s.createDeck('B', parentId: root);
      final List<String> cards = <String>[];
      for (int i = 0; i < 24; i++) {
        t += 1000;
        final String note = await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          deckId: <String>[root, a, b][i % 3],
          fieldsById: <String, String>{
            srsLapisFieldId(kPlanProfile, 'Expression'): 'w$i',
            srsLapisFieldId(kPlanProfile, 'FreqSort'): i.isEven
                ? '${100 - i}'
                : '',
          },
        );
        cards.addAll(<String>[for (final c in await s.cardsOfNote(note)) c.id]);
      }
      // 几张学成复习卡（之后推到到期），几张留在学习步。
      for (final String c in cards.take(6)) {
        await s.answer(c, 4);
      }
      for (final String c in cards.skip(6).take(3)) {
        await s.answer(c, 1);
      }

      Future<List<String>> plan(String sql, List<Object?> args) async {
        final List<Map<String, Object?>> rows = srs.core.debugQuery(
          'EXPLAIN QUERY PLAN $sql',
          args,
        );
        return <String>[
          for (final Map<String, Object?> r in rows) '${r['detail']}',
        ];
      }

      /// 抓 [body] 期间的 SELECT，返回其中 SQL 含 [marker] 的那几条的计划（至少一条）。
      Future<Map<String, List<String>>> capture(
        String label,
        Future<void> Function() body,
        Map<String, String> markers,
      ) async {
        rec.selects.clear();
        await body();
        final Map<String, List<String>> out = <String, List<String>>{};
        for (final MapEntry<String, String> m in markers.entries) {
          final List<(String, List<Object?>)> hits = <(String, List<Object?>)>[
            for (final (String, List<Object?>) q in rec.selects)
              if (q.$1.contains(m.value)) q,
          ];
          expect(hits, isNotEmpty, reason: '$label: no query matched ${m.key}');
          final (String sql, List<Object?> args) = hits.first;
          final List<String> p = await plan(sql, args);
          out[m.key] = p;
          report
            ..writeln('## $label / ${m.key}')
            ..writeln(sql)
            ..writeln('-- plan:')
            ..writeAll(p.map((String l) => '   $l\n'))
            ..writeln();
        }
        return out;
      }

      // 不符合的计划先攒着、最后一起报（一次看到全部）。
      final List<String> wrong = <String>[];
      void uses(List<String> p, String index, {bool sorted = true}) {
        final String all = p.join('\n');
        if (!all.contains(index)) wrong.add('want $index:\n$all');
        if (sorted && all.contains('TEMP B-TREE')) {
          wrong.add('want no TEMP B-TREE:\n$all');
        }
      }

      // 新卡（缺省按词频）+ 学习卡 + 子树计数 + 计数上下文的日志。
      final Map<String, List<String>> freq = await capture(
        'nextCard(按词频)',
        () async => expect(await s.nextCard(root), isNotNull),
        <String, String>{
          'learning': 'ORDER BY COALESCE(due_at, 0), id',
          'new(freq)': 'ORDER BY freq_rank IS NULL',
          'tally': 'GROUP BY deck_id',
          'logs(today)': 'CASE WHEN review_type',
          'logs(30d)': '"srs_review_logs"',
        },
      );
      uses(freq['learning']!, 'COVERING INDEX idx_srs_cards_cache_learning');
      uses(freq['new(freq)']!, 'idx_srs_cards_cache_new_freq');
      uses(freq['tally']!, 'COVERING INDEX idx_srs_cards_cache_tally');
      uses(freq['logs(today)']!, 'idx_srs_review_logs_profile_kind_time');
      uses(
        freq['logs(30d)']!,
        'COVERING INDEX idx_srs_review_logs_profile_kind_time',
      );

      await s.editFields(SrsEntityKind.deck, root, <String, Object?>{
        SrsFieldKeys.deckNewOrder: SrsNewCardOrder.position.wire,
      });
      final Map<String, List<String>> pos = await capture(
        'nextCard(按位置)',
        () async => expect(await s.nextCard(root), isNotNull),
        <String, String>{'new(position)': 'ORDER BY new_position IS NULL'},
      );
      uses(pos['new(position)']!, 'idx_srs_cards_cache_new_position');

      // 单个叶子牌组（deck_id IN 只有一个值）同样。
      final Map<String, List<String>> leaf = await capture(
        'nextCard(叶子牌组)',
        () async => expect(await s.nextCard(a), isNotNull),
        <String, String>{'new(leaf)': 'ORDER BY new_position IS NULL'},
      );
      uses(leaf['new(leaf)']!, 'idx_srs_cards_cache_new_position');

      final Map<String, List<String>> summary = await capture(
        'deckSummary',
        () async => expect(await s.deckSummary(root), isNotNull),
        <String, String>{'tally': 'GROUP BY deck_id'},
      );
      uses(summary['tally']!, 'COVERING INDEX idx_srs_cards_cache_tally');

      final Map<String, List<String>> all = await capture(
        'deckSummaries(全部牌组)',
        () async => expect(await s.deckSummaries(), isNotEmpty),
        <String, String>{'tally(all)': 'GROUP BY deck_id'},
      );
      uses(all['tally(all)']!, 'COVERING INDEX idx_srs_cards_cache_tally');

      // 复习卡到期：候选走到期索引（只扫到期卡、不回表），可提取度排序只排这些候选。
      // 学习卡也都到期了，先出它们；排除掉（预取下一张时就是这样排除当前卡的）才轮到复习卡。
      t += 400 * 86400000;
      final Set<String> learning = cards.skip(6).take(3).toSet();
      final Map<String, List<String>> review = await capture(
        'nextCard(复习到期)',
        () async =>
            expect(await s.nextCard(root, exclude: learning), isNotNull),
        <String, String>{'review': '1.0 / (1.0 + (CASE WHEN last_reviewed_at'},
      );
      uses(
        review['review']!,
        'COVERING INDEX idx_srs_cards_cache_review_due',
        sorted: false,
      );
      expect(wrong, isEmpty, reason: wrong.join('\n\n'));
    },
  );
}
