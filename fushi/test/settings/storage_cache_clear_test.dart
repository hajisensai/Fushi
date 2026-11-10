import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/settings/storage_usage_actions.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';

/// 反馈 jg3XoDVISk：存储页「清除全部缓存」的计划与执行原语。
///
/// 红线是「不碰用户数据」：可删（[kDeletableEntryCategories]）≠ 缓存。封面里有手动
/// 封面、浏览器数据里有登录态、备份包就是用户数据副本——这些只能逐条删。
void main() {
  StorageEntryUsage entry(
    String path,
    int bytes, {
    StorageEntryKind kind = StorageEntryKind.derivedFile,
  }) => StorageEntryUsage(
    id: path,
    label: path,
    bytes: bytes,
    paths: <String>[path],
    kind: kind,
  );

  StorageCategoryUsage category(
    StorageCategoryId id,
    List<StorageEntryUsage> entries,
  ) => StorageCategoryUsage(
    id: id,
    bytes: entries.fold<int>(0, (int s, StorageEntryUsage e) => s + e.bytes),
    entries: entries,
  );

  StorageUsageActions actions(
    Future<String?> Function(List<String> paths) deleteFiles,
  ) => StorageUsageActions(
    booksProvider: () async => const <StorageBookRef>[],
    dictionaryNamesProvider: () async => const <String>[],
    deleteBook: (String _) async => fail('清缓存不许走书籍删除'),
    deleteSrtBook: (String _) async => fail('清缓存不许走字幕书删除'),
    deleteDictionary: (String _) async => fail('清缓存不许走词典删除'),
    deleteDatabaseSnapshots: () async => fail('清缓存不许删数据库快照'),
    deleteFiles: deleteFiles,
    anime4kBytesProvider: () async => 0,
    anime4kDelete: () async => fail('清缓存不许删 Anime4K'),
  );

  group('kClearAllCacheCategories 契约', () {
    test('只收纯缓存，且是可直接删类目的子集', () {
      expect(
        kDeletableEntryCategories.containsAll(kClearAllCacheCategories),
        isTrue,
        reason: '一键清缓存只能是逐条可删集合的子集，不能扩权',
      );
      expect(kClearAllCacheCategories, contains(StorageCategoryId.cache));
    });

    test('用户数据类目一律不在内（封面 / 浏览器 / 导出 / 备份 / 模型 / 着色器 / 书 / 词典…）', () {
      for (final StorageCategoryId id in <StorageCategoryId>[
        StorageCategoryId.books,
        StorageCategoryId.dictionaries,
        StorageCategoryId.videoDownloads,
        StorageCategoryId.covers,
        StorageCategoryId.subtitles,
        StorageCategoryId.shaders,
        StorageCategoryId.customFonts,
        StorageCategoryId.web,
        StorageCategoryId.exports,
        StorageCategoryId.backups,
        StorageCategoryId.database,
        StorageCategoryId.ocrModels,
        StorageCategoryId.other,
      ]) {
        expect(kClearAllCacheCategories.contains(id), isFalse, reason: '$id');
      }
    });
  });

  group('buildStorageCacheClearPlan', () {
    test('只挑缓存类目的可删明细；其它类目即便可删也不进计划', () {
      final StorageCacheClearPlan plan = buildStorageCacheClearPlan(
        <StorageCategoryUsage>[
          category(StorageCategoryId.covers, <StorageEntryUsage>[
            entry('/docs/video_covers/manual.jpg', 4096),
          ]),
          category(StorageCategoryId.web, <StorageEntryUsage>[
            entry('/docs/browser/Cookies', 2048),
          ]),
          category(StorageCategoryId.backups, <StorageEntryUsage>[
            entry(
              '/tmp/fushi_backup.zip',
              8192,
              kind: StorageEntryKind.backupArchives,
            ),
          ]),
          category(StorageCategoryId.cache, <StorageEntryUsage>[
            entry('/tmp/remote_cover_cache', 1000),
            entry('/tmp/libCachedImageData', 3000),
          ]),
        ],
      );

      expect(
        plan.categories.map((StorageCategoryUsage u) => u.id),
        <StorageCategoryId>[StorageCategoryId.cache],
      );
      expect(plan.entries.map((StorageEntryUsage e) => e.id), <String>[
        '/tmp/remote_cover_cache',
        '/tmp/libCachedImageData',
      ]);
      expect(plan.bytes, 4000);
      expect(plan.isEmpty, isFalse);
    });

    test('缓存类目里的只读明细不进计划（只裸删无引用的派生文件）', () {
      final StorageCacheClearPlan plan = buildStorageCacheClearPlan(
        <StorageCategoryUsage>[
          category(StorageCategoryId.cache, <StorageEntryUsage>[
            entry('/tmp/a', 10),
            entry('/tmp/ro', 99, kind: StorageEntryKind.readOnly),
          ]),
        ],
      );
      expect(plan.entries.map((StorageEntryUsage e) => e.id), <String>[
        '/tmp/a',
      ]);
      expect(plan.bytes, 10);
    });

    test('缓存类目为空 / 没扫到 → 空计划', () {
      expect(
        buildStorageCacheClearPlan(<StorageCategoryUsage>[
          category(StorageCategoryId.cache, const <StorageEntryUsage>[]),
        ]).isEmpty,
        isTrue,
      );
      expect(
        buildStorageCacheClearPlan(const <StorageCategoryUsage>[]).isEmpty,
        isTrue,
      );
    });
  });

  group('clearStorageCache', () {
    test('逐条走 deleteFiles；一条失败不中断其余，失败逐条报出，只算成功的字节', () async {
      final StorageCacheClearPlan plan = buildStorageCacheClearPlan(
        <StorageCategoryUsage>[
          category(StorageCategoryId.cache, <StorageEntryUsage>[
            entry('/tmp/big', 5000),
            entry('/tmp/locked', 3000),
            entry('/tmp/small', 1000),
          ]),
        ],
      );
      final List<List<String>> calls = <List<String>>[];

      final StorageCacheClearOutcome outcome = await clearStorageCache(
        actions((List<String> paths) async {
          calls.add(paths);
          if (paths.single == '/tmp/locked') {
            throw const FileSystemException('in use', '/tmp/locked');
          }
          return null;
        }),
        plan,
      );

      expect(calls, <List<String>>[
        <String>['/tmp/big'],
        <String>['/tmp/locked'],
        <String>['/tmp/small'],
      ]);
      expect(outcome.freedBytes, 6000);
      expect(outcome.changed, isTrue);
      expect(outcome.failures.keys, <String>['/tmp/locked']);
      expect(
        storageCacheClearFailureReason(outcome),
        startsWith('/tmp/locked: '),
      );
    });

    test('deleteFiles 返回失败原因同样记为失败；全失败时 changed=false', () async {
      final StorageCacheClearPlan plan = buildStorageCacheClearPlan(
        <StorageCategoryUsage>[
          category(StorageCategoryId.cache, <StorageEntryUsage>[
            entry('/tmp/x', 1),
            entry('/tmp/y', 2),
          ]),
        ],
      );
      final StorageCacheClearOutcome outcome = await clearStorageCache(
        actions((List<String> paths) async => 'denied'),
        plan,
      );
      expect(outcome.freedBytes, 0);
      expect(outcome.changed, isFalse);
      expect(storageCacheClearFailureReason(outcome), '/tmp/x: denied (+1)');
    });

    test('全部成功 → 无失败摘要', () async {
      final StorageCacheClearPlan plan = buildStorageCacheClearPlan(
        <StorageCategoryUsage>[
          category(StorageCategoryId.cache, <StorageEntryUsage>[
            entry('/tmp/x', 7),
          ]),
        ],
      );
      final StorageCacheClearOutcome outcome = await clearStorageCache(
        actions((List<String> _) async => null),
        plan,
      );
      expect(outcome.freedBytes, 7);
      expect(storageCacheClearFailureReason(outcome), isNull);
    });
  });

  test('真实删除原语：整目录递归删掉，已不存在按成功', () async {
    final Directory tmp = Directory.systemTemp.createTempSync(
      'storage_cache_clear_test',
    );
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final Directory dir = Directory('${tmp.path}/remote_cover_cache')
      ..createSync();
    File('${dir.path}/c_a').writeAsBytesSync(<int>[1, 2, 3]);

    final StorageCacheClearOutcome outcome = await clearStorageCache(
      actions(deleteStorageDerivedFiles),
      buildStorageCacheClearPlan(<StorageCategoryUsage>[
        category(StorageCategoryId.cache, <StorageEntryUsage>[
          entry(dir.path, 3),
          entry('${tmp.path}/already_gone', 0),
        ]),
      ]),
    );

    expect(dir.existsSync(), isFalse);
    expect(outcome.failures, isEmpty);
    expect(outcome.freedBytes, 3);
  });
}
