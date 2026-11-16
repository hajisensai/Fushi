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

    test('导入管理器的落库位置委托给仓库（placementForImport）', () {
      final String src = File(
        'lib/src/models/dictionary_import_manager.dart',
      ).readAsStringSync();
      expect(
        src.contains('_dictRepo.placementForImport(name, preservedSettings:'),
        isTrue,
      );
      expect(src.contains('nextDictionaryOrder'), isFalse);
    });

    test('导入同名本机副本：接替服务器行的位置与开关，而不是排到最后', () async {
      // R 在 B 与 C 之间（order 2）。导入一本同名的本机 R：仍排在 B 与 C 之间。
      final ({int order, List<String> hiddenLanguages}) placement = repo
          .placementForImport('R');
      expect(placement.order, 2);
      expect(placement.hiddenLanguages, isEmpty);
      await repo.persistDictionary(
        _local(
          'R',
          placement.order,
          hidden: placement.hiddenLanguages.isNotEmpty,
        ),
      );
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'A',
        'B',
        'R',
        'C',
        'D',
      ]);
      expect(repo.lookupFilters.hiddenDictionaryNames, isEmpty);
    });

    test('导入同名本机副本：服务器行关着 ⇒ 本机副本也关着', () async {
      await db.setRemoteDictionaryProfileColumns(
        hostId: 'h1',
        name: 'R',
        order: 2,
        hidden: true,
      );
      await repo.reloadRemoteDictionaries();
      final ({int order, List<String> hiddenLanguages}) placement = repo
          .placementForImport('R');
      expect(placement.order, 2);
      expect(placement.hiddenLanguages, <String>['ja']);
    });

    test('导入：替换旧本继承旧本；没有同名服务器行排最后', () {
      final Dictionary old = _local('B', 1, hidden: true);
      final ({int order, List<String> hiddenLanguages}) replaced = repo
          .placementForImport('R', preservedSettings: old);
      expect(replaced.order, 1);
      expect(replaced.hiddenLanguages, <String>['ja']);
      final ({int order, List<String> hiddenLanguages}) fresh = repo
          .placementForImport('E');
      expect(fresh.order, repo.nextDictionaryOrder);
      expect(fresh.hiddenLanguages, isEmpty);
    });

    test('「下载到本机」：包里 host 的顺序 / 开关被改写成目录行的', () async {
      await db.setRemoteDictionaryProfileColumns(
        hostId: 'h1',
        name: 'R',
        order: 2,
        hidden: true,
      );
      // 同步包导入照搬 host 自己的值：order 40、开关开着、还带一个别的语言隐藏位。
      await db.upsertDictionaryMeta(
        DictionaryMetadataCompanion.insert(
          name: 'R',
          formatKey: 'yomichan',
          order: 40,
          hiddenLanguagesJson: const Value<String>('["en"]'),
          collapsedLanguagesJson: const Value<String>('["ja"]'),
        ),
      );
      expect(
        await DictionaryRepository.adoptCatalogPlacement(
          db,
          hostId: 'h1',
          name: 'R',
        ),
        isTrue,
      );
      final DictionaryMetaRow row = (await db.getAllDictionaryMetadata())
          .firstWhere((DictionaryMetaRow r) => r.name == 'R');
      expect(row.order, 2);
      expect(row.hiddenLanguagesJson, '["en","ja"]');
      expect(row.collapsedLanguagesJson, '["ja"]', reason: '折叠照原样写回');
      // 没有目录行的 host：不动。
      expect(
        await DictionaryRepository.adoptCatalogPlacement(
          db,
          hostId: 'h9',
          name: 'R',
        ),
        isFalse,
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

  group('删本机词典：同名目录行（各 host）忘掉缺席的、接手还在的', () {
    late FushiDatabase db;
    late DictionaryRepository repo;

    Future<Set<String>> catalogKeys() async => <String>{
      for (final RemoteDictionaryMetaRow r
          in await db.getAllRemoteDictionaryMetadata())
        '${r.hostId}/${r.name}',
    };

    Future<Map<String, String>> catalogPlacement() async => <String, String>{
      for (final RemoteDictionaryMetaRow r
          in await db.getAllRemoteDictionaryMetadata())
        '${r.hostId}/${r.name}': 'order=${r.order} hidden=${r.hidden}',
    };

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = DictionaryRepository(db);
      // X：h1 上已消失、h2 上还在；h3 没开「用于查词」、也已消失；h4 没开「用于
      // 查词」、还在。Y：h1 上已消失。
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h1', 'X', 1));
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h2', 'X', 2));
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h3', 'X', 3));
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h4', 'X', 6));
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h1', 'Y', 4));
      await db.markRemoteDictionariesMissing('h1', <String>['X', 'Y'], 5);
      await db.markRemoteDictionariesMissing('h3', <String>['X'], 5);
      await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://h1:1', hostId: 'h1'),
        FushiClientUrl(url: 'http://h2:1', hostId: 'h2'),
      ]);
      await repo.loadFromDb();
      await repo.persistDictionary(_local('X', 0));
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    Future<void> deleteX() async {
      final ({String name, int order, bool hidden}) handover =
          DictionaryRepository.catalogHandoverOf(
            repo.dictionaries.firstWhere((Dictionary d) => d.name == 'X'),
          );
      await repo.deleteDictionaryMeta('X');
      await repo.releaseCatalogRowsOf(<({String name, int order, bool hidden})>[
        handover,
      ]);
    }

    test('只忘掉同名且已缺席的行（各 host，含不查词的）；还在的行留着', () async {
      await deleteX();
      expect(await catalogKeys(), <String>{'h2/X', 'h4/X', 'h1/Y'});
      // 删完 X 只在 h2 上：管理页是一条服务器行，没有「服务器上已没有」的残行。
      expect(
        repo.remoteDictionaries
            .where((RemoteDictionary r) => r.name == 'X')
            .map((RemoteDictionary r) => '${r.key} missing=${r.isMissing}'),
        <String>['h2/X missing=false'],
      );
    });

    // 审查发现：遮住期间服务器行不参与重编号，序号过时；拖过「两者」行再删本机那份，
    // 服务器行带着旧序号冒出来并与别的行撞号。
    test('还在的同名行（含不查词的 host）接手本机行的位置与开关', () async {
      // 本机 X 被拖到第 8 位、关掉——遮住的服务器行仍是 2 / 6、开着。
      await repo.persistDictionaries(<Dictionary>[
        _local('A', 7),
        _local('X', 8, hidden: true),
        _local('B', 9),
      ]);
      await deleteX();
      final Map<String, String> placement = await catalogPlacement();
      expect(placement['h2/X'], 'order=8 hidden=true');
      expect(placement['h4/X'], 'order=8 hidden=true', reason: '不查词的 host 也接手');
      expect(placement['h1/Y'], 'order=4 hidden=false', reason: '别的名字不动');
      final RemoteDictionary x = repo.remoteDictionaries.singleWhere(
        (RemoteDictionary r) => r.name == 'X',
      );
      expect((x.order, x.hidden), (8, true));
      final List<String> order = repo.lookupFilters.termDictionaryOrder;
      expect(
        <int>[order.indexOf('A'), order.indexOf('X'), order.indexOf('B')],
        orderedEquals(<int>[
          order.indexOf('A'),
          order.indexOf('A') + 1,
          order.indexOf('A') + 2,
        ]),
        reason: '服务器行在原位（A 与 B 之间）接手，查词顺序不变：$order',
      );
      expect(repo.lookupFilters.hiddenDictionaryNames, contains('X'));
    });

    test('「两者」行开关镜像写到各 host 的同名行（含不查词的）', () async {
      await repo.setCatalogRowsHiddenNamed('X', true);
      final Map<String, String> placement = await catalogPlacement();
      expect(placement['h2/X'], 'order=2 hidden=true');
      expect(placement['h4/X'], 'order=6 hidden=true');
      expect(placement['h1/Y'], 'order=4 hidden=false');
    });

    test('AppModel 的删除入口（单本 / 全部）都接上这一步', () {
      final String src = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      String body(String signature) {
        final int start = src.indexOf(signature);
        expect(start, greaterThanOrEqualTo(0), reason: signature);
        return src.substring(start, src.indexOf('\n  }\n', start));
      }

      final String single = body('Future<void> deleteDictionary(Dictionary');
      expect(
        single.indexOf('catalogHandoverOf('),
        lessThan(single.indexOf('dictRepo.deleteDictionaryMeta(')),
        reason: '本机行的位置与开关要在删行之前取',
      );
      expect(
        single.indexOf('releaseCatalogRowsOf('),
        greaterThan(single.indexOf('dictRepo.deleteDictionaryMeta(')),
      );
      final String all = body('Future<void> deleteDictionaries() async {');
      expect(
        all.indexOf('catalogHandoverOf('),
        lessThan(all.indexOf('dictRepo.clearDictionaryMetadata()')),
      );
      expect(all, contains('dictRepo.releaseCatalogRowsOf(released)'));
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
