// 有效复习投影（srs.db 的 srs_stat_reviews）的真实库契约（BUG-3772）：
// - 增量维护的结果 = 整份重建的结果 = 参考实现（全部日志按卡分组、前身卡日志并到继承卡、每组选取后分类）；
// - undo / 再答 / 导入 revlog 都随卡片缓存重算；保留原始时刻，日界换了读时重分桶；
// - 更改笔记类型后旧卡的复习归到新卡；对端并发复习旧卡按合并历史分类；新设备首次同步得出同样的行；
// - 笔记彻底清除（v2 Purge）后复习照样计入，重建也不丢；
// - 存量库（缓存修订号 < 2）打开时补齐；
// - 统计读取路径不再读 srs_review_logs。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' hide isNull;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_purge.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine, openTestStore;
import 'support/srs_bulk_fixture.dart' show importBench;
import 'support/srs_test_storage.dart';
import 'support/srs_sync2_peers.dart';

const String _uid = '01928c3e-0000-7000-8000-00000000a682';

/// 记下每条 SELECT 的 SQL（判「读取路径碰没碰日志表」）。
class _SqlLog extends QueryInterceptor {
  final List<String> selects = <String>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects.add(statement);
    return executor.runSelect(statement, args);
  }
}

const int _dayMs = 86400000;
const int _hourMs = 3600000;

/// 投影表原样的行（按日志 ID 排序；一条日志至多一行）。
Future<List<String>> projectionRows(SrsDatabase db) async => <String>[
  for (final QueryRow r
      in await db
          .customSelect(
            'SELECT log_id, card_id, occurred_at, utc_offset_min, rating, kind, '
            'duration_ms, prev_due_day, maturity_delta FROM srs_stat_reviews '
            'ORDER BY log_id',
          )
          .get())
    jsonEncode(r.data),
];

/// 统计页读到的复习记录 + 成熟变化（排序后逐条比较）。
Future<List<String>> fromLoader(SrsDbStore s, SrsDayContext day) async {
  final SrsStatsData d = (await loadSrsStats(s, day: day)).data;
  return <String>[...d.reviews.map(_review), ...d.maturityEvents.map(_maturity)]
    ..sort();
}

