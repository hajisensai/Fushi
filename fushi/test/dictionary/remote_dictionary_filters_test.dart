// 服务器托管词典（v149 remote_dictionary_metadata）进入查词过滤：与本机词典按 order
// 混排、同名时本机遮住服务器那本、按 host 算出随远端查词请求发出的 `dictionaries` 选择、
// 管理页一次混排重编号在同一个事务里写两张表。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show RemoteLookupDictionaryConfig;

Dictionary _local(
  String name,
  int order, {
  DictionaryType type = DictionaryType.term,
  bool hidden = false,
}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: type,
  metadata: const <String, String>{},
  hiddenLanguages: hidden ? const <String>['ja'] : const <String>[],
  collapsedLanguages: const <String>[],
);

RemoteDictionary _remote(
  String host,
  String name,
  int order, {
  DictionaryType type = DictionaryType.term,
  bool hidden = false,
}) => RemoteDictionary(
  hostId: host,
  name: name,
  type: type,
  order: order,
  hidden: hidden,
  lastSeenAt: 1,
);

RemoteDictionaryMetadataCompanion _catalogRow(
  String host,
  String name,
  int order, {
  bool hidden = false,
}) => RemoteDictionaryMetadataCompanion(
  hostId: Value<String>(host),
  name: Value<String>(name),
  type: const Value<String>('term'),
  lastSeenAt: const Value<int>(1),
  order: Value<int>(order),
  hidden: Value<bool>(hidden),
);

