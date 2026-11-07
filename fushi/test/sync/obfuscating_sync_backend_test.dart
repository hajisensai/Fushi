import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/obfuscating_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_obfuscator.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:path/path.dart' as p;

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

/// 上传必失败的 inner（模拟网络断 / 服务端 400）。
class _FailingUploadBackend extends _RecordingBackend {
  int uploadCalls = 0;

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    uploadCalls++;
    throw const SocketException('Broken pipe');
  }

  @override
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    uploadCalls++;
    throw const SocketException('Broken pipe');
  }
}

Future<List<String>> _listRel(Directory root) async {
  final List<String> out = <String>[];
  if (!await root.exists()) return out;
  await for (final FileSystemEntity e in root.list(recursive: true)) {
    out.add(e.path.substring(root.path.length + 1).replaceAll(r'\', '/'));
  }
  out.sort();
  return out;
}

/// 每个测试一个独立临时根（不碰真实 app 缓存目录，并行测试进程互不干扰）。
/// 收尾先放掉本进程槽位锁句柄（Windows 上不关删不掉目录）再删根。
Directory _testTempRoot() {
  final Directory root = Directory.systemTemp.createTempSync('obf_root_');
  addTearDown(() async {
    await ObfuscatingSyncBackend.debugReleaseSlots();
    if (root.existsSync()) await root.delete(recursive: true);
  });
  return root;
}

/// [root] 下残留的混淆临时目录 / 文件（排除槽位骨架：注册锁、槽位目录、所有者锁）。
Future<List<String>> _leftoverTemps(Directory root) async {
  final List<String> all = await _listRel(root);
  return all.where((String rel) {
    final List<String> parts = rel.split('/');
    if (parts.length == 1) {
      return parts[0] != '.registry.lock' && !parts[0].startsWith('p_');
    }
    if (parts.length == 2 && parts[0].startsWith('p_')) {
      return parts[1] != '.owner.lock';
    }
    return true;
  }).toList();
}

/// 找到与当前 flutter_tester 同一 SDK 的 dart 可执行文件（用来起「别的进程」）。
String _dartExecutable() {
  Directory d = File(Platform.resolvedExecutable).parent;
  for (int i = 0; i < 12; i++) {
    if (p.basename(d.path) == 'cache') {
      final String exe = p.join(
        d.path,
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      if (File(exe).existsSync()) return exe;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  final String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final String exe = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    if (File(exe).existsSync()) return exe;
  }
  throw StateError(
    '找不到 dart 可执行文件（resolvedExecutable=${Platform.resolvedExecutable}）',
  );
}

/// 起一个真实的子进程独占锁住 [lockFile]，模拟「另一个活着的 Fushi 进程」。
/// 子进程锁好后才返回；测试收尾时杀掉它。
Future<Process> _holdLockInChildProcess(File lockFile) async {
  final Directory scriptDir = Directory.systemTemp.createTempSync('obf_child_');
  final File script = File(p.join(scriptDir.path, 'hold_lock.dart'))
    ..writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> args) async {
  final RandomAccessFile raf = await File(args[0]).open(mode: FileMode.append);
  await raf.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdout.flush();
  await stdin.drain<void>();
}
''');
  final Process child = await Process.start(_dartExecutable(), <String>[
    script.path,
    lockFile.path,
  ]);
  addTearDown(() async {
    // 关 stdin 让子进程自己正常退出：Windows 上 `dart x.dart` 的真正 VM 可能是
    // dartdev 拉起的孙进程，只 kill 外层会留下仍握着锁文件的孙进程。stdin 是继承的，
    // 关掉后孙进程的 drain 结束、自行退出。
    await child.stdin.close();
    await child.exitCode;
    if (scriptDir.existsSync()) await scriptDir.delete(recursive: true);
  });
  final StringBuffer err = StringBuffer();
  child.stderr.transform(const SystemEncoding().decoder).listen(err.write);
  final String first = await child.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 60), onTimeout: () => '<timeout>');
  if (first != 'locked') {
    throw StateError('子进程没锁上：stdout=$first stderr=$err');
  }
  return child;
}

/// 上传时记下 inner 看到的临时文件路径。
class _PathRecordingBackend extends _RecordingBackend {
  final List<String> seenPaths = <String>[];

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {
    seenPaths.add(file.absolute.path);
    return super.uploadContentFile(
      folderId: folderId,
      fileName: fileName,
      file: file,
      onProgress: onProgress,
    );
  }
}

Future<File> _tmpFile(String name, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('obf_test_');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f;
}

void main() {
  group('ObfuscatingSyncBackend content upload/download round-trip', () {
    test(
      'uploadContentFile obfuscates bytes (inner sees magic header)',
      () async {
        final inner = _RecordingBackend();
        final backend = ObfuscatingSyncBackend(
          inner,
          tempRoot: _testTempRoot(),
        );
        final plain = Uint8List.fromList(
          List<int>.generate(5000, (i) => i & 0xFF),
        );
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
      },
    );

    test(
      'downloadContentFile deobfuscates obfuscated remote bytes to plaintext',
      () async {
        final inner = _RecordingBackend();
        final backend = ObfuscatingSyncBackend(
          inner,
          tempRoot: _testTempRoot(),
        );
        final plain = Uint8List.fromList(
          List<int>.generate(8000, (i) => (i * 3) & 0xFF),
        );
        inner.remoteBytes['asset1'] = SyncObfuscator.obfuscateBytes(plain);

        final dest = await _tmpFile('out.epub', const <int>[]);
        await backend.downloadContentFile(fileId: 'asset1', destination: dest);

        expect(await dest.readAsBytes(), plain);
      },
    );

    test('full round-trip: upload then download yields original', () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner, tempRoot: _testTempRoot());
      final plain = Uint8List.fromList(
        List<int>.generate(12345, (i) => (i * 7 + 1) & 0xFF),
      );
      final src = await _tmpFile('a.bin', plain);

      await backend.putAsset('NS', 'a.bin', src);
      // 把上传到云端的字节当成下载源。
      inner.remoteBytes['back'] = inner.uploaded['NS/a.bin']!;
      final dest = await _tmpFile('a_out.bin', const <int>[]);
      await backend.getAsset('back', dest);

      expect(await dest.readAsBytes(), plain);
    });
  });

  // BUG-4227：iOS 日志里 tmp/ 残留 9 份 603MB 的 obf_up_*/blob。混淆临时目录必须在
  // 进程内任何失败路径上删掉，且上一个进程被杀留下的遗留要在启动时清掉。
  group('ObfuscatingSyncBackend temp lifecycle (BUG-4227)', () {
    test('obfuscation failure still removes the temp dir', () async {
      final Directory root = _testTempRoot();
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner, tempRoot: root);
      // 源文件不存在 → Rust 混淆失败（建好临时目录之后才失败）。
      final File missing = File('${root.path}/does_not_exist.m4b');

      await expectLater(
        backend.uploadContentFile(
          folderId: 'F',
          fileName: 'a.m4b',
          file: missing,
        ),
        throwsA(anything),
      );
      await expectLater(
        backend.putAsset('NS', 'a.m4b', missing),
        throwsA(anything),
      );

      expect(inner.uploaded, isEmpty);
      expect(await _leftoverTemps(root), isEmpty, reason: '混淆失败也不许留临时目录');
    });

    test('inner upload failure removes the temp dir', () async {
      final Directory root = _testTempRoot();
      final inner = _FailingUploadBackend();
      final backend = ObfuscatingSyncBackend(inner, tempRoot: root);
      final Directory srcDir = await Directory.systemTemp.createTemp('b4227s_');
      addTearDown(() => srcDir.delete(recursive: true));
      final File src = File('${srcDir.path}/a.bin')
        ..writeAsBytesSync(List<int>.generate(4096, (int i) => i & 0xFF));

      await expectLater(
        backend.uploadContentFile(folderId: 'F', fileName: 'a', file: src),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        backend.putAsset('NS', 'a', src),
        throwsA(isA<SocketException>()),
      );

      expect(inner.uploadCalls, 2);
      expect(await _leftoverTemps(root), isEmpty);
    });

    test('sweepLegacyTempsIn removes only old root-level leftovers', () async {
      final Directory sys = await Directory.systemTemp.createTemp('b4227sys_');
      addTearDown(() => sys.delete(recursive: true));
      void mk(String rel, [String content = 'x']) {
        File('${sys.path}/$rel')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
      }

      // 共享系统临时目录里的子目录（哪怕叫 fushi_sync_obf、属于别的用户 / 进程）
      // 一律不碰：遗留清理只管旧版本建在根下的 obf_*。
      mk('${ObfuscatingSyncBackend.tempDirName}/p_1_x/obf_up_AAAA/blob');
      // 旧版本直接建在系统临时目录根下的遗留（iOS 日志里的 obf_up_0p1Dl4/blob 形态）。
      mk('obf_up_0p1Dl4/blob');
      mk('obf_get_xyz/blob');
      Directory('${sys.path}/obf_dn_empty').createSync();
      // 不属于本功能的东西：同前缀但内容不是只有 blob、无关目录、同名普通文件。
      mk('obf_up_foreign/other.txt');
      mk('obf_up_mixed/blob');
      mk('obf_up_mixed/notes.txt');
      mk('keep_me/blob');
      mk('obf_up_plainfile');
      mk('また、同じ夢を見ていた.m4b');

      final int removed = await ObfuscatingSyncBackend.sweepLegacyTempsIn(sys);

      expect(removed, 3);
      expect(await _listRel(sys), <String>[
        ObfuscatingSyncBackend.tempDirName,
        '${ObfuscatingSyncBackend.tempDirName}/p_1_x',
        '${ObfuscatingSyncBackend.tempDirName}/p_1_x/obf_up_AAAA',
        '${ObfuscatingSyncBackend.tempDirName}/p_1_x/obf_up_AAAA/blob',
        'keep_me',
        'keep_me/blob',
        'obf_up_foreign',
        'obf_up_foreign/other.txt',
        'obf_up_mixed',
        'obf_up_mixed/blob',
        'obf_up_mixed/notes.txt',
        'obf_up_plainfile',
        'また、同じ夢を見ていた.m4b',
      ]);
    });

    test('successful upload leaves nothing under the temp root', () async {
      final Directory root = _testTempRoot();
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner, tempRoot: root);
      final Directory srcDir = await Directory.systemTemp.createTemp('b4227s_');
      addTearDown(() => srcDir.delete(recursive: true));
      final File src = File('${srcDir.path}/a.bin')
        ..writeAsBytesSync(List<int>.generate(1024, (int i) => i & 0xFF));

      await backend.uploadContentFile(folderId: 'F', fileName: 'a', file: src);
      inner.remoteBytes['r'] = inner.uploaded['F/a']!;
      await backend.getAsset('r', File('${srcDir.path}/out.bin'));

      expect(await _leftoverTemps(root), isEmpty);
    });
  });

  // BUG-4227 review：临时根不能是多用户共享的 systemTemp 固定子目录；清理只能删
  // 已死进程的槽位，不能删活进程（别的用户 / 并行测试进程 / 另一个 Fushi 实例）的。
  group('ObfuscatingSyncBackend temp ownership (BUG-4227 review)', () {
    test('default temp root lives under the app-private cache dir', () async {
      final TestWidgetsFlutterBinding binding =
          TestWidgetsFlutterBinding.ensureInitialized();
      final Directory ppDir = Directory.systemTemp.createTempSync('obf_pp_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => ppDir.path,
      );
      addTearDown(() async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await ObfuscatingSyncBackend.debugReleaseSlots();
        if (ppDir.existsSync()) await ppDir.delete(recursive: true);
      });
      final String expectedRoot = p.join(
        (await AppPaths.appCacheRootDirectory()).absolute.path,
        ObfuscatingSyncBackend.tempDirName,
      );
      final String sharedTempRoot = p.join(
        Directory.systemTemp.absolute.path,
        ObfuscatingSyncBackend.tempDirName,
      );
      expect(expectedRoot, isNot(sharedTempRoot));

      final inner = _PathRecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      final Directory srcDir = Directory.systemTemp.createTempSync('obf_src_');
      addTearDown(() => srcDir.delete(recursive: true));
      final File src = File(p.join(srcDir.path, 'a.bin'))
        ..writeAsBytesSync(List<int>.generate(256, (int i) => i));

      await backend.uploadContentFile(folderId: 'F', fileName: 'a', file: src);

      expect(inner.seenPaths, hasLength(1));
      expect(
        p.isWithin(expectedRoot, inner.seenPaths.single),
        isTrue,
        reason: '临时文件必须在 app 私有缓存目录下：${inner.seenPaths.single}',
      );
      expect(p.isWithin(sharedTempRoot, inner.seenPaths.single), isFalse);
      expect(await _leftoverTemps(Directory(expectedRoot)), isEmpty);
    });

    test(
      'claiming a slot removes dead owners only, never a live process slot',
      () async {
        final Directory root = _testTempRoot();
        void mk(String rel, [String content = 'x']) {
          File(p.join(root.path, rel))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(content);
        }

        // 另一个活着的进程（真实子进程持有所有者锁），正在上传。
        mk('p_1_live/.owner.lock', '');
        mk('p_1_live/obf_up_inflight/blob');
        await _holdLockInChildProcess(
          File(p.join(root.path, 'p_1_live', '.owner.lock')),
        );
        // 死进程：锁文件在但没人持有（进程退出锁已释放）。
        mk('p_2_dead/.owner.lock', '');
        mk('p_2_dead/obf_up_AAAA/blob');
        // 死在认领途中：连锁文件都没有。
        Directory(p.join(root.path, 'p_3_nolock')).createSync();
        // 同 pid（同进程另一个 isolate）：fcntl 锁判不了活，必须当活的留着。
        mk('p_${pid}_sibling/obf_dn_BBBB/blob');
        // 根下不是槽位的东西不碰。
        mk('keep_me/blob');

        int sweepErrors() => ErrorLogService.instance.entries
            .where(
              (ErrorLogEntry e) =>
                  e.source == 'ObfuscatingSyncBackend.sweepDeadSlots',
            )
            .length;
        final int sweepErrorsBefore = sweepErrors();
        final inner = _PathRecordingBackend();
        final backend = ObfuscatingSyncBackend(inner, tempRoot: root);
        final Directory srcDir = Directory.systemTemp.createTempSync(
          'obf_src_',
        );
        addTearDown(() => srcDir.delete(recursive: true));
        final File src = File(p.join(srcDir.path, 'a.bin'))
          ..writeAsBytesSync(List<int>.generate(256, (int i) => i));

        await backend.uploadContentFile(
          folderId: 'F',
          fileName: 'a',
          file: src,
        );

        final List<String> top = root
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList();
        expect(top, contains('p_1_live'));
        expect(
          File(
            p.join(root.path, 'p_1_live', 'obf_up_inflight', 'blob'),
          ).existsSync(),
          isTrue,
          reason: '活进程正在用的临时文件不许删',
        );
        // Windows 上删一个被别的进程开着的锁文件会因共享冲突失败、被记日志后跳过，
        // 所以「活槽位还在」单看目录在不在不够：清理压根不许去删它。
        expect(sweepErrors(), sweepErrorsBefore, reason: '不许尝试删活进程的槽位');
        expect(top, isNot(contains('p_2_dead')));
        expect(top, isNot(contains('p_3_nolock')));
        expect(top, contains('p_${pid}_sibling'));
        expect(top, contains('keep_me'));
        // 本进程的临时文件建在自己新认领的槽位里，用完即删。
        final String own = p.basename(
          p.dirname(p.dirname(inner.seenPaths.single)),
        );
        expect(own, startsWith('p_${pid}_'));
        expect(own, isNot('p_${pid}_sibling'));
        expect(
          Directory(
            p.join(root.path, own),
          ).listSync().map((FileSystemEntity e) => p.basename(e.path)),
          <String>['.owner.lock'],
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('ObfuscatingSyncBackend backward compat (mixed read)', () {
    test(
      'downloadContentFile passes through legacy plaintext (no header)',
      () async {
        final inner = _RecordingBackend();
        final backend = ObfuscatingSyncBackend(
          inner,
          tempRoot: _testTempRoot(),
        );
        // 现有 Drive 明文：无 magic header。
        final legacy = Uint8List.fromList(
          List<int>.generate(4096, (i) => (i * 5) & 0xFF),
        );
        inner.remoteBytes['old'] = legacy;

        final dest = await _tmpFile('legacy_out.epub', const <int>[]);
        await backend.downloadContentFile(fileId: 'old', destination: dest);

        // 旧明文原样落地（向后兼容，仍可导入）。
        expect(await dest.readAsBytes(), legacy);
      },
    );
  });

  group('ObfuscatingSyncBackend cover obfuscation', () {
    test('ensureBookFolder obfuscates lazily-read cover bytes', () async {
      final inner = _RecordingBackend();
      final backend = ObfuscatingSyncBackend(inner);
      final cover = Uint8List.fromList(
        List<int>.generate(2048, (i) => (i * 9) & 0xFF),
      );

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

  group(
    'ObfuscatingSyncBackend JSON methods are pure delegation (A2 deferred)',
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
    },
  );
}
