// 本机词典与服务器托管词典共用一条 `order` 数轴：所有改分区顺序的写入（改语言换组、
// AppModel / ctl 重排、导入取下一个序号）都要连同服务器词典一起重编号，否则服务器
// 词典在查词序里漂移。复现场景：混排 A0 B1 R2(服务器) C3 D4，只给本机重编号后 R 从
// C 之前跑到 D 之后。另含 App 当 host 时纯汉字词典的排除集（BUG-3573）。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/ops/ctl_dictionary_json.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteLookupDictionaryConfig;

Dictionary _local(
  String name,
  int order, {
  DictionaryType type = DictionaryType.term,
  String? language = 'ja',
  bool hidden = false,
}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: type,
  languageOverride: language,
  metadata: const <String, String>{},
  hiddenLanguages: hidden ? const <String>['ja'] : const <String>[],
  collapsedLanguages: const <String>[],
);

RemoteDictionaryMetadataCompanion _catalogRow(
  String host,
  String name,
  int order, {
  String type = 'term',
  String? language = 'ja',
}) => RemoteDictionaryMetadataCompanion(
  hostId: Value<String>(host),
  name: Value<String>(name),
  type: Value<String>(type),
  sourceLanguage: Value<String?>(language),
  lastSeenAt: const Value<int>(1),
  order: Value<int>(order),
  hidden: const Value<bool>(false),
);

