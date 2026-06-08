import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

void main() {
  group('computeDictionarySyncDiff', () {
    test('union by name: pull remote-only, push local-only, skip shared', () {
      final DictionarySyncDiff diff = computeDictionarySyncDiff(
        localNames: <String>{'JMdict', '明镜'},
        remoteNames: <String>{'明镜', 'NHK'},
      );
      expect(diff.toPull, <String>{'NHK'});
      expect(diff.toPush, <String>{'JMdict'});
    });

    test('empty both sides -> empty diff', () {
      final DictionarySyncDiff diff = computeDictionarySyncDiff(
        localNames: <String>{},
        remoteNames: <String>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });
  });

  group('AppModelLibraryHostService dictionaries', () {
    late Directory tmp;
    late HibikiDatabase db;
    late Directory dictRoot;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('hibiki_lib_host');
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      dictRoot = Directory(p.join(tmp.path, 'dicts'))
        ..createSync(recursive: true);
    });

    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test(
        'list reflects DictionaryMeta; export builds a package; delete removes',
        () async {
      await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
        name: 'JMdict',
        formatKey: 'yomichan',
        order: 0,
        type: const Value('term'),
      ));
      Directory(p.join(dictRoot.path, 'JMdict')).createSync(recursive: true);
      File(p.join(dictRoot.path, 'JMdict', 'blobs.bin'))
          .writeAsBytesSync(<int>[1, 2, 3]);

      final AppModelLibraryHostService svc = AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: dictRoot,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );

      final List<RemoteDictionaryInfo> list = await svc.listDictionaries();
      expect(list.map((RemoteDictionaryInfo d) => d.name), <String>['JMdict']);
      expect(list.first.type, 'term');

      final File pkg = await svc.exportDictionary('JMdict');
      expect(pkg.existsSync(), isTrue);
      expect(pkg.lengthSync(), greaterThan(0));

      await svc.deleteDictionary('JMdict');
      expect(await svc.listDictionaries(), isEmpty);
      expect(
        Directory(p.join(dictRoot.path, 'JMdict')).existsSync(),
        isFalse,
      );

      pkg.parent.deleteSync(recursive: true);
    });

    test('exportDictionary throws StateError for unknown name', () async {
      final AppModelLibraryHostService svc = AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: dictRoot,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
      await expectLater(
        svc.exportDictionary('nonexistent'),
        throwsA(isA<StateError>()),
      );
    });

    test('exportDictionary rejects path-traversal names with ArgumentError',
        () async {
      final AppModelLibraryHostService svc = AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: dictRoot,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
      // '../evil' 含 '..' 应抛 ArgumentError 而非到达 DB 查询
      await expectLater(
        svc.exportDictionary('../evil'),
        throwsA(isA<ArgumentError>()),
      );
      // 斜线穿越
      await expectLater(
        svc.exportDictionary('foo/bar'),
        throwsA(isA<ArgumentError>()),
      );
      // 反斜线穿越
      await expectLater(
        svc.exportDictionary('foo\\bar'),
        throwsA(isA<ArgumentError>()),
      );
      // 空名称
      await expectLater(
        svc.exportDictionary(''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('deleteDictionary rejects path-traversal names with ArgumentError',
        () async {
      final AppModelLibraryHostService svc = AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: dictRoot,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );
      // '../evil' 不应触及 dictRoot 外的路径，应抛 ArgumentError
      await expectLater(
        svc.deleteDictionary('../evil'),
        throwsA(isA<ArgumentError>()),
      );
      // 确认 dictRoot 父目录未被删除（穿越目标不存在也应在校验阶段就拦截）
      expect(dictRoot.existsSync(), isTrue);
    });
  });
}
