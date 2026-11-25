import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 冷启动不等查词历史：`loadFromDb(deferHistory: true)` 装完词典元数据就返回，历史等
/// `startDeferredHistoryLoad()` 放行后才读库、在后台 isolate 里解析，落定前改历史的
/// 操作排队——排在装进来的旧历史之后、且不把还没装进来的旧历史整表覆盖掉。

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

DictionarySearchResult _result(String searchTerm, {int scrollPosition = 0}) =>
    DictionarySearchResult(
      searchTerm: searchTerm,
      entries: <DictionaryEntry>[
        DictionaryEntry(word: searchTerm, meaning: 'meaning of $searchTerm'),
      ],
      bestLength: searchTerm.length,
      scrollPosition: scrollPosition,
    );

/// 往库里放 [terms] 这几条历史（走真实的写穿路径），返回后库里就是这份快照。
Future<void> _seedHistory(FushiDatabase db, List<String> terms) async {
  final DictionaryRepository seeder = DictionaryRepository(db);
  await seeder.loadFromDb();
  for (final String term in terms) {
    seeder.addHistoryResult(_result(term), 10);
  }
  await seeder.flushDictionaryHistoryNow();
  seeder.dispose();
}

Future<List<String>> _persistedTerms(FushiDatabase db) async {
  final DictionaryRepository reader = DictionaryRepository(db);
  await reader.loadFromDb();
  final List<String> terms = <String>[
    for (final DictionarySearchResult r in reader.dictionaryHistory)
      r.searchTerm,
  ];
  reader.dispose();
  return terms;
}

