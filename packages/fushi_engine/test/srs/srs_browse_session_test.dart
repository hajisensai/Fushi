// 浏览常驻会话（native/fushi_fsrs/src/store/browse.rs）的增量更新：一串随机写入（改旗标 / 暂停 / 搁置 / 作答 /
// 改字段 / 改标签 / 新建 / 删笔记 / 换牌组 / 删牌组 / 跨日）之后，增量会话给出的结果必须与整份重建的会话逐项
// 相同——每轮先用同一组查询把字段列、最后改动时刻装进会话（之后的写入只走增量），写几笔，再比「增量」与
// 「关掉会话重建」两边的行。另验：没有写入时同一条查询直接复用上次的结果（预览返回不重算）。
import 'dart:math';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'srs_browse_vectors_test.dart'
    show buildBrowseVecLibrary, kBrowseVecProfile;

/// 每轮比较的查询：覆盖字段列（全部 / 单列）、`edited:`、按修改时间 / 字段 / 到期排序、两种模式。
const List<(String, SrsBrowseSort, SrsBrowseMode)> _probes =
    <(String, SrsBrowseSort, SrsBrowseMode)>[
      ('', SrsBrowseSort(), SrsBrowseMode.cards),
      ('', SrsBrowseSort(), SrsBrowseMode.notes),
      (
        'eat',
        SrsBrowseSort(column: SrsBrowseSortColumn.sortField, ascending: true),
        SrsBrowseMode.cards,
      ),
      (
        'Expression:*a*',
        SrsBrowseSort(column: SrsBrowseSortColumn.due),
        SrsBrowseMode.notes,
      ),
      (
        'edited:2',
        SrsBrowseSort(column: SrsBrowseSortColumn.modified),
        SrsBrowseMode.cards,
      ),
      (
        'is:due OR is:suspended OR is:buried',
        SrsBrowseSort(
          column: SrsBrowseSortColumn.field,
          fieldName: 'MainDefinition',
          ascending: true,
        ),
        SrsBrowseMode.cards,
      ),
      (
        'flag:1 OR flag:2 OR tag:t*',
        SrsBrowseSort(column: SrsBrowseSortColumn.deck, ascending: true),
        SrsBrowseMode.notes,
      ),
      (
        '-deck:Zeta prop:reps>0',
        SrsBrowseSort(column: SrsBrowseSortColumn.interval),
        SrsBrowseMode.cards,
      ),
    ];

String _rowText(SrsBrowseRow r) =>
    '${r.cardId}|${r.noteId}|${r.sortText}|${r.deckName}|${r.deckId}|'
    '${r.noteTypeName}|${r.queue?.name}|${r.dueInDays}|${r.flag}|'
    '${r.isSuspended}|${r.isBuried}|${r.hasPendingDecision}|${r.cardCount}';

Future<List<String>> _probe(SrsBrowseSession session) async {
  final List<String> out = <String>[];
  for (final (String q, SrsBrowseSort sort, SrsBrowseMode mode) in _probes) {
    final SrsBrowseResult r = await session.query(
      query: q,
      sort: sort,
      mode: mode,
    );
    out.add(
      '$q ${sort.column.name}: '
      '${(await r.all()).map(_rowText).join(' ; ')}',
    );
  }
  return out;
}