/// 参考实现：删除前的 Dart 旧算法语义（BUG-3772 之前的 `srsStatsFromHistory` 逐条照抄）。
///
/// - 全部日志（落库原文 + 本机记下的服务器时刻）按卡分组；
/// - 归属：卡自己可见 → 自己；否则 [SrsDbStore.historyOwnerIndex]（继承它历史的可见卡，id 最小）；
/// - **新规则**（旧实现没有）：都不可见（笔记已删）时归它的后代里没有后代者（链尾）中 id 最小的；
///   没有后代 → 归自己。旧实现在「换类型后又删笔记」时把旧卡日志留在旧卡名下单独重放，这里有意按新规则写，
///   与 `SrsDbStore._refreshStatProjection` 同；后代按链接表（[SrsDbStore.successorIndex]）传递求；
/// - 每个归属组的日志合成一份 [SrsCardHistory] 选取有效日志，按合并历史分类；记录的卡 = 归属卡。
Future<List<String>> fromReference(SrsDbStore s, SrsDayContext day) async {
  final Map<String, List<SrsReviewLog>> byCard = <String, List<SrsReviewLog>>{};
  for (final QueryRow r
      in await s.db
          .customSelect(
            'SELECT card_id, json FROM srs_review_logs WHERE profile_uid = ?',
            variables: <Variable<Object>>[
              Variable<String>(s.profileUid, srsIdType),
            ],
          )
          .get()) {
    (byCard[r.read<String>('card_id')] ??= <SrsReviewLog>[]).add(
      SrsReviewLog.fromJson(
        (jsonDecode(r.read<String>('json')) as Map).cast<String, Object?>(),
      ),
    );
  }
  final Map<String, int> serverTimes = <String, int>{
    for (final QueryRow r
        in await s.db
            .customSelect(
              'SELECT event_id, server_time FROM srs_event_local '
              'WHERE server_time IS NOT NULL',
            )
            .get())
      r.read<String>('event_id'): r.read<int>('server_time'),
  };
  final Set<String> visible = <String>{
    for (final SrsCardCacheRow c in await s.allCardRows())
      if (!c.hidden) c.id,
  };
  final Map<String, String> inherited = await s.historyOwnerIndex();
  final Map<String, List<String>> succ = await s.successorIndex();

  Set<String> descendantsOf(String c) {
    final Set<String> out = <String>{};
    final List<String> queue = <String>[...?succ[c]];
    while (queue.isNotEmpty) {
      final String x = queue.removeLast();
      if (x == c || !out.add(x)) continue;
      queue.addAll(succ[x] ?? const <String>[]);
    }
    return out;
  }

  String ownerOf(String c) {
    if (visible.contains(c)) return c;
    final String? heir = inherited[c];
    if (heir != null) return heir;
    final Set<String> d = descendantsOf(c);
    if (d.isEmpty) return c;
    final List<String> tails = <String>[
      for (final String x in d)
        if (succ[x]?.isEmpty ?? true) x,
    ]..sort();
    return tails.isNotEmpty ? tails.first : (d.toList()..sort()).first;
  }

  final Map<String, List<SrsReviewLog>> groups = <String, List<SrsReviewLog>>{};
  for (final MapEntry<String, List<SrsReviewLog>> e in byCard.entries) {
    (groups[ownerOf(e.key)] ??= <SrsReviewLog>[]).addAll(e.value);
  }
  final List<String> out = <String>[];
  for (final MapEntry<String, List<SrsReviewLog>> g in groups.entries) {
    final SrsCardHistory h = SrsCardHistory(
      g.value,
      serverTimeOf: (String id) => serverTimes[id],
    );
    final ({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity})
    one = _classify(g.key, h, day);
    out.addAll(one.reviews.map(_review));
    out.addAll(one.maturity.map(_maturity));
  }
  return out..sort();
}

