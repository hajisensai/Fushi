// 浏览常驻会话（native/fushi_fsrs/src/store/browse.rs）的增量更新：一串随机写入（改旗标 / 暂停 / 搁置 / 作答 /
// 改字段 / 改标签 / 新建 / 删笔记 / 换牌组 / 删牌组 / 跨日）之后，增量会话给出的结果必须与整份重建的会话逐项
// 相同——每轮先用同一组查询把字段列、最后改动时刻装进会话（之后的写入只走增量），写几笔，再比「增量」与
// 「关掉会话重建」两边的行。另验：没有写入时同一条查询直接复用上次的结果（预览返回不重算）。
import 'dart:math';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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
    for (int round = 0; round < 12; round++) {
      // 先把字段列 / 修改时刻装进会话：之后的写入只能走增量。
      await _probe(session);
      for (int k = 0; k < 6; k++) {
        t += 60000 * (1 + rng.nextInt(90));
        final List<SrsBrowseRow> rows = await (await session.query()).all();
        final SrsBrowseRow row = rows[rng.nextInt(rows.length)];
        switch (rng.nextInt(11)) {
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
      await session.close();
      final List<String> fresh = await _probe(session);
      expect(incremental, fresh, reason: 'round $round');
      compared += fresh.length;
    }
    expect(compared, 12 * _probes.length);
    await session.close();
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
