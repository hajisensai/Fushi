// 查词热路径从 DictionaryRepository 取的三样东西的契约：
//
// 1. lookupFilters（被关掉的词典名 + term 词典顺序）：以前每次查词都经
//    `dictionaries` / `termDictionaries` 把全部词典深拷贝两三遍只为取名字，现在缓存
//    一份快照——前提是**每一个**改动词典列表的入口都让它失效，否则查词拿旧的隐藏
//    名单 / 旧顺序。这里逐个入口钉住。
// 2. resultsCacheEpoch：查词是异步的（后台 isolate），在飞期间清了缓存，回来时不得
//    把旧结果写回去——调用方据这个代次判断。
// 3. 查词历史落库：单条 toJson() 在真实词典上 0.26-1.5 MB / p50 28 ms，序列化挪到
//    后台 isolate（encodeDictionaryHistoryResults）。异步之后多出来的窗口：后台
//    序列化期间清历史，回来时那份旧快照不得写回（复活已清历史）。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

Dictionary _dict(
  String name, {
  int order = 0,
  DictionaryType type = DictionaryType.term,
  List<String> hiddenLanguages = const <String>[],
  String? sourceLanguage,
}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: type,
  metadata: <String, String>{
    if (sourceLanguage != null) 'sourceLanguage': sourceLanguage,
  },
  hiddenLanguages: hiddenLanguages,
  collapsedLanguages: const <String>[],
);

DictionarySearchResult _result(String term) => DictionarySearchResult(
  searchTerm: term,
  entries: <DictionaryEntry>[DictionaryEntry(word: term, meaning: 'm')],
);