/// 旧 `srsStatsFromHistory`（c82c1eb7a9 之前的 lib/srs/srs_stats.dart）照抄，记录的卡换成归属卡 [owner]。
({List<SrsStatReview> reviews, List<SrsStatMaturityEvent> maturity}) _classify(
  String owner,
  SrsCardHistory history,
  SrsDayContext day,
) {
  final List<SrsStatReview> reviews = <SrsStatReview>[];
  final List<SrsStatMaturityEvent> maturity = <SrsStatMaturityEvent>[];
  SrsScheduleResult prev = SrsScheduleResult.initial;
  bool prevMature = false;
  for (final SrsReviewLog l in history.effective) {
    final int dayIndex = day.dayIndexOf(l.occurredAt);
    final int? rating = l.rating;
    if (l.kind == SrsLogKind.review &&
        rating != null &&
        rating >= 1 &&
        rating <= 4) {
      final SrsStatReviewKind? kind = switch (l.reviewType) {
        SrsReviewType.learn =>
          prev.queue == SrsQueue.newCard
              ? SrsStatReviewKind.newCard
              : SrsStatReviewKind.learn,
        SrsReviewType.review =>
          prev.scheduledDays >= kSrsMatureIntervalDays
              ? SrsStatReviewKind.mature
              : SrsStatReviewKind.young,
        SrsReviewType.relearn => SrsStatReviewKind.relearn,
        SrsReviewType.filtered => SrsStatReviewKind.filtered,
        _ => null,
      };
      if (kind != null) {
        final int offsetMs = l.utcOffsetMin * 60000;
        reviews.add(
          SrsStatReview(
            cardId: owner,
            at: l.occurredAt,
            day: dayIndex,
            hour: ((l.occurredAt + offsetMs) % _dayMs) ~/ _hourMs,
            rating: rating,
            kind: kind,
            durationMs: math.max(0, l.durationMs),
            early:
                l.algorithm != SrsAlgorithm.rwkv.wire &&
                l.reviewType == SrsReviewType.review &&
                prev.queue == SrsQueue.review &&
                prev.dueDay != null &&
                prev.dueDay! > dayIndex,
          ),
        );
      }
    }
    final SrsScheduleResult? res = l.result;
    if (res == null) continue;
    final bool mature =
        res.queue == SrsQueue.review &&
        res.scheduledDays >= kSrsMatureIntervalDays;
    if (mature != prevMature) {
      maturity.add(
        SrsStatMaturityEvent(
          cardId: owner,
          day: dayIndex,
          delta: mature ? 1 : -1,
        ),
      );
      prevMature = mature;
    }
    prev = res;
  }
  return (reviews: reviews, maturity: maturity);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  // JST 2026-10-14 10:00。
  int now = DateTime.utc(2026, 10, 14, 1).millisecondsSinceEpoch;
  const SrsDayContext jst = SrsDayContext(rolloverHour: 4, utcOffsetMin: 540);

  late _SqlLog sql;
  late TestSrs srs;
  late SrsDatabase db;
  late SrsDbStore store;

  Future<SrsDbStore> open() => SrsDbStore.open(
    db: db,
    core: srs.core,
    profileUid: _uid,
    deviceId: 'dev',
    engine: const FakeFsrsEngine(),
    trustedClock: SrsTrustedClock(wallClockMs: () => now, bootId: 'b'),
    fallbackRolloverHour: () => 4,
  );

  setUp(() async {
    now = DateTime.utc(2026, 10, 14, 1).millisecondsSinceEpoch;
    sql = _SqlLog();
    final Directory tmp = Directory.systemTemp.createTempSync('srs_stat_proj_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    srs = await openTestSrsAt('${tmp.path}/srs.db', interceptor: sql);
    db = srs.db;
    store = await open();
  });

  /// 导入 3 条笔记（6 张卡、每卡 3 条 revlog）+ 原生复习 / 撤销 / 隔天再答。
  Future<void> scenario() async {
    await importBench(store, 3);
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await store.allCardRows()) c.id,
    ]..sort();
    await store.answer(cards[0], 3, durationMs: 4000);
    final SrsReviewLog wrong = await store.answer(cards[1], 1);
    expect(await store.undo(cards[1], wrong.id), isTrue);
    now += 26 * 3600 * 1000;
    await store.answer(cards[0], 4, durationMs: 2500);
    await store.answer(cards[2], 2, durationMs: 9000);
  }

  test('增量 = 整份重建 = 参考实现（按卡分组、前身并到继承卡、选取后分类）', () async {
    await scenario();
    final List<String> incremental = await projectionRows(db);
    expect(incremental, isNotEmpty);
    final List<String> want = await fromReference(store, jst);
    expect(want.where((String s) => s.startsWith('r ')), hasLength(6 * 3 + 3));
    expect(await fromLoader(store, jst), want);

    await store.rebuildCaches();
    expect(await projectionRows(db), incremental);
    expect(await fromLoader(store, jst), want);
  });

  test('undo 撤掉的复习不在投影里，再答进来；原始时刻保留、日界读时重分桶', () async {
    await importBench(store, 1);
    final String card = (await store.allCardRows()).first.id;
    final int before = (await projectionRows(db)).length;
    final SrsReviewLog l = await store.answer(card, 3, durationMs: 1234);
    expect(await projectionRows(db), hasLength(before + 1));
    expect(await store.undo(card, l.id), isTrue);
    expect(await projectionRows(db), hasLength(before));

    // JST 次日凌晨 2 点：按 4 点翻日算 10/14，按 0 点翻日算 10/15。
    now = DateTime.utc(2026, 10, 14, 17).millisecondsSinceEpoch;
    final SrsReviewLog again = await store.answer(card, 3, durationMs: 777);
    final QueryRow row = await db
        .customSelect(
          'SELECT occurred_at, duration_ms FROM srs_stat_reviews '
          'WHERE log_id = ?',
          variables: <Variable<Object>>[Variable<String>(again.id, srsIdType)],
        )
        .getSingle();
    expect(row.read<int>('occurred_at'), now);
    expect(row.read<int>('duration_ms'), 777);

    int dayOf(SrsStatsData d) =>
        d.reviews.firstWhere((SrsStatReview r) => r.at == now).day;
    final SrsStatsData at4 = (await loadSrsStats(store, day: jst)).data;
    const SrsDayContext midnight = SrsDayContext(
      rolloverHour: 0,
      utcOffsetMin: 540,
    );
    final SrsStatsData at0 = (await loadSrsStats(store, day: midnight)).data;
    expect(dayOf(at4), srsDateToDay(2026, 10, 14));
    expect(dayOf(at0), srsDateToDay(2026, 10, 15));
    expect(await fromLoader(store, jst), await fromReference(store, jst));
  });

  Future<String> cacheRev() async {
    final String json =
        (await db.customSelect('SELECT json FROM srs_local_state').getSingle())
            .read<String>('json');
    return '${(jsonDecode(json) as Map)['cacheRev']}';
  }

  test('存量库（缓存修订号 1、投影表为空）打开时补齐', () async {
    await scenario();
    final List<String> want = await projectionRows(db);
    expect(await cacheRev(), '8');
    await db.customStatement('DELETE FROM srs_stat_reviews');
    await db.customStatement(
      "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 1)",
    );
    expect(await projectionRows(db), isEmpty);

    store = await open();
    expect(await projectionRows(db), want);
    expect(await cacheRev(), '8');
    expect(await fromLoader(store, jst), await fromReference(store, jst));
  });

  test('缓存修订号 2 → 当前的升级不动投影（只补笔记缓存的媒体引用）', () async {
    await scenario();
    final List<String> want = await projectionRows(db);
    await db.customStatement(
      "UPDATE srs_local_state SET json = json_set(json, '\$.cacheRev', 2)",
    );
    store = await open();
    expect(await projectionRows(db), want);
    expect(await cacheRev(), '8');
  });

  test('统计读取路径不读复习日志表（大量日志：240 条笔记 × 2 卡 × 4 条）', () async {
    await importBench(store, 240);
    final int logs =
        (await db
                .customSelect('SELECT COUNT(*) AS c FROM srs_review_logs')
                .getSingle())
            .read<int>('c');
    expect(logs, greaterThanOrEqualTo(1440));
    sql.selects.clear();
    final SrsStatsBundle b = await loadSrsStats(store, day: jst, nowMs: now);
    expect(b.data.reviews, hasLength(240 * 2 * 3));
    expect(
      sql.selects.where((String s) => s.contains('srs_review_logs')),
      isEmpty,
      reason: '统计页回到全量读日志 + 逐条 jsonDecode，就会随日志量线性变慢',
    );
    expect(await fromLoader(store, jst), await fromReference(store, jst));
  });

  test('删笔记 → 彻底清除：投影不变（复习照样计入），再整份重建仍不变', () async {
    final String expr = srsLapisFieldId(_uid, 'Expression');
    final String note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{expr: '猫'},
    );
    final String keep = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{expr: '犬'},
    );
    final String card = (await store.cardsOfNote(note)).single.id;
    final String other = (await store.cardsOfNote(keep)).single.id;
    await store.answer(card, 3, durationMs: 3000);
    now += 26 * 3600 * 1000;
    await store.answer(card, 4, durationMs: 2000);
    await store.answer(other, 3, durationMs: 1000);
    final List<String> before = await projectionRows(db);
    final List<String> stats = await fromLoader(store, jst);
    expect(stats.where((String s) => s.startsWith('r ')), hasLength(3));
    expect(stats, await fromReference(store, jst));

    await store.deleteNote(note);
    expect(await projectionRows(db), before, reason: '删除只隐藏卡，复习仍归自己');
    final SrsPurgeReport r = await srsPurgeNotesNow(store, <String>[note]);
    expect(r.notes, 1);
    expect(
      (await store.cardRow(card))!.hidden,
      isTrue,
      reason: '彻底清除只抹内容：卡行留着（复习历史要用），不再出现在队列',
    );
    expect(await projectionRows(db), before);
    expect(await fromLoader(store, jst), stats);

    await store.rebuildCaches();
    expect(await projectionRows(db), before, reason: '重建按全部有日志的卡算投影，含已没有缓存行的卡');
    expect(await fromLoader(store, jst), stats);
    expect(await fromReference(store, jst), stats);
  });

  group('更改笔记类型 / 两台设备', () {
    late SrsMemoryLocationStore dir;

    setUp(() => dir = SrsMemoryLocationStore());

    Future<SrsDbStore> device(String id) =>
        openTestStore(profileUid: _uid, deviceId: id, now: () => now);

    Future<void> syncAll(List<SrsDbStore> stores) async {
      for (int round = 0; round < 3; round++) {
        for (final SrsDbStore s in stores) {
          await srsSyncOnce(s, dir);
        }
      }
    }

    test('反向笔记一张卡复习两次后换类型：增量 = 重建 = 新设备首次同步；2 条复习归新卡', () async {
      final SrsDbStore a = await device('a');
      final String from = await a.createStockNoteType(
        SrsStockNoteType.basicReversed,
        'Rev',
      );
      final String to = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      final SrsNoteTypeView vf = (await a.noteType(from))!;
      final SrsNoteTypeView vt = (await a.noteType(to))!;
      final String note = await a.createNote(
        noteTypeId: from,
        fieldsById: <String, String>{
          vf.fields[0].id: '猫',
          vf.fields[1].id: 'cat',
        },
      );
      final String card2 = SrsIds.card(note, vf.templates[1].id, 0);
      await a.answer(card2, 3, durationMs: 1500);
      now += 26 * 3600 * 1000;
      await a.answer(card2, 3, durationMs: 2500);
      final List<String> beforeChange = await fromLoader(a, jst);
      expect(beforeChange.where((String s) => s.startsWith('r ')), <Matcher>[
        startsWith('r $card2 '),
        startsWith('r $card2 '),
      ]);

      await a.changeNoteType(
        noteIds: <String>[note],
        targetTypeId: to,
        fieldMap: <String, String?>{
          vt.fields[0].id: vf.fields[1].id,
          vt.fields[1].id: vf.fields[0].id,
        },
        templateMap: <String, String?>{vt.templates[0].id: vf.templates[1].id},
      );
      final String newCard = SrsIds.card(note, vt.templates[0].id, 0);
      expect(await a.cardRow(card2), isNull, reason: '前身卡不再生成，删缓存行；增量与重建同一张表');

      final List<String> incremental = await projectionRows(a.db);
      final List<String> stats = await fromLoader(a, jst);
      final List<String> reviews = <String>[
        for (final String s in stats)
          if (s.startsWith('r ')) s,
      ];
      expect(reviews, hasLength(2));
      expect(reviews, everyElement(startsWith('r $newCard ')));
      // 分类按合并历史：与换类型前那张卡上的两条逐项相同，只是卡换了。
      expect(stats, <String>[
        for (final String s in beforeChange) s.replaceAll(card2, newCard),
      ]);
      expect(stats, await fromReference(a, jst));

      await a.rebuildCaches();
      expect(await projectionRows(a.db), incremental);
      expect(await fromLoader(a, jst), stats);

      final SrsDbStore b = await device('b');
      await syncAll(<SrsDbStore>[a, b]);
      expect(await projectionRows(b.db), incremental);
      expect(await fromLoader(b, jst), stats);
      expect(await fromReference(b, jst), stats);

      // 新规则：换类型后又删笔记，前身与新卡都不可见 → 旧卡的复习归链尾（新卡），不回落到旧卡名下。
      await b.deleteNote(note);
      expect((await b.cardRow(newCard))!.hidden, isTrue);
      expect(await projectionRows(b.db), incremental);
      expect(await fromLoader(b, jst), stats);
      expect(await fromReference(b, jst), stats);
      await b.rebuildCaches();
      expect(await projectionRows(b.db), incremental);
    });

    test('对端并发复习旧卡（还没收到换类型）：分类与成熟净值按合并历史', () async {
      final SrsDbStore a = await device('a');
      final SrsDbStore b = await device('b');
      // 新卡 → 学习 → 成熟要经过学习步：RWKV 牌组缺省不用步长，这里写上步长。
      await a.editFields(SrsEntityKind.deck, a.defaultDeckId, <String, Object?>{
        SrsFieldKeys.deckSteps: <String, Object?>{
          'learn': <double>[1, 10],
          'relearn': <double>[10],
        },
      });
      final String to = await a.createStockNoteType(
        SrsStockNoteType.basic,
        'Basic',
      );
      final SrsNoteTypeView lapis = (await a.noteType(a.lapisNoteTypeId))!;
      final SrsNoteTypeView vt = (await a.noteType(to))!;
      final String expr = srsLapisFieldId(_uid, 'Expression');
      final String note = await a.createNote(
        noteTypeId: lapis.id,
        fieldsById: <String, String>{expr: '犬'},
      );
      final String oldCard = (await a.cardsOfNote(note)).single.id;
      await a.answer(oldCard, 3, durationMs: 1000);
      now += 26 * 3600 * 1000;
      await a.answer(oldCard, 4, durationMs: 2000);
      await syncAll(<SrsDbStore>[a, b]);

      await a.changeNoteType(
        noteIds: <String>[note],
        targetTypeId: to,
        fieldMap: srsDefaultFieldMap(lapis, vt)..[vt.fields[0].id] = expr,
        templateMap: <String, String?>{
          vt.templates[0].id: lapis.templates[0].id,
        },
      );
      now += 30 * 24 * 3600 * 1000;
      final SrsReviewLog offline = await b.answer(oldCard, 3, durationMs: 3000);
      await syncAll(<SrsDbStore>[a, b]);
      final String newCard = SrsIds.card(note, vt.templates[0].id, 0);

      final List<String> stats = await fromLoader(a, jst);
      final List<String> reviews = <String>[
        for (final String s in stats)
          if (s.startsWith('r ')) s,
      ];
      expect(reviews, hasLength(3));
      expect(reviews, everyElement(startsWith('r $newCard ')));
      expect(
        reviews.where((String s) => s.contains(' ${offline.occurredAt} ')),
        hasLength(1),
        reason: '对端那次复习流到新卡上',
      );
      expect(stats, await fromReference(a, jst));

      int maturityNet(List<String> s) => s
          .where((String x) => x.startsWith('m '))
          .fold(0, (int acc, String x) => acc + int.parse(x.split(' ').last));
      final SrsCardCacheRow c = (await a.cardRow(newCard))!;
      expect(c.lastLogId, offline.id);
      // 对端那次复习的前序状态来自 a 在旧卡上的两次（合并历史，同步 v2 重放）：新卡 → 学习 → 成熟（a 第二次评
      // 「简单」时按确定性 FSRS 的真实间隔已 ≥ 21 天；旧实现用替身引擎的固定间隔，这里曾是「年轻」）。
      expect(
        <String>[for (final String s in reviews) s.split(' ')[6]],
        <String>['newCard', 'learn', 'mature'],
      );
      expect(maturityNet(stats), 1);
      expect(
        maturityNet(stats),
        c.queue == SrsQueue.review.wire &&
                c.scheduledDays >= kSrsMatureIntervalDays
            ? 1
            : 0,
        reason: '成熟净值 = 新卡当前是否成熟（按合并历史的最后状态）',
      );

      expect(await projectionRows(b.db), await projectionRows(a.db));
      expect(await fromLoader(b, jst), stats);
      expect(await fromReference(b, jst), stats);
      final List<String> incremental = await projectionRows(a.db);
      await a.rebuildCaches();
      expect(await projectionRows(a.db), incremental);
    });
  });
}

String _review(SrsStatReview r) =>
    'r ${r.cardId} ${r.at} ${r.day} ${r.hour} ${r.rating} ${r.kind.name} '
    '${r.durationMs} ${r.early}';

String _maturity(SrsStatMaturityEvent m) => 'm ${m.cardId} ${m.day} ${m.delta}';
