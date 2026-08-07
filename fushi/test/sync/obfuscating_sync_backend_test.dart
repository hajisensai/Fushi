import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';
import 'package:fushi/src/sync/ttu_models.dart';

/// 记录型 fake inner backend：捕获上传到「云端」的字节（content/cover），
/// 下载时把预置的「云端字节」写到目标文件。其余方法 noSuchMethod 兜底。
class _RecordingBackend implements SyncBackend {
  /// folderId/fileName -> 上传到云端的字节（content 路径）。
  final Map<String, Uint8List> uploaded = <String, Uint8List>{};

  /// assetId -> 预置的「云端字节」，下载时写入目标文件。
  final Map<String, Uint8List> remoteBytes = <String, Uint8List>{};

  /// 最近一次 ensureBookFolder 从惰性回调取到的封面字节（已是装饰器处理后的）。
  Uint8List? lastCoverData;

  /// ensureBookFolder 里惰性封面回调被调用的次数（验证装饰器保持惰性）。
  int coverProviderCalls = 0;

  /// true 时 ensureBookFolder 模拟「书名→folderId 缓存命中」：直接早退，
  /// 一次都不碰封面回调。
  bool simulateCacheHit = false;

  /// 记录 JSON 方法被调用（验证纯委托不混淆）。
  TtuProgress? lastProgress;

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    uploaded['$folderId/$fileName'] = await file.readAsBytes();
    onProgress?.call(1.0);
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    uploaded['$namespaceId/$name'] = await file.readAsBytes();
    onProgress?.call(1.0);
  }

  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {
    await destination.writeAsBytes(remoteBytes[fileId] ?? Uint8List(0));
    onProgress?.call(1.0);
  }

  @override
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await destination.writeAsBytes(remoteBytes[assetId] ?? Uint8List(0));
    onProgress?.call(1.0);
  }

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    if (simulateCacheHit) return 'folder-$bookTitle';
    // 模拟 cache-miss 分支：真的去取封面字节（缓存命中的后端不会调用回调）。
    if (readCoverData != null) {
      coverProviderCalls++;
      lastCoverData = await readCoverData();
    }
    return 'folder-$bookTitle';
  }

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    lastProgress = progress;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<File> _tmpFile(String name, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('obf_test_');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f;
}

void main() {
  group('ObfuscatingSyncBackend content upload/download round-trip', () {
    test('uploadContentFile obfuscates bytes (inner sees magic header)',
        () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      final plain =
          Uint8List.fromList(List<int>.generate(5000, (i) => i & 0xFF));
      final src = await _tmpFile('content.epub', plain);

      await backend.uploadContentFile(
        folderId: 'F',
        fileName: 'content.epub',
        file: src,
      );

      final stored = inner.uploaded['F/content.epub']!;
      // 云端字节必须带 magic header 且与明文不同（确实混淆）。
      expect(SyncObfuscator.hasMagicHeader(stored), isTrue);
      expect(stored, isNot(equals(plain)));
      // 反混淆云端字节得回原文（体积仅多 magic header）。
      expect(SyncObfuscator.deobfuscateBytes(stored), plain);
      expect(stored.length, plain.length + SyncObfuscator.magicHeaderLength);
    });

    test(
        'downloadContentFile deobfuscates obfuscated remote bytes to plaintext',
        () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      final plain =
          Uint8List.fromList(List<int>.generate(8000, (i) => (i * 3) & 0xFF));
      inner.remoteBytes['asset1'] = SyncObfuscator.obfuscateBytes(plain);

      final dest = await _tmpFile('out.epub', const <int>[]);
      await backend.downloadContentFile(fileId: 'asset1', destination: dest);

      expect(await dest.readAsBytes(), plain);
    });

    test('full round-trip: upload then download yields original', () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      final plain = Uint8List.fromList(
          List<int>.generate(12345, (i) => (i * 7 + 1) & 0xFF));
      final src = await _tmpFile('a.bin', plain);

      await backend.putAsset('NS', 'a.bin', src);
      // 把上传到云端的字节当成下载源。
      inner.remoteBytes['back'] = inner.uploaded['NS/a.bin']!;
      final dest = await _tmpFile('a_out.bin', const <int>[]);
      await backend.getAsset('back', dest);

      expect(await dest.readAsBytes(), plain);
    });
  });

  group('ObfuscatingSyncBackend backward compat (mixed read)', () {
    test('downloadContentFile passes through legacy plaintext (no header)',
        () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      // 现有 Drive 明文：无 magic header。
      final legacy =
          Uint8List.fromList(List<int>.generate(4096, (i) => (i * 5) & 0xFF));
      inner.remoteBytes['old'] = legacy;

      final dest = await _tmpFile('legacy_out.epub', const <int>[]);
      await backend.downloadContentFile(fileId: 'old', destination: dest);

      // 旧明文原样落地（向后兼容，仍可导入）。
      expect(await dest.readAsBytes(), legacy);
    });
  });

  group('ObfuscatingSyncBackend cover obfuscation', () {
    test('ensureBookFolder obfuscates lazily-read cover bytes', () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      final cover =
          Uint8List.fromList(List<int>.generate(2048, (i) => (i * 9) & 0xFF));

      await backend.ensureBookFolder(
        bookTitle: 'Book',
        rootFolderId: 'root',
        readCoverData: () async => cover,
      );

      final stored = inner.lastCoverData!;
      expect(SyncObfuscator.hasMagicHeader(stored), isTrue);
      expect(SyncObfuscator.deobfuscateBytes(stored), cover);
    });

    test('ensureBookFolder forwards a null cover provider untouched', () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      await backend.ensureBookFolder(bookTitle: 'B', rootFolderId: 'r');
      expect(inner.lastCoverData, isNull);
      expect(inner.coverProviderCalls, 0);
    });

    // TODO-2657: 装饰器必须把混淆包在惰性回调「里面」。若它先 await 取字节、混淆
    // 完再把常量透传下去（eager 形态），内层后端即使缓存命中根本不要封面，也已经
    // 付掉了整张图的磁盘读 + 混淆代价——正是这轮要消掉的浪费。
    test('ObfuscatingSyncBackend does not read the cover eagerly', () async {
      final inner = _RecordingBackend()..simulateCacheHit = true;
      final backend = ObfuscatingSyncBackend(inner);
      int reads = 0;

      await backend.ensureBookFolder(
        bookTitle: 'Book',
        rootFolderId: 'root',
        readCoverData: () async {
          reads++;
          return Uint8List.fromList(<int>[1, 2, 3, 4]);
        },
      );

      expect(reads, 0, reason: '内层后端缓存命中不取封面时，装饰器也不许自己先读一遍');
      expect(inner.lastCoverData, isNull);
    });
  });

  group('ObfuscatingSyncBackend JSON methods are pure delegation (A2 deferred)',
      () {
    test('updateProgressFile delegates without obfuscation', () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      final prog = TtuProgress(
        dataId: 1,
        exploredCharCount: 0,
        progress: 0,
        lastBookmarkModified: 0,
      );
      await backend.updateProgressFile(
        folderId: 'F',
        fileId: null,
        progress: prog,
      );
      // JSON 原样透传给 inner（A1 不碰 JSON，留 A2）。
      expect(inner.lastProgress, same(prog));
    });
  });
}
