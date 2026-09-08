import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_deck_reposition.dart';
import 'package:fushi/src/anki/anki_deck_reposition_runner.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

// 卡组新卡按词频重排的纯函数层 + 编排层：
//   - 字段角色解析（用户映射 → Lapis 出厂 → 常见名 → 首字段）；
//   - 按词典取 rank：只看勾选词典、同读音优先、单本取最小、跨本复合；
//   - 排序：有 rank 在前、无 rank 末尾保序、同 note 相邻、稳定；
//   - runner：写回前落快照，撤销只恢复仍是新卡的那些并删快照。

AnkiCardInfo _card(
  int id, {
  int? note,
  int ord = 0,
  int due = 0,
  int type = 0,
  String model = 'Lapis',
  Map<String, String> fields = const <String, String>{},
}) =>
    AnkiCardInfo(
      cardId: id,
      noteId: note ?? id * 10,
      ord: ord,
      due: due,
      type: type,
      queue: 0,
      modelName: model,
      deckName: 'Mining',
      fields: fields,
    );

FushiTermResult _term(
  String expression,
  String reading,
  Map<String, List<int>> freqs,
) =>
    FushiTermResult(
      expression: expression,
      reading: reading,
      rules: '',
      glossaries: const <FushiGlossaryEntry>[],
      pitches: const <FushiPitchEntry>[],
      frequencies: <FushiFrequencyEntry>[
        for (final MapEntry<String, List<int>> e in freqs.entries)
          FushiFrequencyEntry(
            dictName: e.key,
            frequencies: <FushiFrequency>[
              for (final int v in e.value)
                FushiFrequency(value: v, displayValue: ''),
            ],
          ),
      ],
    );

/// 假引擎：表达式 → 词条表。
AnkiFrequencyLookup _lookup(Map<String, List<FushiTermResult>> table) =>
    (String e) => table[e] ?? const <FushiTermResult>[];

AnkiRepositionCard _rc(int id, int? rank,
        {int? note, int ord = 0, int due = 0}) =>
    AnkiRepositionCard(
      card: _card(id, note: note, ord: ord, due: due),
      expression: 'w$id',
      rank: rank,
    );