void main() {
  late FushiDatabase db;
  late DictionaryRepository repo;
  final String ja = JapaneseLanguage.instance.languageCode;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = DictionaryRepository(db);
    await repo.loadFromDb();
  });

  tearDown(() async {
    repo.dispose();
    await db.close();
  });

  group('lookupFilters', () {
    test('派生值与旧的深拷贝表达式一致', () async {
      await repo.persistDictionaries(<Dictionary>[
        _dict('A'),
        _dict('Freq', order: 1, type: DictionaryType.frequency),
        _dict('B', order: 2, hiddenLanguages: <String>[ja]),
        _dict('C', order: 3),
      ]);
      final DictionaryLookupFilters filters = repo.lookupFilters;
      expect(
        filters.hiddenDictionaryNames,
        repo.dictionaries
            .where((Dictionary d) => d.isHidden(JapaneseLanguage.instance))
            .map((Dictionary d) => d.name)
            .toSet(),
      );
      expect(
        filters.termDictionaryOrder,
        repo.termDictionaries.map((Dictionary d) => d.name).toList(),
      );
      expect(filters.termDictionaryOrder, <String>['A', 'B', 'C']);
      expect(
        identical(repo.lookupFilters, filters),
        isTrue,
        reason: '没有变化时复用同一份快照，不再每次查词重算',
      );
    });

    test('显示 / 隐藏开关后失效', () async {
      final Dictionary a = _dict('A');
      await repo.persistDictionary(a);
      expect(repo.lookupFilters.hiddenDictionaryNames, isEmpty);
      await repo.setDictionaryHidden(a, ja, true);
      expect(repo.lookupFilters.hiddenDictionaryNames, <String>{'A'});
      await repo.toggleDictionaryHidden(a, ja);
      expect(repo.lookupFilters.hiddenDictionaryNames, isEmpty);
    });

    test('重排 / 删除 / 清空 / 移出缓存 / 重新加载后失效', () async {
      await repo.persistDictionaries(<Dictionary>[
        _dict('A'),
        _dict('B', order: 1),
        _dict('C', order: 2),
      ]);
      expect(repo.lookupFilters.termDictionaryOrder, <String>['A', 'B', 'C']);

      await repo.updateDictionaryOrder(<Dictionary>[
        _dict('C'),
        _dict('A', order: 1),
        _dict('B', order: 2),
      ]);
      expect(repo.lookupFilters.termDictionaryOrder, <String>['C', 'A', 'B']);

      await repo.deleteDictionaryMeta('A');
      expect(repo.lookupFilters.termDictionaryOrder, <String>['C', 'B']);

      repo.removeDictionaryFromCache('C');
      expect(repo.lookupFilters.termDictionaryOrder, <String>['B']);

      await repo.loadFromDb();
      expect(repo.lookupFilters.termDictionaryOrder, <String>['C', 'B']);

      repo.clearDictionariesCache();
      expect(repo.lookupFilters.termDictionaryOrder, isEmpty);

      await repo.loadFromDb();
      await repo.clearDictionaryMetadata();
      expect(repo.lookupFilters.termDictionaryOrder, isEmpty);
    });
  });

  group('lookupFilters.hasChineseTermDictionary（反馈 3FY6vTqwV-）', () {
    test('只认启用中、声明为中文的 term 词典', () async {
      await repo.persistDictionaries(<Dictionary>[
        _dict('JMdict', sourceLanguage: 'ja'),
        _dict('Unlabelled', order: 1),
        _dict(
          'ZhFreq',
          order: 2,
          type: DictionaryType.frequency,
          sourceLanguage: 'zh',
        ),
      ]);
      expect(
        repo.lookupFilters.hasChineseTermDictionary,
        isFalse,
        reason: '日语 / 未标注 term 词典、中文频率词典都不算',
      );

      await repo.persistDictionary(
        _dict('ABC', order: 3, sourceLanguage: 'zh-Hans'),
      );
      expect(repo.lookupFilters.hasChineseTermDictionary, isTrue);
    });

    test('被关掉的中文词典不算；开回来又算', () async {
      final Dictionary drEye = _dict('DrEye', sourceLanguage: 'zh-Hant');
      await repo.persistDictionary(drEye);
      expect(repo.lookupFilters.hasChineseTermDictionary, isTrue);
      await repo.setDictionaryHidden(drEye, ja, true);
      expect(repo.lookupFilters.hasChineseTermDictionary, isFalse);
      await repo.setDictionaryHidden(drEye, ja, false);
      expect(repo.lookupFilters.hasChineseTermDictionary, isTrue);
    });

    test('手动指定语言优先于包内声明，改语言后快照失效', () async {
      final Dictionary dict = _dict('Cedict');
      await repo.persistDictionary(dict);
      expect(repo.lookupFilters.hasChineseTermDictionary, isFalse);
      await repo.setDictionaryLanguageOverride(dict, 'zh');
      expect(repo.lookupFilters.hasChineseTermDictionary, isTrue);
      await repo.setDictionaryLanguageOverride(dict, null);
      expect(repo.lookupFilters.hasChineseTermDictionary, isFalse);
    });
  });

  group('resultsCacheEpoch', () {
    test('每次清查词缓存都推进；只读不推进', () async {
      final int start = repo.resultsCacheEpoch;
      repo.cacheSearchResult('k', _result('k'));
      expect(repo.getCachedSearch('k'), isNotNull);
      expect(repo.resultsCacheEpoch, start);
      repo.clearDictionaryResultsCache();
      expect(repo.resultsCacheEpoch, start + 1);
      await repo.persistDictionary(_dict('A'));
      expect(
        repo.resultsCacheEpoch,
        greaterThan(start + 1),
        reason: '写词典元数据 = 引擎集合变了，必须作废在飞的查询结果',
      );
    });
  });

  group('history flush（后台序列化）', () {
    test('落库内容与 UI isolate 上的 toJson() 逐字相同', () async {
      final DictionarySearchResult a = _result('猫');
      final DictionarySearchResult b = _result('犬')..scrollPosition = 4;
      repo.addHistoryResult(a, 10);
      repo.addHistoryResult(b, 10);
      await repo.flushDictionaryHistoryNow();
      final List<DictionaryHistoryRow> rows = await db
          .getAllDictionaryHistory();
      expect(
        rows.map((DictionaryHistoryRow r) => r.resultJson).toList(),
        <String>[a.toJson(), b.toJson()],
      );
    });

    test('后台序列化期间清历史：旧快照不写回', () async {
      repo.addHistoryResult(_result('猫'), 10);
      final Future<void> flushing = repo.flushDictionaryHistoryNow();
      // 序列化在后台 isolate，此刻必然还没回来。
      await repo.clearDictionaryHistory();
      await flushing;
      await repo.flushPendingWritesNow();
      expect(await db.getAllDictionaryHistory(), isEmpty);
      expect(repo.dictionaryHistory, isEmpty);
    });

    test('后台序列化期间 dispose：旧快照不写回', () async {
      final DictionaryRepository other = DictionaryRepository(db);
      await other.loadFromDb();
      other.addHistoryResult(_result('猫'), 10);
      final Future<void> flushing = other.flushDictionaryHistoryNow();
      other.dispose();
      await flushing;
      expect(await db.getAllDictionaryHistory(), isEmpty);
    });

    test('序列化期间被就地改过（scrollPosition）：再 flush 写入新值', () async {
      final DictionarySearchResult r = _result('猫');
      repo.addHistoryResult(r, 10);
      final Future<void> flushing = repo.flushDictionaryHistoryNow();
      repo.updateDictionaryResultScrollIndex(result: r, newIndex: 7);
      await flushing;
      await repo.flushPendingWritesNow();
      final List<DictionaryHistoryRow> rows = await db
          .getAllDictionaryHistory();
      expect(rows.single.resultJson, r.toJson());
      expect(
        DictionarySearchResult.fromJson(rows.single.resultJson).scrollPosition,
        7,
      );
    });
  });
}
