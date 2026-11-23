// HBK-AUDIT-223：[SyncAssetStore.getBytesAsset] 约定 256 MiB 上限
// （[kSyncBytesAssetMaxBytes]），超了抛错、不整份读进内存。这里钉共用的计数器
// [readSyncAssetBytesCapped] 与本机目录实现 [LocalDirectoryAssetStore]；云后端
// （OneDrive / Dropbox / SFTP）的契约测试在 app 侧
// `fushi/test/sync/sync_asset_bytes_cap_backends_test.dart`。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 逐块吐 [chunks] 块、每块 [chunkSize] 字节的来源，记下实际被拉走多少块。
class _CountingSource {
  _CountingSource({required this.chunks, required this.chunkSize});

  final int chunks;
  final int chunkSize;
  int pulled = 0;
  bool listened = false;
  bool cancelled = false;

  Stream<List<int>> get stream {
    late final StreamController<List<int>> c;
    c = StreamController<List<int>>(
      onListen: () async {
        listened = true;
        for (int i = 0; i < chunks; i++) {
          if (cancelled) return;
          pulled++;
          c.add(Uint8List(chunkSize));
          await Future<void>.delayed(Duration.zero);
        }
        await c.close();
      },
      onCancel: () => cancelled = true,
    );
    return c.stream;
  }
}

void main() {
  group('readSyncAssetBytesCapped', () {
    test('上限之内整份交回', () async {
      final _CountingSource src = _CountingSource(chunks: 4, chunkSize: 10);
      final Uint8List bytes = await readSyncAssetBytesCapped(
        src.stream,
        assetId: 'a',
        maxBytes: 40,
      );
      expect(bytes.length, 40);
    });

    test('边收边计数：刚超上限就抛并取消上游，不再往下收', () async {
      final _CountingSource src = _CountingSource(chunks: 1000, chunkSize: 10);
      await expectLater(
        readSyncAssetBytesCapped(src.stream, assetId: 'big', maxBytes: 35),
        throwsA(
          isA<SyncAssetTooLarge>()
              .having((SyncAssetTooLarge e) => e.assetId, 'assetId', 'big')
              .having((SyncAssetTooLarge e) => e.maxBytes, 'maxBytes', 35),
        ),
      );
      expect(src.cancelled, isTrue);
      expect(src.pulled, lessThan(10));
    });

    test('声明长度已超上限：一个字节都不收', () async {
      final _CountingSource src = _CountingSource(chunks: 1, chunkSize: 1);
      await expectLater(
        readSyncAssetBytesCapped(
          src.stream,
          assetId: 'big',
          maxBytes: 10,
          declaredLength: 11,
        ),
        throwsA(isA<SyncAssetTooLarge>()),
      );
      expect(src.listened, isFalse);
    });

    test('声明长度撒谎（报小）照样按实际字节拒', () async {
      final _CountingSource src = _CountingSource(chunks: 5, chunkSize: 10);
      await expectLater(
        readSyncAssetBytesCapped(
          src.stream,
          assetId: 'liar',
          maxBytes: 20,
          declaredLength: 5,
        ),
        throwsA(isA<SyncAssetTooLarge>()),
      );
    });
  });

  group('LocalDirectoryAssetStore.getBytesAsset', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('bytes_cap_');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('上限之内原样读回；不存在返回 null', () async {
      final LocalDirectoryAssetStore store = LocalDirectoryAssetStore(root);
      final String ns = await store.ensureNamespace('ns');
      await store.putBytesAsset(ns, 'a.bin', Uint8List.fromList(<int>[1, 2]));
      expect(await store.getBytesAsset(p.join(ns, 'a.bin')), <int>[1, 2]);
      expect(await store.getBytesAsset(p.join(ns, 'missing.bin')), isNull);
    });

    test('超过 kSyncBytesAssetMaxBytes 的文件抛 SyncAssetTooLarge，不读进内存', () async {
      final File big = File(p.join(root.path, 'big.bin'));
      // 只设长度（稀疏 / 延迟清零），不真写 256 MiB。
      final RandomAccessFile raf = await big.open(mode: FileMode.write);
      await raf.truncate(kSyncBytesAssetMaxBytes + 1);
      await raf.close();
      final LocalDirectoryAssetStore store = LocalDirectoryAssetStore(root);
      await expectLater(
        store.getBytesAsset(big.path),
        throwsA(isA<SyncAssetTooLarge>()),
      );
    });
  });
}
