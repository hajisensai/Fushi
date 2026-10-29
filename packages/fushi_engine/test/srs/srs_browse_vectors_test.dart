// 浏览页（搜索 + 排序 + 卡片 / 笔记模式 + 列表行）的输入→输出回归向量。
//
// 向量由**旧的 Dart 实现**（`SrsBrowseSnapshot.load` + `query`：Dart 侧整份快照、Dart 排序，2026-10-29 L4 之前，
// 已删除）在下面的确定性库上生成，存进 fixtures/srs_browse_vectors.json；浏览搬进 Rust 常驻会话
// （`SrsBrowseSession` → native/fushi_fsrs/src/store/browse.rs）之后，新实现逐项给出同样的结果：每条查询 × 每种排序 × 两种模式的行序（主卡、笔记、该行的全部卡），以及每张卡的列表行
// （排序字段、牌组名、笔记类型名、队列、到期天数、旗标、暂停 / 搁置、待裁决）。库里有：两种笔记类型（Lapis、
// 内置 Fushi 卡片：字段别名）、HTML / 大小写 / 希腊文 Σ / 土耳其文 İ / 代理对（UTF-16 序与码点序不同）/ 空排序字段、
// 嵌套牌组与已删除牌组（归默认牌组）、标签、旗标、暂停、搁置、复习卡 / 学习卡 / 新卡、改过的笔记（修改时间）、
// 删除的笔记、同一创建时刻的笔记（按 id 定序）。
//
// 重新生成（只在有意改变浏览语义时；旧实现已删，生成的就是当前实现的输出）：SRS_BROWSE_VECTORS_WRITE=1 跑本文件。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kBrowseVecProfile = '01928c3e-0000-7000-8000-0000000000c4';

final String _fixture =
    '${Directory.current.path}/test/srs/fixtures/srs_browse_vectors.json'
        .replaceAll('\\', '/');

/// 查询（含语法错误 / 不支持的：结果记成 `!error`）。
const List<String> kBrowseVecQueries = <String>[
  '',
  'deck:*',
  'deck:Root',
  'deck:"Root::A"',
  'deck:Default',
  '-deck:Zeta',
  'tag:n5',
  'tag:n5 -tag:verb',
  'tag:none',
  'is:new',
  'is:due',
  'is:review',
  'is:learn',
  'is:suspended',
  'is:buried',
  '-is:new -is:suspended',
  'flag:1',
  'flag:0',
  'prop:reps>1',
  'prop:ivl>=1',
  'prop:due<=1',
  'edited:1',
  'edited:3',
  'added:1',
  'added:10',
  'Expression:*a*',
  'MainDefinition:to*',
  'Expression:',
  'Term:*',
  'eat',
  'σ',
  'ı',
  '"re:(?i)run|eat"',
  'note:Lapis*',
  'note:"Fushi*"',
  'card:1',
  'card:2',
  'prop:ease>2',
  '(tag:n5 OR flag:2) is:review',
];

/// 排序：全部列 × 升降序（指定字段三种：有的、大小写不同、没有这个字段的）。
List<SrsBrowseSort> browseVecSorts() => <SrsBrowseSort>[
  for (final SrsBrowseSortColumn c in SrsBrowseSortColumn.values)
    for (final bool asc in <bool>[true, false])
      if (c == SrsBrowseSortColumn.field)
        for (final String f in <String>[
          'MainDefinition',
          'expression',
          'NoSuchField',
        ])
          SrsBrowseSort(column: c, ascending: asc, fieldName: f)
      else
        SrsBrowseSort(column: c, ascending: asc),
];

String browseVecSortKey(SrsBrowseSort s) =>
    '${s.column.name}${s.fieldName == null ? '' : '(${s.fieldName})'}'
    '${s.ascending ? '+' : '-'}';

