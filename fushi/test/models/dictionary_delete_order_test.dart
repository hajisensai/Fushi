import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as path;

import 'package:fushi/src/models/dictionary_directory.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/src/models/dictionary_repository.dart';

/// BUG-1756：删词典目录必须先让 native 引擎释放 mmap view。
///
/// 根因：词典加载时 `query.cpp` 的 `add_dict` 把 hash.table / bloom.filter /
/// blobs.bin / media.bin / media.idx 全部 `MapViewOfFile` 常驻映射。Windows 上
/// 只要那份 view 还活着，`DeleteFileW` 一律返回 ERROR_USER_MAPPED_FILE(1224)。
/// 四个删除入口原先都是「先删目录、后卸载引擎」，顺序反了：
///   * 手动删除 → 弹「删除失败」，但 DB 行已删 → 重启后词典消失、目录残留；
///   * 覆盖更新导入 → 第一步删旧目录就抛 → 「词典更新只能每次重新导入」。
///
/// 这里锚定两层：
///   1. 行为层：覆盖导入的旧本清理里，撤 meta（= 引擎重载）必须发生在目录消失之前；
///   2. 纯逻辑层：[deleteDictionaryDirectoryCore] 的重试 / 隔离 / 抛出分流。
void main() {
  group('覆盖导入：撤 meta（引擎重载）必须早于删目录', () {
    late Directory resourceDir;
    late FushiDatabase db;
    late DictionaryRepository repo;
    late DictionaryImportManager manager;

    /// 每次引擎重载时目录是否还在磁盘上（按发生顺序记录）。
    late List<bool> dirAliveAtRebuild;
    late Directory watched;

    Directory dirFor(String name) {
      final Directory d = Directory(path.join(resourceDir.path, name))
        ..createSync(recursive: true);
      File(path.join(d.path, 'blobs.bin')).writeAsStringSync('x');
      return d;
    }

    Dictionary dict(String name) => Dictionary(
          name: name,
          formatKey: 'yomichan',
          order: 0,
          type: DictionaryType.term,
          metadata: const <String, String>{},
          hiddenLanguages: const <String>[],
          collapsedLanguages: const <String>[],
        );

    setUp(() async {
      resourceDir = Directory.systemTemp.createTempSync('hibiki_dictdel_');
      db =
          FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
      dirAliveAtRebuild = <bool>[];
      watched = Directory(path.join(resourceDir.path, 'JMdict'));
      repo = DictionaryRepository(
        db,
        onCacheRebuild: () => dirAliveAtRebuild.add(watched.existsSync()),
      );
      await repo.loadFromDb();
      manager = DictionaryImportManager(
        dictRepo: repo,
        resourceDirectory: resourceDir,
        formats: const <String, DictionaryFormat>{},
      );
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      repo.dispose();
      await db.close();
      if (resourceDir.existsSync()) resourceDir.deleteSync(recursive: true);
    });

    test('replaceExact：引擎重载时旧目录仍在（顺序反了这里必红）', () async {
      final Directory old = dirFor('JMdict');
      repo.persistDictionary(dict('JMdict'));
      dirAliveAtRebuild.clear(); // persist 自己那次重载不算

      final Dictionary? preserved = await manager.resolveAndRemoveReplaced(
        newName: 'JMdict',
        decision: UpdateDecision.replaceExact,
        replaceTarget: null,
      );

      expect(preserved, isNotNull);
      expect(dirAliveAtRebuild, isNotEmpty,
          reason: '撤 meta 必须触发引擎重载（onCacheRebuild），否则旧索引会一直活着');
      expect(
        dirAliveAtRebuild.first,
        isTrue,
        reason: '引擎重载（释放 mmap view）必须发生在目录被删之前；先删后卸载在 '
            'Windows 上会撞 ERROR_USER_MAPPED_FILE，覆盖导入整条失败（BUG-1756）',
      );
      // 收尾状态不变：meta 与目录都不在了。
      expect(repo.hasDictionaryNamed('JMdict'), isFalse);
      expect(old.existsSync(), isFalse);
    });
  });

  group('deleteDictionaryDirectoryCore 分流', () {
    FileSystemException winErr(int code) => FileSystemException(
        'delete failed', 'D:/dict', OSError('occupied', code));

    test('一次成功 → deleted，不重试', () async {
      int calls = 0;
      final DictDirDeleteOutcome outcome = await deleteDictionaryDirectoryCore(
        delete: () async => calls++,
        quarantine: () async => fail('不该走隔离'),
        sleep: (int _) async {},
        isWindows: true,
      );
      expect(outcome, DictDirDeleteOutcome.deleted);
      expect(calls, 1);
    });

    test('Windows 占用码（5 / 32 / 1224）→ 重试到上限后隔离', () async {
      for (final int code in <int>[5, 32, 1224]) {
        int calls = 0;
        bool quarantined = false;
        final DictDirDeleteOutcome outcome =
            await deleteDictionaryDirectoryCore(
          delete: () async {
            calls++;
            throw winErr(code);
          },
          quarantine: () async => quarantined = true,
          sleep: (int _) async {},
          isWindows: true,
          maxAttempts: 3,
        );
        expect(outcome, DictDirDeleteOutcome.quarantined, reason: 'code=$code');
        expect(calls, 3, reason: 'code=$code 应重试到上限');
        expect(quarantined, isTrue, reason: 'code=$code');
      }
    });

    test('Windows 非占用码 → 原样抛给调用方报错', () async {
      await expectLater(
        deleteDictionaryDirectoryCore(
          delete: () async => throw winErr(2), // FILE_NOT_FOUND
          quarantine: () async => fail('不该走隔离'),
          sleep: (int _) async {},
          isWindows: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('非 Windows → 不重试、原样抛（POSIX 没有 mmap 删除锁）', () async {
      int calls = 0;
      await expectLater(
        deleteDictionaryDirectoryCore(
          delete: () async {
            calls++;
            throw winErr(5);
          },
          quarantine: () async => fail('不该走隔离'),
          sleep: (int _) async {},
          isWindows: false,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls, 1);
    });

    test('隔离也失败 → leftBehind（绝不把删不掉升级成异常打断删除流程）', () async {
      final DictDirDeleteOutcome outcome = await deleteDictionaryDirectoryCore(
        delete: () async => throw winErr(1224),
        quarantine: () async => throw winErr(1224),
        sleep: (int _) async {},
        isWindows: true,
        maxAttempts: 2,
      );
      expect(outcome, DictDirDeleteOutcome.leftBehind);
    });
  });

  group('deleteDictionaryDirectory / purgePendingDictionaryDeletes 真实文件系统', () {
    late Directory root;
    late int reloads;

    setUp(() {
      root = Directory.systemTemp.createTempSync('hibiki_dictfs_');
      reloads = 0;
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('目录不存在 → absent（幂等，不抛）', () async {
      expect(
        await deleteDictionaryDirectory(Directory(path.join(root.path, 'nope')),
            reloadEngine: () => reloads++),
        DictDirDeleteOutcome.absent,
      );
    });

    test('未被占用的词典目录连内容一起删掉', () async {
      final Directory d = Directory(path.join(root.path, 'JMdict'))
        ..createSync(recursive: true);
      File(path.join(d.path, 'blobs.bin')).writeAsStringSync('x');
      expect(
        await deleteDictionaryDirectory(d, reloadEngine: () => reloads++),
        DictDirDeleteOutcome.deleted,
      );
      expect(d.existsSync(), isFalse);
      expect(reloads, 1, reason: '释放映射会清空整个引擎，删完必须把剩下的词典装回去（BUG-1756）');
    });

    test('启动清理扫掉隔离区，其余词典目录不动', () async {
      final Directory pending =
          Directory(path.join(root.path, kDictionaryPendingDeleteDirName))
            ..createSync(recursive: true);
      File(path.join(pending.path, 'stale')).writeAsStringSync('x');
      final Directory keep = Directory(path.join(root.path, 'JMdict'))
        ..createSync(recursive: true);

      await purgePendingDictionaryDeletes(root);

      expect(pending.existsSync(), isFalse);
      expect(keep.existsSync(), isTrue);
    });
  });
}