void main() {
  group('混排数轴：服务器词典不随本机重编号漂移', () {
    late FushiDatabase db;
    late DictionaryRepository repo;

    Dictionary named(String name) =>
        repo.dictionaries.firstWhere((Dictionary d) => d.name == name);

    Future<Map<String, int>> dbOrders() async => <String, int>{
      for (final DictionaryMetaRow r in await db.getAllDictionaryMetadata())
        r.name: r.order,
      for (final RemoteDictionaryMetaRow r
          in await db.getAllRemoteDictionaryMetadata())
        r.name: r.order,
    };

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = DictionaryRepository(db);
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h1', 'R', 2));
      await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://h1:1', hostId: 'h1'),
      ]);
      await repo.loadFromDb();
      await repo.persistDictionaries(<Dictionary>[
        _local('A', 0),
        _local('B', 1),
        _local('C', 3),
        _local('D', 4),
      ]);
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'A',
        'B',
        'R',
        'C',
        'D',
      ]);
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('改语言换组：A 去新组最后，R 仍在 B 与 C 之间（两表同一数轴重编号）', () async {
      await repo.setDictionaryLanguageOverride(named('A'), 'en');
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'B',
        'R',
        'C',
        'D',
        'A',
      ]);
      expect(await dbOrders(), <String, int>{
        'B': 0,
        'R': 1,
        'C': 2,
        'D': 3,
        'A': 4,
      });
      expect(repo.remoteDictionaries.single.order, 1);
      expect(repo.filtersForHost('h1')!.order, <String>[
        'B',
        'R',
        'C',
        'D',
        'A',
      ]);
    });

    test('改语言换组：紧挨在被改那本前面的服务器词典不被它带走', () async {
      // R 原本在 A 正前方（R0 A1 B2 …）：A 改语言后 R 仍在 B 之前。
      await repo.updateDictionaryOrder(
        <Dictionary>[
          named('A').copyWith(order: 1),
          named('B').copyWith(order: 2),
          named('C').copyWith(order: 3),
          named('D').copyWith(order: 4),
        ],
        remoteDictionaries: <RemoteDictionary>[
          repo.remoteDictionaries.single.copyWith(order: 0),
        ],
      );
      expect(repo.lookupFilters.termDictionaryOrder.take(3), <String>[
        'R',
        'A',
        'B',
      ]);
      await repo.setDictionaryLanguageOverride(named('A'), 'en');
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'R',
        'B',
        'C',
        'D',
        'A',
      ]);
    });

    test('ctl position：A 挪到组尾，R 守在 C 之前', () async {
      final List<Dictionary> reordered = ctlReorderDictionaries(
        repo.termDictionaries,
        named('A'),
        4,
      );
      // ctl 路由同一调用（AppModel.updateDictionaryOrder → 仓库分区重编号）。
      await repo.reorderDictionarySection(reordered, moved: 'A');
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'B',
        'R',
        'C',
        'D',
        'A',
      ]);
      expect((await dbOrders())['R'], 1);
    });

    test('ctl position：相邻上移只挪那一本，R 留在原处（C 与 B 对调）', () async {
      final List<Dictionary> reordered = ctlReorderDictionaries(
        repo.termDictionaries,
        named('C'),
        2,
      );
      await repo.reorderDictionarySection(reordered, moved: 'C');
      // C 落在新顺序里它的前一本（A）正后方；R 原本守在 C 之前，C 挪走后守在下一本
      // 没动的本机词典（D）之前。
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'A',
        'C',
        'B',
        'R',
        'D',
      ]);
    });

    test('ctl position 不变（只规范化）：什么都不挪', () async {
      final Map<String, int> before = await dbOrders();
      final List<Dictionary> reordered = ctlReorderDictionaries(
        repo.termDictionaries,
        named('C'),
        3,
      );
      await repo.reorderDictionarySection(reordered, moved: 'C');
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'A',
        'B',
        'R',
        'C',
        'D',
      ]);
      // 只是把序号压成 0..n-1，相对位置一个不变。
      expect(await dbOrders(), <String, int>{
        'A': 0,
        'B': 1,
        'R': 2,
        'C': 3,
        'D': 4,
      });
      expect(before['R'], 2);
    });

    test('AppModel.updateDictionaryOrder 同一入口：整段新顺序，服务器词典守在原邻居前', () async {
      await repo.reorderDictionarySection(<Dictionary>[
        named('B'),
        named('A'),
        named('C'),
        named('D'),
      ]);
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'B',
        'A',
        'R',
        'C',
        'D',
      ]);
    });

    test('分区重编号只取真名与先后，其它字段以缓存为准（旧快照不覆盖开关）', () async {
      final Dictionary staleA = named('A');
      await repo.toggleDictionaryHidden(named('A'), 'ja');
      expect(named('A').isHidden(JapaneseLanguage.instance), isTrue);
      await repo.reorderDictionarySection(<Dictionary>[
        named('B'),
        staleA,
        named('C'),
        named('D'),
      ]);
      expect(named('A').isHidden(JapaneseLanguage.instance), isTrue);
      expect(named('A').order, 1);
    });

    test('分区重编号拒收混了类型的列表', () {
      expect(
        () => repo.reorderDictionarySection(<Dictionary>[
          named('A'),
          _local('F', 9, type: DictionaryType.frequency),
        ]),
        throwsArgumentError,
      );
    });

    test('导入取下一个序号：两表最大值 + 1，新词典排在服务器词典之后', () async {
      expect(repo.nextDictionaryOrder, 5);
      await repo.updateDictionaryOrder(
        const <Dictionary>[],
        remoteDictionaries: <RemoteDictionary>[
          repo.remoteDictionaries.single.copyWith(order: 10),
        ],
      );
      expect(repo.nextDictionaryOrder, 11);
      // DictionaryImportManager._nextOrder 就是 nextDictionaryOrder。
      await repo.persistDictionary(_local('E', repo.nextDictionaryOrder));
      expect(repo.lookupFilters.termDictionaryOrder.skip(4), <String>[
        'R',
        'E',
      ]);
    });

    test('导入管理器的 _nextOrder 委托给仓库（两表最大值）', () {
      final String src = File(
        'lib/src/models/dictionary_import_manager.dart',
      ).readAsStringSync();
      expect(
        src.contains('int _nextOrder() => _dictRepo.nextDictionaryOrder;'),
        isTrue,
      );
    });

    test('「汉字」分区重排不动术语查词序（汉字分区不混服务器词典）', () async {
      await repo.persistDictionaries(<Dictionary>[
        _local('K1', 0, type: DictionaryType.kanji),
        _local('K2', 1, type: DictionaryType.kanji),
      ]);
      final List<String> termBefore = repo.lookupFilters.termDictionaryOrder;
      await repo.updateKanjiSectionOrder(<Dictionary>[
        named('K2'),
        named('K1'),
      ]);
      expect(repo.lookupFilters.termDictionaryOrder, termBefore);
      expect(repo.remoteDictionaries.single.order, 2);
      expect(
        repo.kanjiSectionDictionaries.map((Dictionary d) => d.name),
        <String>['K2', 'K1'],
      );
    });
  });

  group('纯汉字词典的排除集（App 当 host，BUG-3573）', () {
    test('lookupFiltersOf 收集纯汉字型词典；App 自己查词时汉字排除集为空', () {
      final DictionaryLookupFilters filters =
          DictionaryRepository.lookupFiltersOf(<Dictionary>[
            _local('JMdict', 0),
            _local('KANJIDIC', 1, type: DictionaryType.kanji, hidden: true),
            _local('Mixed', 2, hidden: true),
          ]);
      expect(filters.kanjiDictionaryNames, <String>{'KANJIDIC'});
      expect(filters.hiddenKanjiDictionaryNames, isEmpty);
    });

    test('forRequesterConfig：汉字排除集 = 请求方排除名单 ∩ 本机纯汉字词典', () {
      final DictionaryLookupFilters local =
          DictionaryRepository.lookupFiltersOf(<Dictionary>[
            _local('JMdict', 0),
            _local('Mixed', 1),
            _local('KANJIDIC', 2, type: DictionaryType.kanji),
          ]);
      final DictionaryLookupFilters out = local.forRequesterConfig(
        const RemoteLookupDictionaryConfig(
          excluded: <String>{'Mixed', 'KANJIDIC', 'Elsewhere'},
          order: <String>[],
        ),
      );
      // 混合词典只进术语排除（它的汉字部分有自己的开关），不进汉字排除集。
      expect(out.hiddenDictionaryNames, <String>{
        'Mixed',
        'KANJIDIC',
        'Elsewhere',
      });
      expect(out.hiddenKanjiDictionaryNames, <String>{'KANJIDIC'});
      expect(out.kanjiDictionaryNames, <String>{'KANJIDIC'});
    });

    test('fingerprint 带上汉字排除集', () {
      const DictionaryLookupFilters a = DictionaryLookupFilters(
        hiddenDictionaryNames: <String>{'X'},
        termDictionaryOrder: <String>['A'],
      );
      const DictionaryLookupFilters b = DictionaryLookupFilters(
        hiddenDictionaryNames: <String>{'X'},
        termDictionaryOrder: <String>['A'],
        hiddenKanjiDictionaryNames: <String>{'X'},
      );
      expect(a.fingerprint, isNot(b.fingerprint));
    });

    test('App 查词把汉字排除集交给后台查词请求', () {
      final String src = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      expect(
        src.contains(
          'hiddenKanjiDictionaries: filters.hiddenKanjiDictionaryNames,',
        ),
        isTrue,
      );
    });
  });
}