/// 生成向量的库。返回 store 与此刻；[t] 由调用方的时钟闭包读。
Future<SrsDbStore> buildBrowseVecLibrary(
  int Function() now,
  void Function(int) setNow,
) async {
  final SrsDbStore s = await openTestStore(
    profileUid: kBrowseVecProfile,
    deviceId: 'bv',
    now: now,
  );
  await s.editField(
    SrsEntityKind.profile,
    kBrowseVecProfile,
    SrsFieldKeys.utcOffsetMin,
    540,
  );
  await s.editField(
    SrsEntityKind.profile,
    kBrowseVecProfile,
    SrsFieldKeys.dayRolloverHour,
    4,
  );
  final String root = await s.ensureDeckPath('Root');
  final String a = await s.ensureDeckPath('Root::A');
  final String b = await s.ensureDeckPath('Root::B');
  final String zeta = await s.ensureDeckPath('Zeta');
  final String gone = await s.ensureDeckPath('Gone');
  final List<String> decks = <String>[root, a, b, zeta, gone];
  final SrsNoteTypeView fushi = (await s.noteTypes()).firstWhere(
    (SrsNoteTypeView t) => t.builtinKey == kSrsBuiltinFushiCardKey,
  );
  String lapis(String k) => srsLapisFieldId(kBrowseVecProfile, k);
  const List<String> exprs = <String>[
    '食べる',
    '<b>走る</b>',
    'apple',
    'Apple',
    'ΟΔΟΣ',
    'İstanbul',
    'ısı',
    '𝔘nicode',
    'ﬃ',
    '',
    '  spaced  ',
    'zebra',
    'éclair',
    'Ärger',
    'a<br>b',
    '﻿bom',
    'run',
    'eat',
  ];
  const List<String> defs = <String>[
    'to eat',
    'to run',
    'fruit',
    '',
    'road',
    'city',
    'heat',
    'odd',
    'ligature',
    'empty',
    'spaces',
    'Animal',
    'pastry',
    'anger',
    'two lines',
    'bom',
    'to RUN',
    'EAT',
  ];
  final List<String> notes = <String>[];
  int t = now();
  for (int i = 0; i < exprs.length; i++) {
    // 每两条同一创建时刻（自然顺序按笔记 id 定）。
    if (i.isEven) t += 60000;
    setNow(t);
    final bool fushiCard = i % 5 == 3;
    final String id = await s.createNote(
      noteTypeId: fushiCard ? fushi.id : s.lapisNoteTypeId,
      guid: 'bv-$i',
      deckId: decks[i % decks.length],
      fieldsById: fushiCard
          ? <String, String>{
              fushi.fields[0].id: exprs[i],
              if (fushi.fields.length > 2) fushi.fields[2].id: defs[i],
            }
          : <String, String>{
              lapis('Expression'): exprs[i],
              lapis('MainDefinition'): defs[i],
            },
      tags: <String>[
        if (i % 3 == 0) 'n5',
        if (i % 4 == 1) 'verb',
        if (i % 7 == 2) 'Σigma',
      ],
    );
    notes.add(id);
  }
  // 复习：几张评分（变复习卡 / 学习卡），隔几天。
  for (int i = 0; i < notes.length; i++) {
    final List<SrsCardCacheRow> cards = await s.cardsOfNote(notes[i]);
    for (final SrsCardCacheRow c in cards) {
      if (i % 3 == 1) await s.answer(c.id, 3);
      if (i % 4 == 2) await s.answer(c.id, 1);
      if (i % 6 == 0) await s.answer(c.id, 4);
    }
  }
  t += 86400000 * 2;
  setNow(t);
  for (int i = 0; i < notes.length; i++) {
    final List<SrsCardCacheRow> cards = await s.cardsOfNote(notes[i]);
    final SrsCardCacheRow c = cards.first;
    if (i % 5 == 0) await s.setFlag(c.id, 1 + i % 3);
    if (i % 7 == 3) await s.setSuspended(c.id, true);
    if (i % 8 == 5) {
      await s.buryUntil(c.id, (await s.dayContext()).dayIndexOf(t) + 1);
    }
    if (i % 6 == 4) await s.answer(c.id, 2);
  }
  // 改过的笔记（修改时间 / edited:）。
  t += 3600000;
  setNow(t);
  await s.updateNote(notes[2], tags: <String>['touched']);
  await s.updateNote(
    notes[5],
    fieldsById: <String, String>{lapis('MainDefinition'): 'metropolis'},
  );
  // 删掉一条笔记、一个牌组（卡归默认牌组）。
  await s.deleteNote(notes[10]);
  await s.editField(SrsEntityKind.deck, gone, SrsFieldKeys.deleted, t);
  t += 3600000;
  setNow(t);
  return s;
}