void main() {
  late FushiDatabase db;

  setUp(() => db = _testDb());
  tearDown(() => db.close());

  test('deferHistory：返回时历史还没装、标着装载中，落定后回调一次', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    int loadedCalls = 0;
    final DictionaryRepository repo = DictionaryRepository(
      db,
      onHistoryLoaded: () => loadedCalls++,
    );
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    expect(repo.dictionaryHistoryLoading, isTrue);
    expect(repo.dictionaryHistory, isEmpty);
    expect(loadedCalls, 0);

    // 没放行就一直是装载中：连库都不读（启动期别的查询不排在这张大表后面）。
    await pumpEventQueue();
    expect(repo.dictionaryHistoryLoading, isTrue);
    expect(repo.dictionaryHistory, isEmpty);
    expect(loadedCalls, 0);

    repo.startDeferredHistoryLoad();
    await repo.dictionaryHistoryLoaded;
    expect(repo.dictionaryHistoryLoading, isFalse);
    expect(repo.dictionaryHistory.map((r) => r.searchTerm), <String>['猫', '犬']);
    expect(loadedCalls, 1);
  });

  test('不带 deferHistory：返回时历史已经在内存里', () async {
    await _seedHistory(db, <String>['猫']);
    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);

    await repo.loadFromDb();
    expect(repo.dictionaryHistoryLoading, isFalse);
    expect(repo.dictionaryHistory.single.searchTerm, '猫');
  });

  test('装载中查的词排在旧历史之后，落库不丢旧历史', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    repo.addHistoryResult(_result('鳥'), 10);
    // 还没落定：这条新词不能先进内存（随后的整表写穿会把旧历史覆盖成只剩它）。
    expect(repo.dictionaryHistory, isEmpty);

    await repo.flushDictionaryHistoryNow();
    expect(repo.dictionaryHistory.map((r) => r.searchTerm), <String>[
      '猫',
      '犬',
      '鳥',
    ]);
    expect(await _persistedTerms(db), <String>['猫', '犬', '鳥']);
  });

  test('装载中重查旧词：去重后挪到末尾', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    repo.addHistoryResult(_result('猫'), 10);
    repo.startDeferredHistoryLoad();
    await repo.dictionaryHistoryLoaded;

    expect(repo.dictionaryHistory.map((r) => r.searchTerm), <String>['犬', '猫']);
  });

  test('装载中删一条历史：落定后生效并落库', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    repo.removeHistoryResult('猫');
    await repo.flushDictionaryHistoryNow();

    expect(repo.dictionaryHistory.single.searchTerm, '犬');
    expect(await _persistedTerms(db), <String>['犬']);
  });

  test('装载中清空历史：旧历史不复活，排队的操作作废', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    repo.addHistoryResult(_result('鳥'), 10);
    await repo.clearDictionaryHistory();
    await repo.flushDictionaryHistoryNow();

    expect(repo.dictionaryHistoryLoading, isFalse);
    expect(repo.dictionaryHistory, isEmpty);
    expect(await _persistedTerms(db), isEmpty);
  });

  test('装载中 dispose：不再回调，旧历史不落进已释放的仓库', () async {
    await _seedHistory(db, <String>['猫']);
    int loadedCalls = 0;
    final DictionaryRepository repo = DictionaryRepository(
      db,
      onHistoryLoaded: () => loadedCalls++,
    );

    await repo.loadFromDb(deferHistory: true);
    final Future<void> loaded = repo.dictionaryHistoryLoaded;
    repo.dispose();
    await loaded;

    expect(loadedCalls, 0);
    expect(repo.dictionaryHistory, isEmpty);
    expect(await _persistedTerms(db), <String>['猫']);
  });

  test('没放行就重载（切 Profile）：上一轮装载了结，本轮照常装进来', () async {
    await _seedHistory(db, <String>['猫']);
    int loadedCalls = 0;
    final DictionaryRepository repo = DictionaryRepository(
      db,
      onHistoryLoaded: () => loadedCalls++,
    );
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    await repo.loadFromDb();

    expect(repo.dictionaryHistoryLoading, isFalse);
    expect(repo.dictionaryHistory.single.searchTerm, '猫');
    await pumpEventQueue();
    expect(repo.dictionaryHistory.single.searchTerm, '猫');
  });

  test('坏行跳过，其余照常装进来', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    await db.customStatement(
      "UPDATE dictionary_history SET result_json = '{not json' "
      'WHERE position = 0',
    );
    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    repo.startDeferredHistoryLoad();
    await repo.dictionaryHistoryLoaded;

    expect(repo.dictionaryHistory.single.searchTerm, '犬');
  });

  test('BUG-5064：entries 存成对象的行还原进内存，并按规范格式重写回库', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    final DictionaryHistoryRow row = (await db.getAllDictionaryHistory()).first;
    final Map<String, dynamic> map =
        jsonDecode(row.resultJson) as Map<String, dynamic>;
    map['entries'] = <Object?>[
      for (final Object? e in map['entries'] as List<Object?>)
        jsonDecode(e! as String),
    ];
    await db.customStatement(
      'UPDATE dictionary_history SET result_json = ? WHERE id = ?',
      <Object>[jsonEncode(map), row.id],
    );

    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);
    await repo.loadFromDb();

    expect(
      <String>[for (final r in repo.dictionaryHistory) r.searchTerm],
      <String>['猫', '犬'],
    );
    expect(repo.dictionaryHistory.first.entries.single.meaning, 'meaning of 猫');

    // 没查新词，只是退出前的 flush：坏格式那行也已经按规范格式重写（行 id 不变）。
    await repo.flushDictionaryHistoryNow();
    final List<DictionaryHistoryRow> after = await db.getAllDictionaryHistory();
    expect(<int>[for (final r in after) r.id], contains(row.id));
    for (final DictionaryHistoryRow r in after) {
      final Map<String, dynamic> m =
          jsonDecode(r.resultJson) as Map<String, dynamic>;
      expect(DictionarySearchResult.hasCanonicalEntries(m), isTrue);
    }
  });

  test('BUG-5064：读不回来的行装载后即从库里清掉，不再每次启动重报', () async {
    await _seedHistory(db, <String>['猫', '犬']);
    await db.customStatement(
      'UPDATE dictionary_history SET result_json = ? WHERE position = 0',
      <Object>[
        jsonEncode(<String, Object?>{
          'searchTerm': '猫',
          'entries': <Object?>[42],
        }),
      ],
    );
    await db.customStatement(
      'INSERT INTO dictionary_history (position, result_json) VALUES (?, ?)',
      <Object>[2, '{not json'],
    );

    final DictionaryRepository repo = DictionaryRepository(db);
    addTearDown(repo.dispose);
    await repo.loadFromDb();
    expect(repo.dictionaryHistory.single.searchTerm, '犬');

    // 用户什么都没做，只有退出前的 flush：坏行已经不在库里了。
    await repo.flushDictionaryHistoryNow();
    final List<DictionaryHistoryRow> after = await db.getAllDictionaryHistory();
    expect(after, hasLength(1));
    final List<DecodedDictionaryHistoryResult> decoded =
        await decodeDictionaryHistoryResults(<String>[
          for (final DictionaryHistoryRow r in after) r.resultJson,
        ]);
    expect(decoded.single.error, isNull);
    expect(decoded.single.result?.searchTerm, '犬');
  });

  test('没有历史：不起 isolate 也照常落定并回调', () async {
    int loadedCalls = 0;
    final DictionaryRepository repo = DictionaryRepository(
      db,
      onHistoryLoaded: () => loadedCalls++,
    );
    addTearDown(repo.dispose);

    await repo.loadFromDb(deferHistory: true);
    repo.startDeferredHistoryLoad();
    // 放行是一次性的：重复调用是空操作。
    repo.startDeferredHistoryLoad();
    await repo.dictionaryHistoryLoaded;

    expect(repo.dictionaryHistory, isEmpty);
    expect(repo.dictionaryHistoryLoading, isFalse);
    expect(loadedCalls, 1);
  });

  test('decodeDictionaryHistoryResults：逐条对位，坏行带错误文本', () async {
    final List<DecodedDictionaryHistoryResult> decoded =
        await decodeDictionaryHistoryResults(<String>[
          _result('猫', scrollPosition: 3).toJson(),
          '{not json',
          _result('犬').toJson(),
        ]);

    expect(decoded, hasLength(3));
    expect(decoded[0].result?.searchTerm, '猫');
    expect(decoded[0].result?.scrollPosition, 3);
    expect(decoded[0].error, isNull);
    expect(decoded[0].canonical, isTrue);
    expect(decoded[1].result, isNull);
    expect(decoded[1].error, isNotEmpty);
    expect(decoded[2].result?.searchTerm, '犬');
  });
}
