import 'dart:io';

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/foundation/storage_area.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 测试用区域（宿主正常是增强枚举；这里用普通类拼出违规组合）。
class _Area implements StorageArea {
  const _Area(
    this.id,
    this.relativePath, {
    this.root = StorageRootId.documents,
    this.legacyNames = const <String>[],
    this.lifecycle = StorageLifecycle.userData,
    this.deletabilityOverride,
    this.countsAsLibraryEvidence = true,
  });

  @override
  final String id;
  @override
  final StorageRootId root;
  @override
  final String relativePath;
  @override
  final List<String> legacyNames;
  @override
  StorageCategoryId get category => StorageCategoryId.other;
  @override
  final StorageLifecycle lifecycle;
  @override
  final StorageEntryDeletability? deletabilityOverride;
  @override
  final bool countsAsLibraryEvidence;
}

void main() {
  group('StorageAreaRegistry 构造期校验', () {
    test('引擎区域自身合法', () {
      expect(
        () => StorageAreaRegistry(EngineStorageArea.values),
        returnsNormally,
      );
    });

    test('重复 id 抛', () {
      expect(
        () => StorageAreaRegistry(const <StorageArea>[
          _Area('a', 'x'),
          _Area('a', 'y'),
        ]),
        throwsArgumentError,
      );
    });

    test('同一根下同一路径被两个区域认领抛', () {
      expect(
        () => StorageAreaRegistry(const <StorageArea>[
          _Area('a', 'x'),
          _Area('b', 'x'),
        ]),
        throwsArgumentError,
      );
    });

    test('顶层名与别的区域的旧名撞（大小写不敏感）抛', () {
      expect(
        () => StorageAreaRegistry(const <StorageArea>[
          _Area('a', 'books', legacyNames: <String>['OldBooks']),
          _Area('b', 'oldbooks'),
        ]),
        throwsArgumentError,
      );
    });

    test('不同根下同名不冲突', () {
      expect(
        () => StorageAreaRegistry(const <StorageArea>[
          _Area('a', 'logs'),
          _Area('b', 'logs', root: StorageRootId.support),
        ]),
        returnsNormally,
      );
    });

    test('非缓存区域声明进一键清缓存抛', () {
      for (final StorageLifecycle lifecycle in StorageLifecycle.values) {
        if (lifecycle == StorageLifecycle.cache) continue;
        expect(
          () => StorageAreaRegistry(<StorageArea>[
            _Area(
              'a',
              'x',
              lifecycle: lifecycle,
              deletabilityOverride: StorageEntryDeletability.cacheBulk,
            ),
          ]),
          throwsArgumentError,
          reason: lifecycle.name,
        );
      }
    });

    test('坏相对路径 / 多段区域带旧名抛', () {
      for (final String bad in <String>['', 'a//b', '../x', 'a/./b', r'a\b']) {
        expect(
          () => StorageAreaRegistry(<StorageArea>[_Area('a', bad)]),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(
        () => StorageAreaRegistry(const <StorageArea>[
          _Area('a', 'torrent/resume', legacyNames: <String>['old']),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('派生量', () {
    final StorageAreaRegistry registry = StorageAreaRegistry(
      const <StorageArea>[
        _Area('books', 'books', legacyNames: <String>['old_books']),
        _Area('export', 'export', countsAsLibraryEvidence: false),
        _Area('db', 'models', root: StorageRootId.support),
        _Area('clips', 'clips', root: StorageRootId.userExports),
      ],
    );

    test('迁移白名单 = documents 根下顶层名 + 旧名', () {
      expect(registry.dataRootDocumentsEntries, <String>{
        'books',
        'old_books',
        'export',
      });
      expect(registry.libraryEvidenceIgnoredDocumentsEntries, <String>{
        'export',
      });
    });

    test('随数据根迁移只由根决定', () {
      expect(
        registry.areas.map((StorageArea a) => a.migratesWithDataRoot),
        <bool>[true, true, true, false],
      );
    });

    test('区域可删性默认取生命周期，覆盖优先', () {
      expect(
        const _Area('a', 'a').entryDeletability,
        StorageEntryDeletability.no,
      );
      expect(
        const _Area(
          'a',
          'a',
          lifecycle: StorageLifecycle.cache,
        ).entryDeletability,
        StorageEntryDeletability.cacheBulk,
      );
      expect(
        const _Area(
          'a',
          'a',
          deletabilityOverride: StorageEntryDeletability.confirm,
        ).entryDeletability,
        StorageEntryDeletability.confirm,
      );
    });

    test('pathUnder 按段拼', () {
      expect(
        const _Area('t', 'torrent/resume').pathUnder('/data/support'),
        p.join('/data/support', 'torrent', 'resume'),
      );
    });
  });

  group('EnginePaths.areaDirectory', () {
    final FixedEnginePaths paths = FixedEnginePaths(
      documents: Directory('/d'),
      support: Directory('/s'),
      temp: Directory('/t'),
    );

    test('引擎区域按登记的根解析，与具名 getter 一致', () async {
      expect(
        (await paths.videoCoversDirectory()).path,
        p.join('/d', 'video_covers'),
      );
      expect(
        (await paths.epubBooksDirectory()).path,
        p.join('/d', 'fushi_books'),
      );
      expect(
        (await paths.pickedVideoCopiesDirectory()).path,
        p.join('/s', 'imported_videos'),
      );
      expect(
        (await paths.areaDirectory(EngineStorageArea.asrJobs)).path,
        p.join('/s', 'asr_jobs'),
      );
    });

    test('宿主没有的根是编程错误', () {
      expect(
        paths.areaDirectory(
          const _Area('x', 'x', root: StorageRootId.hostData),
        ),
        throwsStateError,
      );
    });
  });
}
