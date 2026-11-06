// 同步 v2 的并发读写（srs_location_store.dart）：有上限的并发池、云盘位置的列表缓存（每个文件少一次按名查）、
// 写并发上限（Dropbox）、并发写进新目录时文件夹只建一次（Google Drive 允许同名文件夹）。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:test/test.dart';

void main() {
  group('srsRunPooled', () {
    test('结果按输入顺序，同时在途不超过上限', () async {
      int inFlight = 0;
      int peak = 0;
      final List<int> out = await srsRunPooled(
        List<int>.generate(40, (int i) => i),
        6,
        (int i) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(Duration(milliseconds: 1 + (i * 7) % 5));
          inFlight--;
          return i * 2;
        },
      );
      expect(out, List<int>.generate(40, (int i) => i * 2));
      expect(peak, 6);
    });

    test('一个失败：不再开新的，等在途的跑完后抛出', () async {
      final List<int> started = <int>[];
      await expectLater(
        srsRunPooled(List<int>.generate(30, (int i) => i), 3, (int i) async {
          started.add(i);
          await Future<void>.delayed(const Duration(milliseconds: 2));
          if (i == 4) throw StateError('boom');
          return i;
        }),
        throwsA(isA<StateError>()),
      );
      expect(started.length, lessThan(30));
    });

    test('空输入', () async {
      expect(await srsRunPooled(<int>[], 4, (int i) async => i), isEmpty);
    });
  });

  group('SrsAssetLocationStore', () {
    late Directory dir;
    late _CountingStore backend;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('srs2_conc_');
      backend = _CountingStore(LocalDirectoryAssetStore(dir));
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄滞后。
      }
    });

    SrsAssetLocationStore location({int? maxConcurrentWrites}) =>
        SrsAssetLocationStore(
          store: backend,
          profileUid: 'p',
          maxConcurrentWrites: maxConcurrentWrites,
        );

    test('列过的目录：读用列出来的定位符、写新文件不再按名查', () async {
      final SrsAssetLocationStore seed = location();
      for (int i = 0; i < 5; i++) {
        await seed.put('devices/d1/seg-$i.bin', Uint8List.fromList(<int>[i]));
      }
      final SrsAssetLocationStore loc = location();
      await loc.list('devices/d1');
      backend.finds = 0;
      for (int i = 0; i < 5; i++) {
        expect(await loc.get('devices/d1/seg-$i.bin'), <int>[i]);
      }
      await loc.put('devices/d1/seg-new.bin', Uint8List.fromList(<int>[9]));
      expect(backend.finds, 0);
      // 没列过的目录照旧按名查；列过但不存在的文件读出 null。
      expect(await loc.get('devices/d1/missing.bin'), isNull);
      expect(await loc.get('devices/d2/x.bin'), isNull);
      // 覆盖写（同名）先删旧的：读回新内容。
      await loc.put('devices/d1/seg-0.bin', Uint8List.fromList(<int>[42]));
      expect(await location().get('devices/d1/seg-0.bin'), <int>[42]);
    });

    test('列出来之后被别人删掉：按名重查，读出 null 而不是抛错', () async {
      final SrsAssetLocationStore loc = location();
      await loc.put('devices/d1/a.bin', Uint8List.fromList(<int>[1]));
      await loc.list('devices/d1');
      await location().delete('devices/d1/a.bin');
      expect(await loc.get('devices/d1/a.bin'), isNull);
    });

    test('并发写进新目录：每级文件夹只建一次；写并发不超过上限', () async {
      final SrsAssetLocationStore loc = location(maxConcurrentWrites: 2);
      backend.putDelay = const Duration(milliseconds: 5);
      await srsRunPooled(
        List<int>.generate(12, (int i) => i),
        6,
        (int i) => loc.put('devices/new/seg-$i.bin', Uint8List(1)),
      );
      expect(backend.peakPuts, 2);
      expect(backend.ensured['new'], 1);
      expect(backend.ensured['devices'], 1);
      expect(
        (await location().list(
          'devices/new',
        )).map((SrsLocationEntry e) => e.name),
        hasLength(12),
      );
    });
  });
}

/// 记调用次数 / 在途写数的后端包装。
class _CountingStore implements SyncAssetStore {
  _CountingStore(this.inner);

  final SyncAssetStore inner;
  int finds = 0;
  int puts = 0;
  int peakPuts = 0;
  Duration putDelay = Duration.zero;
  final Map<String, int> ensured = <String, int>{};

  @override
  Future<String> ensureNamespace(String name) => inner.ensureNamespace(name);

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    ensured[name] = (ensured[name] ?? 0) + 1;
    // 让并发调用真的交错（真实后端是网络往返）。
    await Future<void>.delayed(const Duration(milliseconds: 2));
    return inner.ensureFolder(parentId, name);
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      inner.listChildren(namespaceId);

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) {
    finds++;
    return inner.findAsset(namespaceId, name);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    SyncTransferProgress? onProgress,
  }) async {
    puts++;
    if (puts > peakPuts) peakPuts = puts;
    try {
      await Future<void>.delayed(putDelay);
      await inner.putAsset(namespaceId, name, file, onProgress: onProgress);
    } finally {
      puts--;
    }
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    SyncTransferProgress? onProgress,
  }) => inner.getAsset(assetId, destination, onProgress: onProgress);

  @override
  Future<Object?> getJsonAsset(String assetId) => inner.getJsonAsset(assetId);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      inner.putJsonAsset(namespaceId, name, json);

  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      inner.deleteAsset(id, isFolder: isFolder);
}