void main() {
  group('lookupFiltersOf（本机 + 服务器混排）', () {
    test('term 顺序按 order 混排，关掉的服务器词典进隐藏名单', () {
      final DictionaryLookupFilters filters =
          DictionaryRepository.lookupFiltersOf(
            <Dictionary>[_local('JMdict', 0), _local('Local2', 2)],
            <RemoteDictionary>[
              _remote('h1', 'Daijirin', 1),
              _remote('h1', 'Hidden', 3, hidden: true),
              _remote('h1', 'Freq', 4, type: DictionaryType.frequency),
            ],
          );
      expect(filters.termDictionaryOrder, <String>[
        'JMdict',
        'Daijirin',
        'Local2',
        'Hidden',
      ]);
      expect(filters.hiddenDictionaryNames, <String>{'Hidden'});
    });

    test('同名时本机那本遮住服务器那本：服务器行的顺序 / 开关不作数', () {
      final DictionaryLookupFilters filters =
          DictionaryRepository.lookupFiltersOf(
            <Dictionary>[_local('JMdict', 5)],
            <RemoteDictionary>[_remote('h1', 'JMdict', 0, hidden: true)],
          );
      expect(filters.termDictionaryOrder, <String>['JMdict']);
      expect(filters.hiddenDictionaryNames, isEmpty);
    });

    test('不传服务器词典时与升级前逐字相同', () {
      final List<Dictionary> local = <Dictionary>[
        _local('A', 0),
        _local('B', 1, hidden: true),
      ];
      final DictionaryLookupFilters filters =
          DictionaryRepository.lookupFiltersOf(local);
      expect(filters.termDictionaryOrder, <String>['A', 'B']);
      expect(filters.hiddenDictionaryNames, <String>{'B'});
    });

    test('指纹随服务器词典的顺序 / 开关变化', () {
      final List<Dictionary> local = <Dictionary>[_local('A', 0)];
      final String base = DictionaryRepository.lookupFiltersOf(
        local,
        <RemoteDictionary>[_remote('h1', 'S', 1)],
      ).fingerprint;
      final String hidden = DictionaryRepository.lookupFiltersOf(
        local,
        <RemoteDictionary>[_remote('h1', 'S', 1, hidden: true)],
      ).fingerprint;
      final String moved = DictionaryRepository.lookupFiltersOf(
        local,
        <RemoteDictionary>[_remote('h1', 'S', -1)],
      ).fingerprint;
      expect(<String>{base, hidden, moved}, hasLength(3));
    });
  });

  group('remoteLookupConfigFor（每台 host 的词典选择）', () {
    test('本机词典 + 该 host 的服务器词典；别的 host 的行不进来', () {
      final RemoteLookupDictionaryConfig config =
          DictionaryRepository.remoteLookupConfigFor(
            dictionaries: <Dictionary>[
              _local('JMdict', 0),
              _local('Off', 3, hidden: true),
            ],
            remoteDictionaries: <RemoteDictionary>[
              _remote('h1', 'Daijirin', 1),
              _remote('h1', 'Meikyo', 2, hidden: true),
              _remote('h2', 'Other', 0, hidden: true),
            ],
            hostId: 'h1',
          )!;
      expect(config.order, <String>['JMdict', 'Daijirin', 'Meikyo', 'Off']);
      expect(config.excluded, <String>{'Off', 'Meikyo'});
    });

    test('同名时本机那本说了算', () {
      final RemoteLookupDictionaryConfig config =
          DictionaryRepository.remoteLookupConfigFor(
            dictionaries: <Dictionary>[_local('JMdict', 0, hidden: true)],
            remoteDictionaries: <RemoteDictionary>[_remote('h1', 'JMdict', 0)],
            hostId: 'h1',
          )!;
      expect(config.excluded, <String>{'JMdict'});
      expect(config.order, <String>['JMdict']);
    });

    test('一无所知（没有本机词典、没有该 host 的目录）时不发选择', () {
      expect(
        DictionaryRepository.remoteLookupConfigFor(
          dictionaries: const <Dictionary>[],
          remoteDictionaries: <RemoteDictionary>[_remote('h2', 'X', 0)],
          hostId: 'h1',
        ),
        isNull,
      );
    });
  });

  group('forRequesterConfig（App 当 host 按请求方选择查）', () {
    test('排除只认请求方；请求方的顺序在前，本机其余 term 词典按本机顺序接后', () {
      const DictionaryLookupFilters local = DictionaryLookupFilters(
        hiddenDictionaryNames: <String>{'LocalOff'},
        termDictionaryOrder: <String>['A', 'B', 'C'],
      );
      final DictionaryLookupFilters out = local.forRequesterConfig(
        const RemoteLookupDictionaryConfig(
          excluded: <String>{'B'},
          order: <String>['C', 'Unknown', 'A'],
        ),
      );
      expect(out.termDictionaryOrder, <String>['C', 'A', 'B']);
      expect(out.hiddenDictionaryNames, <String>{'B'});
      expect(out.fingerprint, isNot(local.fingerprint));
    });
  });

  group('DictionaryRepository 装载与写入', () {
    late FushiDatabase db;
    late DictionaryRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = DictionaryRepository(db);
      await db.upsertDictionaryMeta(
        const DictionaryMetadataCompanion(
          name: Value<String>('JMdict'),
          formatKey: Value<String>('yomichan'),
          order: Value<int>(0),
          type: Value<String>('term'),
        ),
      );
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h1', 'Daijirin', 1));
      await db.upsertRemoteDictionaryCatalog(_catalogRow('h2', 'Meikyo', 2));
      await SyncRepository(db).setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://h1:1', hostId: 'h1'),
        FushiClientUrl(url: 'http://h2:1', hostId: 'h2', lookupEnabled: false),
      ]);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('只装载参与查词的 host（关掉「用它查词典」的 host 不进过滤）', () async {
      expect(
        repo.remoteDictionaries.map((RemoteDictionary r) => r.key),
        <String>['h1/Daijirin'],
      );
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'JMdict',
        'Daijirin',
      ]);
      expect(repo.filtersForHost('h1')!.order, <String>['JMdict', 'Daijirin']);
      expect(repo.filtersForHost('h2')!.order, <String>['JMdict']);

      await SyncRepository(db).updateFushiClientUrls(
        (List<FushiClientUrl> urls) => <FushiClientUrl>[
          for (final FushiClientUrl u in urls) u.copyWith(lookupEnabled: true),
        ],
      );
      await repo.reloadRemoteDictionaries();
      expect(
        repo.remoteDictionaries.map((RemoteDictionary r) => r.key),
        <String>['h1/Daijirin', 'h2/Meikyo'],
      );
    });

    test('混排重编号在一个事务里写两张表', () async {
      final RemoteDictionary daijirin = repo.remoteDictionaries.single;
      final Dictionary jmdict = repo.dictionaries.single;
      await repo.updateDictionaryOrder(
        <Dictionary>[jmdict.copyWith(order: 1)],
        remoteDictionaries: <RemoteDictionary>[daijirin.copyWith(order: 0)],
      );
      expect(repo.lookupFilters.termDictionaryOrder, <String>[
        'Daijirin',
        'JMdict',
      ]);
      expect((await db.getAllDictionaryMetadata()).single.order, 1);
      expect(
        (await db.getAllRemoteDictionaryMetadata())
            .firstWhere((RemoteDictionaryMetaRow r) => r.name == 'Daijirin')
            .order,
        0,
      );
    });

    test('服务器那本中途被忘掉：整个重编号回滚，本机词典的顺序也不落', () async {
      final RemoteDictionary daijirin = repo.remoteDictionaries.single;
      final Dictionary jmdict = repo.dictionaries.single;
      // 另一条路径（目录刷新 / 别的进程）直接删了目录行，缓存还以为它在。
      await db.deleteRemoteDictionary('h1', 'Daijirin');
      await expectLater(
        repo.updateDictionaryOrder(
          <Dictionary>[jmdict.copyWith(order: 5)],
          remoteDictionaries: <RemoteDictionary>[daijirin.copyWith(order: 0)],
        ),
        throwsStateError,
      );
      expect((await db.getAllDictionaryMetadata()).single.order, 0);
      expect(repo.dictionaries.single.order, 0);
    });

    test('开关服务器词典只写配置列，进隐藏名单', () async {
      await repo.setRemoteDictionaryHidden(
        repo.remoteDictionaries.single,
        true,
      );
      expect(repo.lookupFilters.hiddenDictionaryNames, <String>{'Daijirin'});
      expect(repo.filtersForHost('h1')!.excluded, <String>{'Daijirin'});
      final RemoteDictionaryMetaRow row =
          (await db.getAllRemoteDictionaryMetadata()).firstWhere(
            (RemoteDictionaryMetaRow r) => r.name == 'Daijirin',
          );
      expect(row.hidden, isTrue);
      expect(row.order, 1);
    });

    test('忘掉 host：目录行删掉，过滤里不再有它', () async {
      await repo.forgetRemoteDictionaryHost('h1');
      expect(repo.remoteDictionaries, isEmpty);
      expect(repo.lookupFilters.termDictionaryOrder, <String>['JMdict']);
    });
  });
}
