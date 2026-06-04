import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';

/// 对任意 [SyncAssetStore] 实现跑同一组行为断言。后端集成测试可复用
/// （传入真实后端工厂），单测传 FakeAssetStore。
void runAssetStoreContract(
  String label,
  SyncAssetStore Function() create,
) {
  group('SyncAssetStore contract: $label', () {
    late SyncAssetStore store;
    late Directory tmp;

    setUp(() async {
      store = create();
      tmp = await Directory.systemTemp.createTemp('asset_contract_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('put then find then get round-trips bytes', () async {
      final String ns = await store.ensureNamespace('books');
      final File src = File('${tmp.path}/a.bin')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      await store.putAsset(ns, 'a.bin', src);

      final AssetEntry? found = await store.findAsset(ns, 'a.bin');
      expect(found, isNotNull);
      expect(found!.name, 'a.bin');

      final File dst = File('${tmp.path}/out.bin');
      await store.getAsset(found.id, dst);
      expect(dst.readAsBytesSync(), <int>[1, 2, 3, 4]);
    });

    test('findAsset returns null for missing', () async {
      final String ns = await store.ensureNamespace('books');
      expect(await store.findAsset(ns, 'nope.bin'), isNull);
    });

    test('listChildren lists subfolders and files at one level only', () async {
      final String books = await store.ensureNamespace('books');
      final String sub = await store.ensureFolder(books, 'bookKey');
      final File src = File('${tmp.path}/c.epub')..writeAsBytesSync(<int>[9]);
      await store.putAsset(sub, 'content.epub', src);
      await store.putJsonAsset(books, 'top.json', <String, int>{'x': 1});

      final Set<String> topNames = (await store.listChildren(books))
          .map((AssetEntry e) => e.name)
          .toSet();
      expect(topNames, containsAll(<String>['bookKey', 'top.json']));
      // 不应递归出 content.epub
      expect(topNames.contains('content.epub'), isFalse);

      final Set<String> subNames =
          (await store.listChildren(sub)).map((AssetEntry e) => e.name).toSet();
      expect(subNames, contains('content.epub'));
    });

    test('json round-trips', () async {
      final String ns = await store.ensureNamespace('dictionaries');
      await store
          .putJsonAsset(ns, 'm.json', <String, Object?>{'k': 'v', 'n': 2});
      final AssetEntry? found = await store.findAsset(ns, 'm.json');
      final Object? decoded = await store.getJsonAsset(found!.id);
      expect(decoded, <String, Object?>{'k': 'v', 'n': 2});
    });

    test('deleteAsset removes a file (idempotent)', () async {
      final String ns = await store.ensureNamespace('books');
      final File src = File('${tmp.path}/a.txt')..writeAsStringSync('hello');
      await store.putAsset(ns, 'a.txt', src);
      expect(await store.findAsset(ns, 'a.txt'), isNotNull);

      final AssetEntry asset = (await store.findAsset(ns, 'a.txt'))!;
      await store.deleteAsset(asset.id);
      expect(await store.findAsset(ns, 'a.txt'), isNull);

      // 幂等：再删一次不应抛。
      await store.deleteAsset(asset.id);
    });

    test('deleteAsset removes a folder recursively', () async {
      final String ns = await store.ensureNamespace('books');
      final String sub = await store.ensureFolder(ns, 'bookA');
      final File src = File('${tmp.path}/content.epub')
        ..writeAsStringSync('content');
      await store.putAsset(sub, 'content.epub', src);

      await store.deleteAsset(sub, isFolder: true);
      final List<AssetEntry> children = await store.listChildren(ns);
      expect(children.where((AssetEntry c) => c.name == 'bookA'), isEmpty);
    });
  });
}