/// 一行编成 `主卡:该行全部卡`（卡用它在 [cards]（按 id 排序）里的下标，`.` 分隔）。
String browseVecRow(List<String> cards, String primary, List<String> all) =>
    '${cards.indexOf(primary)}:${all.map(cards.indexOf).join('.')}';

/// 浏览会话：每条查询 × 排序 × 模式的行序（[browseVecRow]），与每张卡的列表行。
Future<Map<String, Object?>> browseVectors(SrsDbStore s) async {
  final SrsBrowseSession session = SrsBrowseSession(s);
  final List<SrsBrowseRow> all = await (await session.query()).all();
  final List<String> ids = <String>[
    for (final SrsBrowseRow r in all) r.cardId,
  ]..sort();
  // 笔记模式一行 = 该笔记的全部可见卡（自然顺序），与查询无关。
  final SrsBrowseResult byNote = await session.query(
    mode: SrsBrowseMode.notes,
  );
  final Map<String, List<String>> cardsOf = <String, List<String>>{
    for (final String n in await byNote.ids())
      n: (await byNote.targets(<String>[n])).cardIds,
  };
  final Map<String, Object?> results = <String, Object?>{};
  for (final String q in kBrowseVecQueries) {
    for (final SrsBrowseMode mode in SrsBrowseMode.values) {
      for (final SrsBrowseSort sort in browseVecSorts()) {
        final String key = '$q|${mode.name}|${browseVecSortKey(sort)}';
        try {
          final SrsBrowseResult r = await session.query(
            query: q,
            sort: sort,
            mode: mode,
          );
          results[key] = <String>[
            for (final SrsBrowseRow row in await r.all())
              browseVecRow(
                ids,
                row.cardId,
                mode == SrsBrowseMode.cards
                    ? <String>[row.cardId]
                    : cardsOf[row.noteId]!,
              ),
          ].join(' ');
        } on SrsSearchUnsupported {
          results[key] = '!error';
        }
      }
    }
  }
  final Map<String, Object?> rows = <String, Object?>{
    for (final SrsBrowseRow r in all)
      r.cardId: <Object?>[
        r.noteId,
        r.sortText,
        r.deckName,
        r.noteTypeName,
        r.queue!.name,
        r.dueInDays,
        r.flag,
        r.isSuspended,
        r.isBuried,
        r.hasPendingDecision,
        r.deckId,
      ],
  };
  await session.close();
  return <String, Object?>{'cards': ids, 'results': results, 'rows': rows};
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final bool write = Platform.environment['SRS_BROWSE_VECTORS_WRITE'] == '1';

  test('浏览：查询 × 排序 × 模式 与旧实现的向量逐项一致', () async {
    int t = DateTime.utc(2026, 10, 10, 3).millisecondsSinceEpoch;
    final SrsDbStore s = await buildBrowseVecLibrary(() => t, (int v) => t = v);
    final Map<String, Object?> got = await browseVectors(s);
    if (write) {
      File(
        _fixture,
      ).writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(got)}\n');
      return;
    }
    final Map<String, Object?> want =
        (jsonDecode(File(_fixture).readAsStringSync()) as Map)
            .cast<String, Object?>();
    expect(got['cards'], want['cards']);
    expect(got['rows'], want['rows']);
    final Map<String, Object?> wr = (want['results']! as Map)
        .cast<String, Object?>();
    final Map<String, Object?> gr = (got['results']! as Map)
        .cast<String, Object?>();
    for (final String k in wr.keys) {
      expect(gr[k], wr[k], reason: k);
    }
    expect(gr.keys.toSet(), wr.keys.toSet());
  });
}