/// 原生浏览会话的计数（`browse_stats`）：整份建会话的次数（全局）、这个会话整份建语料的次数、持有者。
Future<({int sessions, int builds, bool live, List<Object?> owners})> _stats(
  SrsDbStore s,
) async {
  final Map<String, Object?> m = (await s.browseCommand(<String, Object?>{
    'op': 'browse_stats',
  })).map;
  return (
    sessions: m['sessions']! as int,
    builds: m['builds']! as int,
    live: m['live']! as bool,
    owners: m['owners']! as List<Object?>,
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // 增量语料（store/browse.rs `View::refresh`）：写过的笔记只重做自己的语料条目。每轮写入之后既要与新建的会话
  // 逐项一致，又不许整份重建语料（计数不变；只有删牌组那一轮 Dart 传来的牌组名变了，重建一次）——关掉增量
  // （写入后不重做条目）结果就对不上，改回「写了就整份重建」计数就对不上。
  test('增量会话与整份重建逐项一致（随机写入）', () async {
    int t = DateTime.utc(2026, 10, 10, 3).millisecondsSinceEpoch;
    final SrsDbStore s = await buildBrowseVecLibrary(() => t, (int v) => t = v);
    final SrsBrowseSession session = SrsBrowseSession(s);
    final Random rng = Random(4);
    final List<String> decks = <String>[
      for (final String p in <String>['Root', 'Root::A', 'Zeta', 'Extra'])
        await s.ensureDeckPath(p),
    ];
    String lapis(String k) => srsLapisFieldId(kBrowseVecProfile, k);
    int created = 0;
    int compared = 0;
    final List<SrsNoteTypeView> types = <SrsNoteTypeView>[
      for (final SrsNoteTypeView v in await s.noteTypes())
        if (v.deletedAt == null && v.fields.isNotEmpty) v,
    ];
    expect(types.length, greaterThan(1));
    int changed = 0;
    for (int round = 0; round < 12; round++) {
      // 先把字段列 / 修改时刻装进会话：之后的写入只能走增量。
      await _probe(session);
      final ({int sessions, int builds, bool live, List<Object?> owners})
      before = await _stats(s);
      for (int k = 0; k < 6; k++) {
        t += 60000 * (1 + rng.nextInt(90));
        final List<SrsBrowseRow> rows = await (await session.query()).all();
        final SrsBrowseRow row = rows[rng.nextInt(rows.length)];
        switch (rng.nextInt(12)) {
          case 0:
            await s.setFlag(row.cardId, rng.nextInt(4));
          case 1:
            await s.setSuspended(row.cardId, !row.isSuspended);
          case 2:
            final int today = (await s.dayContext()).dayIndexOf(t);
            await s.buryUntil(row.cardId, rng.nextBool() ? today + 1 : null);
          case 3:
            await s.answer(row.cardId, 1 + rng.nextInt(4));
          case 4:
            await s.updateNote(
              row.noteId,
              fieldsById: <String, String>{
                lapis('Expression'): 'edit $round/$k <i>eat</i>',
                lapis('MainDefinition'): rng.nextBool() ? 'Zed' : 'alpha',
              },
            );
          case 5:
            await s.updateNote(row.noteId, tags: <String>['t$round', 'n5']);
          case 6:
            await s.createNote(
              noteTypeId: s.lapisNoteTypeId,
              guid: 'bs-${created++}',
              deckId: decks[rng.nextInt(decks.length)],
              fieldsById: <String, String>{
                lapis('Expression'): 'new $round apple',
                lapis('MainDefinition'): 'fresh',
              },
            );
          case 7:
            if (rows.length > 8) await s.deleteNote(row.noteId);
          case 8:
            await s.moveCard(row.cardId, decks[rng.nextInt(decks.length)]);
          case 9:
            // 跨日（会话不重建：日界只影响按此刻现算的列）。
            t += 86400000;
          case 10:
            // 换笔记类型：字段排布、模板（卡）都换了。
            final SrsNoteTypeView from = (await s.noteType(
              (await s.notes(<String>[row.noteId]))[row.noteId]!.noteTypeId,
            ))!;
            final SrsNoteTypeView to = types.firstWhere(
              (SrsNoteTypeView v) => v.id != from.id,
            );
            await s.changeNoteType(
              noteIds: <String>[row.noteId],
              targetTypeId: to.id,
              fieldMap: srsDefaultFieldMap(from, to),
              templateMap: srsDefaultTemplateMap(from, to),
            );
            changed++;
          case _:
            final List<SrsCardCacheRow> cs = await s.cardsOfNote(row.noteId);
            if (cs.isNotEmpty) await s.resetCard(cs.first.id);
        }
      }
      if (round == 7) {
        // 删掉一个牌组：卡归默认牌组（Dart 传来的牌组名变了 → 语料重建）。
        await s.editField(
          SrsEntityKind.deck,
          decks[3],
          SrsFieldKeys.deleted,
          t,
        );
      }
      final List<String> incremental = await _probe(session);
      final ({int sessions, int builds, bool live, List<Object?> owners})
      after = await _stats(s);
      expect(after.sessions, before.sessions, reason: 'round $round');
      expect(
        after.builds,
        before.builds + (round == 7 ? 1 : 0),
        reason: 'round $round: writes must patch the corpus per note',
      );
      await session.close();
      final List<String> fresh = await _probe(session);
      expect(incremental, fresh, reason: 'round $round');
      compared += fresh.length;
    }
    expect(compared, 12 * _probes.length);
    expect(changed, greaterThan(0));
    await session.close();
  });

  // 会话由浏览页与 AnkiConnect 共用（store/browse.rs `Sessions`）：浏览页关闭只注销自己，AnkiConnect 还在用就不
  // 释放、下一个请求不重建；最后一个持有者注销才释放。
  test('浏览页关闭不释放 AnkiConnect 还在用的会话；最后一个持有者注销才释放', () async {
    int t = DateTime.utc(2026, 10, 10, 3).millisecondsSinceEpoch;
    final SrsDbStore s = await buildBrowseVecLibrary(() => t, (int v) => t = v);
    final SrsBrowseSession page = SrsBrowseSession(s);
    final SrsAnkiConnectHandler ac = SrsAnkiConnectHandler(
      store: () async => s,
      instanceId: 'owner-test',
    );
    Future<List<Object?>> tags() async =>
        (await s.browseCommand(<String, Object?>{
              'op': 'anki_tags',
              'owner': SrsAnkiConnectHandler.browseOwner,
            })).map['tags']!
            as List<Object?>;

    await page.query(query: 'eat');
    final List<Object?> before = await tags();
    final ({int sessions, int builds, bool live, List<Object?> owners}) open =
        await _stats(s);
    expect(open.live, isTrue);
    expect(open.owners, hasLength(2));

    await page.close();
    final ({int sessions, int builds, bool live, List<Object?> owners})
    afterPage = await _stats(s);
    expect(afterPage.live, isTrue);
    expect(afterPage.owners, <Object?>[SrsAnkiConnectHandler.browseOwner]);
    expect(await tags(), before);
    expect((await _stats(s)).sessions, open.sessions);

    // 浏览页重开：接着用同一个会话。
    final SrsBrowseSession again = SrsBrowseSession(s);
    await again.query(query: 'eat');
    expect((await _stats(s)).sessions, open.sessions);
    await again.close();

    await ac.close();
    final ({int sessions, int builds, bool live, List<Object?> owners}) closed =
        await _stats(s);
    expect(closed.live, isFalse);
    expect(closed.owners, isEmpty);
    // 再来一个请求：重新建。
    expect(await tags(), before);
    expect((await _stats(s)).sessions, open.sessions + 1);
    await ac.close();
  });

  test('没有写入时同一条查询复用上次的结果；有写入就重算', () async {
    int t = DateTime.utc(2026, 10, 10, 3).millisecondsSinceEpoch;
    final SrsDbStore s = await buildBrowseVecLibrary(() => t, (int v) => t = v);
    final SrsBrowseSession session = SrsBrowseSession(s);
    final SrsBrowseResult a = await session.query(query: 'eat');
    final SrsBrowseResult b = await session.query(query: 'eat', reuse: true);
    expect(identical(a, b), isTrue);
    final SrsBrowseRow first = (await b.all()).first;
    await s.setFlag(first.cardId, 3);
    final SrsBrowseResult c = await session.query(query: 'eat', reuse: true);
    expect(identical(b, c), isFalse);
    expect((await c.all()).first.flag, 3);
    // 会话只留最近几份结果：再查几次后旧结果被挤掉，取行报 SrsBrowseResultGone（页面据此重新查询）。
    for (int i = 0; i < 4; i++) {
      await session.query(query: 'eat $i');
    }
    b.invalidateRows();
    await expectLater(b.all(), throwsA(isA<SrsBrowseResultGone>()));
    await session.close();
  });
}