void main() {
  group('resolveNoteFieldRoles', () {
    test('当前笔记类型用用户映射', () {
      const AnkiSettings s = AnkiSettings(
        selectedNoteTypeName: 'Mine',
        fieldMappings: <String, String>{
          'Word': '{expression}',
          'Kana': '{reading}',
          'Rank': 'x {frequency-harmonic-rank} y',
        },
      );
      final AnkiNoteFieldRoles r = resolveNoteFieldRoles(
        modelName: 'Mine',
        fieldNames: const <String>['Word', 'Kana', 'Rank', 'Note'],
        settings: s,
      );
      expect(r.expression, 'Word');
      expect(r.reading, 'Kana');
      expect(r.rank, 'Rank');
    });

    test('别的笔记类型回落 Lapis 出厂映射', () {
      final AnkiNoteFieldRoles r = resolveNoteFieldRoles(
        modelName: 'Lapis',
        fieldNames: LapisNoteType.fields,
        settings: const AnkiSettings(selectedNoteTypeName: 'Mine'),
      );
      expect(r.expression, 'Expression');
      expect(r.reading, 'ExpressionReading');
      expect(r.rank, 'FreqSort');
    });

    test('陌生卡型：常见名不区分大小写，再不行首字段当表达式', () {
      final AnkiNoteFieldRoles a = resolveNoteFieldRoles(
        modelName: 'Basic',
        fieldNames: const <String>['Back', 'Front'],
        settings: const AnkiSettings(),
      );
      expect(a.expression, 'Front');
      expect(a.reading, isNull);
      final AnkiNoteFieldRoles b = resolveNoteFieldRoles(
        modelName: 'Weird',
        fieldNames: const <String>['Alpha', 'Beta'],
        settings: const AnkiSettings(),
      );
      expect(b.expression, 'Alpha');
      expect(
          resolveNoteFieldRoles(
            modelName: 'Empty',
            fieldNames: const <String>[],
            settings: const AnkiSettings(),
          ).expression,
          isNull);
    });
  });

  group('ankiFieldPlainText / parseFieldRank', () {
    test('去 ruby 注音、标签、实体，折叠空白', () {
      expect(
        ankiFieldPlainText('<ruby>漢字<rt>かんじ</rt></ruby>&nbsp;<b>x</b>\n y'),
        '漢字 x y',
      );
      expect(ankiFieldPlainText('a &amp; b &lt;c&gt;'), 'a & b <c>');
    });

    test('字段 rank 取前导数字，非法为 null', () {
      expect(parseFieldRank('<span>1520</span>'), 1520);
      expect(parseFieldRank(''), isNull);
      expect(parseFieldRank('n/a'), isNull);
    });
  });

  group('dictionaryRankFor', () {
    final AnkiFrequencyLookup lookup = _lookup(<String, List<FushiTermResult>>{
      '雨': <FushiTermResult>[
        _term('雨', 'あめ', <String, List<int>>{
          'JPDB': <int>[300, 250],
          'BCCWJ': <int>[600]
        }),
        _term('雨', 'う', <String, List<int>>{
          'JPDB': <int>[9000]
        }),
      ],
      '孤': <FushiTermResult>[
        _term('孤', 'こ', <String, List<int>>{
          'Kanji': <int>[5]
        }),
      ],
    });

    test('单本词典内取最小值；未勾选的词典不参与', () {
      expect(
        dictionaryRankFor(
          expression: '雨',
          reading: 'あめ',
          options:
              const AnkiRepositionRankOptions(dictionaries: <String>{'JPDB'}),
          lookup: lookup,
        ),
        250,
      );
      expect(
        dictionaryRankFor(
          expression: '雨',
          reading: 'あめ',
          options:
              const AnkiRepositionRankOptions(dictionaries: <String>{'BCCWJ'}),
          lookup: lookup,
        ),
        600,
      );
    });

    test('多本复合：空集合 = 全部，调和平均 / 取最小', () {
      // 2 / (1/250 + 1/600) = 352.9 → 352
      expect(
        dictionaryRankFor(
          expression: '雨',
          reading: 'あめ',
          options: const AnkiRepositionRankOptions(),
          lookup: lookup,
        ),
        352,
      );
      expect(
        dictionaryRankFor(
          expression: '雨',
          reading: 'あめ',
          options: const AnkiRepositionRankOptions(
            aggregate: FrequencyAggregate.min,
          ),
          lookup: lookup,
        ),
        250,
      );
    });

    test('读音匹配时只看同读音词条；片假名读音也能对上；读音对不上则看全部', () {
      expect(
        dictionaryRankFor(
          expression: '雨',
          reading: 'う',
          options:
              const AnkiRepositionRankOptions(dictionaries: <String>{'JPDB'}),
          lookup: lookup,
        ),
        9000,
      );
      expect(
        dictionaryRankFor(
          expression: '雨',
          reading: 'ウ',
          options:
              const AnkiRepositionRankOptions(dictionaries: <String>{'JPDB'}),
          lookup: lookup,
        ),
        9000,
      );
      expect(
        dictionaryRankFor(
          expression: '雨',
          reading: 'xx',
          options:
              const AnkiRepositionRankOptions(dictionaries: <String>{'JPDB'}),
          lookup: lookup,
        ),
        250,
        reason: '读音对不上时不丢词条，取全部里的最小',
      );
    });

    test('查不到 / 勾选词典没值 / 空表达式 → null', () {
      expect(
        dictionaryRankFor(
          expression: '無',
          reading: '',
          options: const AnkiRepositionRankOptions(),
          lookup: lookup,
        ),
        isNull,
      );
      expect(
        dictionaryRankFor(
          expression: '孤',
          reading: '',
          options:
              const AnkiRepositionRankOptions(dictionaries: <String>{'JPDB'}),
          lookup: lookup,
        ),
        isNull,
      );
      expect(
        dictionaryRankFor(
          expression: '',
          reading: '',
          options: const AnkiRepositionRankOptions(),
          lookup: lookup,
        ),
        isNull,
      );
    });
  });

  group('planCardPositions', () {
    test('有 rank 升序在前，无 rank 末尾保序，位置从 1 连续', () {
      final AnkiRepositionPlan p = planCardPositions('D', <AnkiRepositionCard>[
        _rc(1, null, due: 1),
        _rc(2, 500, due: 2),
        _rc(3, null, due: 3),
        _rc(4, 20, due: 4),
      ]);
      expect(p.ordered.map((AnkiRepositionCard c) => c.card.cardId).toList(),
          <int>[4, 2, 1, 3]);
      expect(p.updates.map((AnkiCardDueUpdate u) => u.due).toList(),
          <int>[1, 2, 3, 4]);
      expect(p.previous.map((AnkiCardDueUpdate u) => u.due).toList(),
          <int>[4, 2, 1, 3]);
      expect(p.ranked, 2);
      expect(p.unranked, 2);
      expect(p.changed, 3, reason: '卡 2 位置 2→2 没变；4/1/3 三张变了');
    });

    test('同 rank 稳定（保持传入次序），同 note 的多张卡相邻并按 ord', () {
      final AnkiRepositionPlan p = planCardPositions('D', <AnkiRepositionCard>[
        _rc(1, 100, note: 7, ord: 1),
        _rc(2, 100, note: 8, ord: 0),
        _rc(3, 100, note: 7, ord: 0),
        _rc(4, 50, note: 9),
      ]);
      expect(p.ordered.map((AnkiRepositionCard c) => c.card.cardId).toList(),
          <int>[4, 3, 1, 2]);
    });

    test('罕见词优先反转有 rank 的部分，无 rank 仍在末尾', () {
      final AnkiRepositionPlan p = planCardPositions(
        'D',
        <AnkiRepositionCard>[_rc(1, 10), _rc(2, null), _rc(3, 30)],
        rareFirst: true,
      );
      expect(p.ordered.map((AnkiRepositionCard c) => c.card.cardId).toList(),
          <int>[3, 1, 2]);
    });

    test('已经有序时 changed == 0', () {
      final AnkiRepositionPlan p = planCardPositions('D', <AnkiRepositionCard>[
        _rc(1, 10, due: 1),
        _rc(2, 20, due: 2),
      ]);
      expect(p.changed, 0);
    });
  });

  group('AnkiDeckRepositionRunner', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('anki_repo_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    AnkiDeckRepositionRunner runner(_FakeRepo repo,
            {AnkiFrequencyLookup? lookup}) =>
        AnkiDeckRepositionRunner(
          repo,
          lookup: lookup ?? _lookup(<String, List<FushiTermResult>>{}),
          snapshotDirectory: () async => tmp,
        );

    test('不支持的后端 plan 返回 null', () async {
      final AnkiRepositionPlan? p =
          await runner(_FakeRepo(supported: false)).plan(
        deckName: 'D',
        settings: const AnkiSettings(),
        options: const AnkiRepositionRankOptions(),
      );
      expect(p, isNull);
    });

    test('词典来源：按旧位置排队、同 note 只查一次、进度回调到位', () async {
      int lookups = 0;
      List<FushiTermResult> lookup(String e) {
        lookups++;
        return <FushiTermResult>[
          _term(e, '', <String, List<int>>{
            'JPDB': <int>[e == '猫' ? 10 : 900]
          }),
        ];
      }

      final _FakeRepo repo = _FakeRepo(cards: <AnkiCardInfo>[
        _card(1,
            note: 5,
            ord: 1,
            due: 30,
            fields: <String, String>{'Expression': '犬'}),
        _card(2, note: 6, due: 20, fields: <String, String>{'Expression': '猫'}),
        _card(3,
            note: 5,
            ord: 0,
            due: 10,
            fields: <String, String>{'Expression': '犬'}),
      ]);
      final List<AnkiRepositionProgress> seen = <AnkiRepositionProgress>[];
      final AnkiRepositionPlan? p = await runner(repo, lookup: lookup).plan(
        deckName: 'D',
        settings: const AnkiSettings(),
        options: const AnkiRepositionRankOptions(),
        onProgress: seen.add,
      );
      expect(lookups, 2, reason: '两张卡同一 note，只查一次');
      expect(p!.ordered.map((AnkiRepositionCard c) => c.card.cardId).toList(),
          <int>[2, 3, 1]);
      expect(p.ordered.first.expression, '猫');
      expect(seen.first.stage, AnkiRepositionStage.fetch);
      expect(seen.last.stage, AnkiRepositionStage.rank);
      expect(seen.last.done, 3);
    });

    test('字段来源：读 FreqSort，不碰引擎', () async {
      final _FakeRepo repo = _FakeRepo(cards: <AnkiCardInfo>[
        _card(1,
            fields: <String, String>{'Expression': 'a', 'FreqSort': '700'}),
        _card(2, fields: <String, String>{'Expression': 'b', 'FreqSort': '5'}),
        _card(3, fields: <String, String>{'Expression': 'c', 'FreqSort': ''}),
      ]);
      final AnkiRepositionPlan? p = await runner(
        repo,
        lookup: (String _) => throw StateError('must not query'),
      ).plan(
        deckName: 'D',
        settings: const AnkiSettings(),
        options:
            const AnkiRepositionRankOptions(source: AnkiRepositionSource.field),
      );
      expect(p!.ordered.map((AnkiRepositionCard c) => c.card.cardId).toList(),
          <int>[2, 1, 3]);
    });

    test('取消在让出点生效并抛 AnkiRepositionCancelled', () async {
      final _FakeRepo repo = _FakeRepo(cards: <AnkiCardInfo>[
        for (int i = 1; i <= AnkiDeckRepositionRunner.kYieldEvery + 1; i++)
          _card(i, fields: <String, String>{'Expression': 'x'}),
      ]);
      bool cancel = false;
      await expectLater(
        runner(repo).plan(
          deckName: 'D',
          settings: const AnkiSettings(),
          options: const AnkiRepositionRankOptions(),
          onProgress: (AnkiRepositionProgress p) {
            if (p.stage == AnkiRepositionStage.rank && p.done > 0) {
              cancel = true;
            }
          },
          shouldCancel: () => cancel,
        ),
        throwsA(isA<AnkiRepositionCancelled>()),
      );
    });

    test('apply 先落快照再写回；undo 只恢复仍是新卡的并删快照', () async {
      final _FakeRepo repo = _FakeRepo(cards: <AnkiCardInfo>[
        _card(1,
            due: 1,
            fields: <String, String>{'Expression': 'a', 'FreqSort': '900'}),
        _card(2,
            due: 2,
            fields: <String, String>{'Expression': 'b', 'FreqSort': '1'}),
      ]);
      final AnkiDeckRepositionRunner r = runner(repo);
      final AnkiRepositionPlan plan = (await r.plan(
        deckName: 'D',
        settings: const AnkiSettings(),
        options:
            const AnkiRepositionRankOptions(source: AnkiRepositionSource.field),
      ))!;
      final AnkiRepositionOutcome out = await r.apply(plan);
      expect(out.written, 2);
      expect(out.failures, isEmpty);
      expect(
          repo.writes.single
              .map((AnkiCardDueUpdate u) => '${u.cardId}:${u.due}'),
          <String>['2:1', '1:2']);
      final File snap = out.snapshot!;
      expect(snap.existsSync(), isTrue);
      final Map<String, dynamic> json =
          jsonDecode(snap.readAsStringSync()) as Map<String, dynamic>;
      expect(json['deckName'], 'D');
      expect(json['positions'], <Object>[
        <String, Object>{'cardId': 2, 'due': 2},
        <String, Object>{'cardId': 1, 'due': 1},
      ]);

      final AnkiRepositionSnapshot? latest = await r.latestSnapshot('D');
      expect(latest, isNotNull);
      expect(await r.latestSnapshot('Other'), isNull);

      // 卡 1 在撤销前被学掉了：不再是新卡，undo 不能碰它。
      repo.cards = <AnkiCardInfo>[_card(2, due: 1)];
      final AnkiRepositionUndoOutcome undo = await r.undo(latest!);
      expect(undo.restored, 1);
      expect(undo.skipped, 1);
      expect(
          repo.writes.last.map((AnkiCardDueUpdate u) => '${u.cardId}:${u.due}'),
          <String>['2:2']);
      expect(snap.existsSync(), isFalse, reason: '撤销成功后快照删除，不会二次撤销');
    });

    test('写回前重校验：预览期间被学掉的卡不写位置，也不进快照', () async {
      // 计划算好时两张都是新卡。
      final _FakeRepo repo = _FakeRepo(cards: <AnkiCardInfo>[
        _card(1, due: 1, fields: <String, String>{'FreqSort': '900'}),
        _card(2, due: 2, fields: <String, String>{'FreqSort': '10'}),
      ]);
      final AnkiDeckRepositionRunner r = runner(repo);
      final AnkiRepositionPlan plan = (await r.plan(
        deckName: 'D',
        settings: const AnkiSettings(),
        options:
            const AnkiRepositionRankOptions(source: AnkiRepositionSource.field),
      ))!;

      // 用户盯着预览弹窗时切去 Anki 学了卡 1：它的 due 已经是「到期日」，
      // 把队列位置写进去就是毁进度。
      repo.cards = <AnkiCardInfo>[
        _card(2, due: 2, fields: <String, String>{'FreqSort': '10'}),
      ];
      final AnkiRepositionOutcome out = await r.apply(plan);

      expect(out.skipped, 1, reason: '卡 1 已不是新卡，必须被跳过');
      expect(
        repo.writes.last.map((AnkiCardDueUpdate u) => u.cardId),
        <int>[2],
        reason: '一条针对卡 1 的写都不许发出去',
      );
      final Map<String, dynamic> json =
          jsonDecode(out.snapshot!.readAsStringSync()) as Map<String, dynamic>;
      expect(
        (json['positions'] as List<dynamic>)
            .map((dynamic e) => (e as Map<String, dynamic>)['cardId']),
        <int>[2],
        reason: '快照只该记我们真的动过的卡',
      );
    });

    test('撤销一张都没恢复时不删快照（唯一的后悔药）', () async {
      final _FakeRepo repo = _FakeRepo(cards: <AnkiCardInfo>[
        _card(1, due: 1, fields: <String, String>{'FreqSort': '900'}),
        _card(2, due: 2, fields: <String, String>{'FreqSort': '10'}),
      ]);
      final AnkiDeckRepositionRunner r = runner(repo);
      final AnkiRepositionPlan plan = (await r.plan(
        deckName: 'D',
        settings: const AnkiSettings(),
        options:
            const AnkiRepositionRankOptions(source: AnkiRepositionSource.field),
      ))!;
      final AnkiRepositionOutcome out = await r.apply(plan);
      final AnkiRepositionSnapshot latest = (await r.latestSnapshot('D'))!;

      // listNewCards 这一刻一张都没返回（卡组改名 / 连接抖动 / 用户手动动过）。
      repo.cards = <AnkiCardInfo>[];
      final AnkiRepositionUndoOutcome undo = await r.undo(latest);

      expect(undo.restored, 0);
      expect(
        out.snapshot!.existsSync(),
        isTrue,
        reason: '一张都没恢复就删快照 = 把唯一的后悔药静默销毁',
      );
    });

    test('坏快照文件被跳过，不影响找最新的', () async {
      File('${tmp.path}/reposition-bad.json').writeAsStringSync('{nope');
      final AnkiDeckRepositionRunner r = runner(_FakeRepo());
      expect(await r.latestSnapshot('D'), isNull);
    });
  });
}

class _FakeRepo extends BaseAnkiRepository {
  _FakeRepo({this.supported = true, this.cards = const <AnkiCardInfo>[]});

  final bool supported;
  List<AnkiCardInfo> cards;
  final List<List<AnkiCardDueUpdate>> writes = <List<AnkiCardDueUpdate>>[];

  @override
  bool get supportsDeckReposition => supported;

  @override
  Future<List<AnkiCardInfo>> listNewCards(String deckName) async =>
      List<AnkiCardInfo>.of(cards);

  @override
  Future<AnkiCardDueWriteResult> setNewCardPositions(
    List<AnkiCardDueUpdate> updates,
  ) async {
    writes.add(List<AnkiCardDueUpdate>.of(updates));
    return AnkiCardDueWriteResult(
      written: updates.length,
      failures: const <int, String>{},
    );
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      MineOutcome.failure('unused');

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => true;

  @override
  Future<bool> createDeck(String name) async => true;
}
