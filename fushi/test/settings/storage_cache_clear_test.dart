import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/settings/storage_usage_actions.dart';
import 'package:fushi/src/storage/app_storage_areas.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';

/// 反馈 jg3XoDVISk：存储页「清除全部缓存」的计划与执行原语。
///
/// 红线是「不碰用户数据」：逐条可删（[StorageEntryDeletability.confirm]）≠ 缓存
/// （[StorageEntryDeletability.cacheBulk]）。封面里有手动封面、浏览器数据里有登录态、
/// 备份包就是用户数据副本——这些最多只能逐条删。
void main() {
  StorageEntryUsage entry(
    String path,
    int bytes, {
    StorageEntryKind kind = StorageEntryKind.derivedFile,
    StorageEntryDeletability? deletability,
  }) => StorageEntryUsage(
    id: path,
    label: path,
    bytes: bytes,
    paths: <String>[path],
    kind: kind,
    deletability:
        deletability ??
        (kind == StorageEntryKind.derivedFile
            ? StorageEntryDeletability.cacheBulk
            : null),
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

  group('一键清缓存的区域契约（登记表）', () {
    test('登记的区域里只有纯缓存区域可能进一键清缓存', () {
      for (final StorageArea area in kAppStorageAreas.areas) {
        if (area.entryDeletability == StorageEntryDeletability.cacheBulk) {
          expect(area.lifecycle, StorageLifecycle.cache, reason: area.id);
        }
      }
    });

    test('BUG-5613：封面与着色器区域连逐条删都不给（有库行指着、混着用户数据）', () {
      for (final StorageArea area in kAppStorageAreas.areas) {
        if (area.category != StorageCategoryId.covers &&
            area.category != StorageCategoryId.shaders) {
          continue;
        }
        expect(
          area.entryDeletability,
          StorageEntryDeletability.no,
          reason: area.id,
        );
      }
    });
  });

  group('buildStorageCacheClearPlan', () {
    test('只挑所有者标成纯缓存的明细；逐条可删的用户数据不进计划', () {
      final StorageCacheClearPlan plan = buildStorageCacheClearPlan(
        <StorageCategoryUsage>[
          category(StorageCategoryId.covers, <StorageEntryUsage>[
            entry(
              '/docs/video_covers/manual.jpg',
              4096,
              kind: StorageEntryKind.readOnly,
            ),
          ]),
          category(StorageCategoryId.web, <StorageEntryUsage>[
            entry(
              '/docs/browser/Cookies',
              2048,
              deletability: StorageEntryDeletability.confirm,
            ),
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
