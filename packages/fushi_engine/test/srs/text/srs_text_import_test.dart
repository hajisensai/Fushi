import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/text/srs_text_import.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String _profile = '01928c3e-0000-7000-8000-0000000000c5';

Future<SrsDbStore> _openStore() async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final SrsStorage storage = await openTestSrsStorage();
  int t = DateTime.utc(2026, 11, 16, 12).millisecondsSinceEpoch;
  return SrsDbStore.open(
    core: storage.core,
    profileUid: _profile,
    deviceId: 'dev',
    trustedClock: SrsTrustedClock(
      wallClockMs: () => t++,
      bootClockMs: () => 0,
      bootId: 'boot',
    ),
  );
}

void main() {
  late Directory tmp;
  late SrsDbStore store;
  late SrsNoteTypeView lapis;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('srs_text_import_');
    store = await _openStore();
    lapis = (await store.noteTypes()).firstWhere(
      (SrsNoteTypeView t) => t.name == 'Lapis',
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<SrsTextFile> parse(String name, String text) async {
    final File f = File('${tmp.path}/$name');
    await f.writeAsString(text);
    return parseSrsTextFile(f.path);
  }

  /// Lapis 的前两个字段 ← 第 1、2 列。
  SrsTextImportOptions opts({
    SrsTextDupeMode mode = SrsTextDupeMode.update,
    SrsTextMatchScope scope = SrsTextMatchScope.noteType,
    int? tagsColumn,
    int? deckColumn,
    int? guidColumn,
    List<String> tags = const <String>[],
  }) => SrsTextImportOptions(
    noteTypeId: lapis.id,
    deckId: store.defaultDeckId,
    fieldColumns: <int>[1, 2],
    tagsColumn: tagsColumn,
    deckColumn: deckColumn,
    guidColumn: guidColumn,
    tags: tags,
    dupeMode: mode,
    matchScope: scope,
  );

  Future<List<SrsNoteView>> allNotes() async {
    final Map<String, SrsNoteView?> m = await store.notes(
      await store.entityIds(SrsEntityKind.note),
    );
    return <SrsNoteView>[
      for (final SrsNoteView? n in m.values)
        if (n != null && n.deletedAt == null) n,
    ]..sort((SrsNoteView a, SrsNoteView b) => a.createdAt - b.createdAt);
  }

  String first(SrsNoteView n) => n.field(lapis.fields[0].id);
  String second(SrsNoteView n) => n.field(lapis.fields[1].id);

  test('Anki 文本导出的文件头经原生解析回到 Dart', () async {
    final SrsTextFile f = await parse(
      'export.txt',
      '#separator:Tab\n#html:true\n#tags:a b\n#notetype:Basic\n#deck:日本語\n'
          '#tags column:3\n#guid column:4\n#if matches:preserve\n'
          '#match scope:notetypeDeck\n'
          '猫\t<b>neko</b>\tt1\tg1\n犬\tinu\t\tg2\n',
    );
    expect(f.delimiter, '\t');
    expect(f.html, isTrue);
    expect(f.delimiterFromHeader, isTrue);
    expect(f.total, 2);
    expect(f.rows.first, <String>['猫', '<b>neko</b>', 't1', 'g1']);
    expect(f.tags, <String>['a', 'b']);
    expect(f.noteType, 'Basic');
    expect(f.deck, '日本語');
    expect(f.tagsColumn, 3);
    expect(f.guidColumn, 4);
    expect(f.ifMatches, SrsTextDupeMode.preserve);
    expect(f.matchScope, SrsTextMatchScope.noteTypeAndDeck);
    // 默认列映射跳过声明了用途的列。
    expect(srsTextDefaultFieldColumns(<String>['F', 'B', 'C'], f), <int>[
      1,
      2,
      0,
    ]);
  });

  test('默认列映射：列名与字段名相同的按名字对上', () async {
    final SrsTextFile f = await parse(
      'named.csv',
      '#columns:Back,Front\nb1,f1\n',
    );
    expect(srsTextDefaultFieldColumns(<String>['Front', 'Back'], f), <int>[
      2,
      1,
    ]);
  });

  test('CSV 新增笔记：纯文本转义、空首字段跳过、标签列与额外标签', () async {
    final SrsTextFile f = await parse(
      'cards.csv',
      'front,back,tags\n'
          'cat,"a < b & ""c""",x y\n'
          ',orphan,\n'
          'dog,"line1\nline2",\n',
    );
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: f,
      options: opts(tagsColumn: 3, tags: <String>['imported']),
    );
    expect(r.notesAdded, 3); // 表头行 front,back 也是一条（Anki 同样不认无 # 的表头）
    expect(r.notesSkipped, 1);
    final List<SrsNoteView> notes = await allNotes();
    final SrsNoteView cat = notes.firstWhere(
      (SrsNoteView n) => first(n) == 'cat',
    );
    expect(second(cat), 'a &lt; b &amp; "c"');
    expect(cat.tags.toSet(), <String>{'imported', 'x', 'y'});
    final SrsNoteView dog = notes.firstWhere(
      (SrsNoteView n) => first(n) == 'dog',
    );
    expect(second(dog), 'line1<br>line2');
  });

  test('已存在：更新 / 保留 / 另加', () async {
    await runSrsTextImport(
      store: store,
      file: await parse('a.tsv', 'cat\tv1\ndog\tw1\n'),
      options: opts(tags: <String>['t1']),
    );
    final SrsTextFile again = await parse('b.tsv', 'cat\tv2\ndog\tw1\n');

    final SrsImportReport preserve = await runSrsTextImport(
      store: store,
      file: again,
      options: opts(mode: SrsTextDupeMode.preserve),
    );
    expect(preserve.notesAdded, 0);
    expect(preserve.notesSkipped, 2);

    final SrsImportReport update = await runSrsTextImport(
      store: store,
      file: again,
      options: opts(tags: <String>['t2']),
    );
    expect(update.notesAdded, 0);
    // cat 改了字段；dog 只多了标签，同样算更新。
    expect(update.notesUpdated, 2);
    List<SrsNoteView> notes = await allNotes();
    expect(notes, hasLength(2));
    final SrsNoteView cat = notes.firstWhere(
      (SrsNoteView n) => first(n) == 'cat',
    );
    expect(second(cat), 'v2');
    expect(cat.tags.toSet(), <String>{'t1', 't2'});

    final SrsImportReport noop = await runSrsTextImport(
      store: store,
      file: again,
      options: opts(tags: <String>['t2']),
    );
    expect(noop.notesUpdated, 0);
    expect(noop.notesSkipped, 2);

    final SrsImportReport dup = await runSrsTextImport(
      store: store,
      file: again,
      options: opts(mode: SrsTextDupeMode.duplicate),
    );
    expect(dup.notesAdded, 2);
    notes = await allNotes();
    expect(notes, hasLength(4));
  });

  test('同一份文件里重复的首字段：更新模式合成一条', () async {
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('d.tsv', 'cat\tv1\ncat\tv2\n'),
      options: opts(),
    );
    expect(r.notesAdded, 1);
    final List<SrsNoteView> notes = await allNotes();
    expect(notes, hasLength(1));
    expect(second(notes.single), 'v2');
  });

  test('牌组列：没有的牌组建出来；按牌组匹配时别的牌组里的同名笔记不算已存在', () async {
    await runSrsTextImport(
      store: store,
      file: await parse('e.tsv', 'cat\tv1\tA::B\n'),
      options: opts(deckColumn: 3),
    );
    final SrsDeckTree tree = await store.deckTree();
    final String ab = tree.decks
        .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'A::B')
        .id;
    expect((await allNotes()).single.deckId, ab);

    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('f.tsv', 'cat\tv2\tOther\n'),
      options: opts(deckColumn: 3, scope: SrsTextMatchScope.noteTypeAndDeck),
    );
    expect(r.notesAdded, 1);
    expect(r.notesUpdated, 0);
  });

  test('GUID 列：首字段改了也按 GUID 更新同一条', () async {
    await runSrsTextImport(
      store: store,
      file: await parse('g.tsv', 'cat\tv1\tguid-1\n'),
      options: opts(guidColumn: 3),
    );
    final SrsNoteView before = (await allNotes()).single;
    expect(before.guid, 'guid-1');
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('h.tsv', 'kitten\tv2\tguid-1\n'),
      options: opts(guidColumn: 3),
    );
    expect(r.notesUpdated, 1);
    final SrsNoteView after = (await allNotes()).single;
    expect(after.id, before.id);
    expect(first(after), 'kitten');
  });
}
