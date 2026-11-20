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
          '#tags column:3\n#guid column:4\n#if matches:keep current\n'
          '#match scope:notetype + deck\n'
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

  test('同一份文件里重复的首字段：互不匹配，两行导成两条（同 Anki）', () async {
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('d.tsv', 'cat\tv1\ncat\tv2\n'),
      options: opts(),
    );
    expect(r.notesAdded, 2);
    expect(r.notesUpdated, 0);
    expect(r.notesSkipped, 0);
    final List<SrsNoteView> notes = await allNotes();
    expect(notes.map(second).toList(), <String>['v1', 'v2']);
  });

  test('同一份文件里首字段相同、GUID 不同的两行：两条都导入', () async {
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('d2.tsv', 'cat\tv1\tguid-a\ncat\tv2\tguid-b\n'),
      options: opts(guidColumn: 3),
    );
    expect(r.notesAdded, 2);
    final List<SrsNoteView> notes = await allNotes();
    expect(notes.map((SrsNoteView n) => n.guid).toSet(), <String>{
      'guid-a',
      'guid-b',
    });
  });

  test('首字段只有图片（查重规范形为空）的行照样导入', () async {
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('img.txt', '#html:true\n<img src="a.png">\tback\n'),
      options: opts(),
    );
    expect(r.notesAdded, 1);
    expect(r.notesSkipped, 0);
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

  test('GUID 列有值但库里没有：当新笔记，不按首字段覆盖同名的已有笔记', () async {
    await runSrsTextImport(
      store: store,
      file: await parse('i.tsv', 'cat\tv1\tguid-1\n'),
      options: opts(guidColumn: 3),
    );
    final SrsNoteView before = (await allNotes()).single;
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('j.tsv', 'cat\tv2\tguid-2\n'),
      options: opts(guidColumn: 3),
    );
    expect(r.notesAdded, 1);
    expect(r.notesUpdated, 0);
    final List<SrsNoteView> notes = await allNotes();
    expect(notes, hasLength(2));
    final SrsNoteView old = notes.firstWhere(
      (SrsNoteView n) => n.id == before.id,
    );
    expect(old.guid, 'guid-1');
    expect(second(old), 'v1');
    final SrsNoteView added = notes.firstWhere(
      (SrsNoteView n) => n.id != before.id,
    );
    expect(added.guid, 'guid-2');
    expect(second(added), 'v2');
  });

  String rowsOf(int n, String value) =>
      <String>[for (int i = 0; i < n; i++) 'w$i\t$value'].join('\n');

  test('纯更新的导入逐行阶段也报中间进度、能叫停（不再只在攒满 500 条新增时）', () async {
    await runSrsTextImport(
      store: store,
      file: await parse('base.tsv', rowsOf(1200, 'v1')),
      options: opts(),
    );
    final List<double> progress = <double>[];
    int asked = 0;
    await expectLater(
      runSrsTextImport(
        store: store,
        file: await parse('upd.tsv', rowsOf(1200, 'v2')),
        options: opts(),
        onProgress: progress.add,
        shouldStop: () => ++asked >= 1,
      ),
      throwsA(isA<SrsImportStopped>()),
    );
    expect(asked, 1);
    expect(progress, hasLength(1));
    expect(progress.single, inExclusiveRange(0, 1));
    // 叫停在更新落库之前：一条都没改。
    expect(
      (await allNotes()).where((SrsNoteView n) => second(n) == 'v2'),
      isEmpty,
    );

    // 不叫停时更新阶段也分批报进度，单调递增到 1。
    progress.clear();
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('upd2.tsv', rowsOf(1200, 'v2')),
      options: opts(),
      onProgress: progress.add,
      shouldStop: () => false,
    );
    expect(r.notesUpdated, 1200);
    expect(progress.length, greaterThan(3));
    for (int k = 1; k < progress.length; k++) {
      expect(progress[k], greaterThan(progress[k - 1]));
    }
    expect(progress.last, 1);
  });

  test('牌组列里新的牌组到要写进去时才建：叫停、跳过的行不留空牌组', () async {
    // 前 500 行进默认牌组；第 501 行起才用新牌组，第一个批间叫停。
    final String text = <String>[
      for (int i = 0; i < 500; i++) 'w$i\tv\t',
      for (int i = 500; i < 600; i++) 'w$i\tv\tNew::Sub',
    ].join('\n');
    await expectLater(
      runSrsTextImport(
        store: store,
        file: await parse('decks.tsv', text),
        options: opts(deckColumn: 3),
        shouldStop: () => true,
      ),
      throwsA(isA<SrsImportStopped>()),
    );
    Future<Set<String>> deckNames() async {
      final SrsDeckTree tree = await store.deckTree();
      return <String>{
        for (final SrsDeckView d in tree.decks) tree.fullName(d.id),
      };
    }

    expect(await deckNames(), isNot(contains('New')));
    expect(await allNotes(), hasLength(500));

    // 首字段为空被跳过的行不建它的牌组；真有新笔记的牌组照建。
    final SrsImportReport r = await runSrsTextImport(
      store: store,
      file: await parse('skip.tsv', '\tv\tGhost\nfresh\tv\tReal\n'),
      options: opts(deckColumn: 3),
    );
    expect(r.notesSkipped, 1);
    expect(r.notesAdded, 1);
    final Set<String> names = await deckNames();
    expect(names, isNot(contains('Ghost')));
    expect(names, contains('Real'));
  });

  test(
    'GUID 列的 guid 在同库另一份 profile 里是另一个笔记类型的笔记：记冲突、不算已添加；同一个笔记类型照常导入（BUG-4843 复核）',
    () async {
      const String other = '01928c3e-0000-7000-8000-0000000000c6';
      final SrsStorage lib = await openTestSrsStorage();
      int clock = DateTime.utc(2026, 11, 16, 12).millisecondsSinceEpoch;
      Future<SrsDbStore> open(String uid) => SrsDbStore.open(
        core: lib.core,
        profileUid: uid,
        deviceId: 'dev',
        trustedClock: SrsTrustedClock(
          wallClockMs: () => clock++,
          bootClockMs: () => 0,
          bootId: 'boot',
        ),
      );
      SrsTextImportOptions into(SrsDbStore s, String noteTypeId) =>
          SrsTextImportOptions(
            noteTypeId: noteTypeId,
            deckId: s.defaultDeckId,
            fieldColumns: <int>[1, 2],
            guidColumn: 3,
            dupeMode: SrsTextDupeMode.update,
            matchScope: SrsTextMatchScope.noteType,
          );
      Future<List<String>> guids(SrsDbStore s) async => <String>[
        for (final SrsNoteView? n in (await s.notes(
          await s.entityIds(SrsEntityKind.note),
        )).values)
          if (n != null && n.deletedAt == null) n.guid,
      ]..sort();

      final SrsDbStore p1 = await open(_profile);
      final SrsDbStore p2 = await open(other);
      final String lapisId = (await p1.noteTypes())
          .firstWhere((SrsNoteTypeView t) => t.name == 'Lapis')
          .id;
      await runSrsTextImport(
        store: p1,
        file: await parse('p1.tsv', 'cat\tv1\tguid-1\n'),
        options: into(p1, lapisId),
      );
      final SrsNoteTypeView fushiCard = (await p2.noteTypes()).firstWhere(
        (SrsNoteTypeView t) => t.id == p2.fushiCardNoteTypeId,
      );
      final SrsImportReport r = await runSrsTextImport(
        store: p2,
        file: await parse('p2.tsv', 'cat\tv1\tguid-1\ndog\tv2\tguid-2\n'),
        options: into(p2, fushiCard.id),
      );
      expect(r.notesAdded, 1);
      expect(
        <(String, String, String)>[
          for (final SrsImportNoteIssue i in r.conflictNotes)
            (i.guid, i.noteType, i.reason),
        ],
        <(String, String, String)>[
          ('guid-1', fushiCard.name, SrsImportIssueReason.otherProfileNoteType),
        ],
      );
      expect(await guids(p2), <String>['guid-2']);
      expect(await guids(p1), <String>['guid-1']);

      // 合法场景：同一个笔记类型导入同一个 guid（同一份内容，并入后合成一份）照常。
      final SrsImportReport same = await runSrsTextImport(
        store: p2,
        file: await parse('p2-same.tsv', 'cat\tv1\tguid-1\n'),
        options: into(p2, lapisId),
      );
      expect(same.notesAdded, 1);
      expect(same.conflictNotes, isEmpty);
      expect(await guids(p2), <String>['guid-1', 'guid-2']);
    },
  );
}
