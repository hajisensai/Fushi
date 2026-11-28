import 'dart:io';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/settings/storage_usage_actions.dart';
import 'package:fushi/src/storage/app_storage_areas.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

// settings-storage-page-open-jank：打开 设置 › 存储 时 UI isolate 卡顿。
//
// 1. 开页的清单取数只能读瘦投影：整行读 `epub_books` / `video_books` 会把每本
//    几十 KB 的 chaptersJson / tocJson、playlistJson 等经 drift 后台 isolate 拷回
//    UI isolate 解码（500 本书实测约 200 ms，全耗在 UI isolate 上）。
// 2. 开页扫描（类目扫描、随包组件、Anime4K 占用）在调用方 isolate 上不做任何同步
//    文件 IO——同步 stat / list 一律在后台 isolate 里。

/// 记录落到存储页所用各表上的 SELECT 语句。
class _SelectRecorder extends QueryInterceptor {
  final List<String> statements = <String>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements.add(statement);
    return executor.runSelect(statement, args);
  }
}

/// 只读整行才会出现的大列（存储页一列都用不上）。
const List<String> _fatColumns = <String>[
  'chapters_json',
  'toc_json',
  'source_metadata',
  'playlist_json',
];

/// 调用方 isolate 上的同步文件 IO 探针：zone 内新建的 File / Directory 都换成
/// 只放行异步与纯路径操作的包装，任何 `*Sync` 调用记一笔并抛出。
/// `Isolate.run` 的计算在新 isolate 的根 zone 里跑，不受这里的覆盖影响。
final class _NoSyncIoOverrides extends IOOverrides {
  final List<String> violations = <String>[];

  Never _violate(String what) {
    violations.add(what);
    throw StateError('sync IO on caller isolate: $what');
  }

  @override
  File createFile(String path) => _GuardFile(super.createFile(path), this);

  @override
  Directory createDirectory(String path) =>
      _GuardDirectory(super.createDirectory(path), this);

  @override
  FileStat statSync(String path) => _violate('FileStat.statSync($path)');

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      _violate('FileSystemEntity.typeSync($path)');

  @override
  bool fseIdenticalSync(String path1, String path2) =>
      _violate('FileSystemEntity.identicalSync($path1, $path2)');
}

class _GuardFile implements File {
  _GuardFile(this._real, this._guard);
  final File _real;
  final _NoSyncIoOverrides _guard;

  @override
  String get path => _real.path;
  @override
  Uri get uri => _real.uri;
  @override
  bool get isAbsolute => _real.isAbsolute;
  @override
  File get absolute => _GuardFile(_real.absolute, _guard);
  @override
  Directory get parent => _GuardDirectory(_real.parent, _guard);
  @override
  Future<bool> exists() => _real.exists();
  @override
  Future<int> length() => _real.length();
  @override
  Future<FileStat> stat() => _real.stat();
  @override
  String toString() => _real.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _guard._violate('File.${_memberName(invocation)}($path)');
}

class _GuardDirectory implements Directory {
  _GuardDirectory(this._real, this._guard);
  final Directory _real;
  final _NoSyncIoOverrides _guard;

  @override
  String get path => _real.path;
  @override
  Uri get uri => _real.uri;
  @override
  bool get isAbsolute => _real.isAbsolute;
  @override
  Directory get absolute => _GuardDirectory(_real.absolute, _guard);
  @override
  Directory get parent => _GuardDirectory(_real.parent, _guard);
  @override
  Future<bool> exists() => _real.exists();
  @override
  Future<FileStat> stat() => _real.stat();
  @override
  Future<Directory> create({bool recursive = false}) async {
    await _real.create(recursive: recursive);
    return this;
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => _real.list(recursive: recursive, followLinks: followLinks);
  @override
  String toString() => _real.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _guard._violate('Directory.${_memberName(invocation)}($path)');
}

String _memberName(Invocation invocation) {
  final String raw = invocation.memberName.toString();
  // Symbol("existsSync") -> existsSync
  return raw.substring(raw.indexOf('"') + 1, raw.lastIndexOf('"'));
}

void _writeFile(String path, int bytes) {
  final File f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

void main() {
  group('开页清单取数只读瘦投影', () {
    late _SelectRecorder recorder;
    late FushiDatabase db;

    setUp(() async {
      recorder = _SelectRecorder();
      db = FushiDatabase.forTesting(
        NativeDatabase.memory().interceptWith(recorder),
      );
      final String fatJson = '[${List<String>.filled(200, '"x"').join(',')}]';
      await db.batch((b) {
        b.insert(
          db.epubBooks,
          EpubBooksCompanion.insert(
            bookKey: 'book-a',
            title: 'Book A',
            epubPath: 'a.epub',
            extractDir: '/docs/fushi_books/book-a',
            chapterCount: 200,
            chaptersJson: fatJson,
            tocJson: Value(fatJson),
            importedAt: 1,
          ),
        );
        b.insert(
          db.audiobooks,
          AudiobooksCompanion.insert(
            bookKey: 'book-a',
            audioRoot: const Value('/docs/audiobooks/book-a'),
            alignmentFormat: 'srt',
            alignmentPath: '/docs/audiobooks/book-a/align.srt',
          ),
        );
        b.insert(
          db.videoBooks,
          VideoBooksCompanion.insert(
            bookUid: 'video-1',
            title: 'Video 1',
            videoPath: '/docs/videos/v1.mkv',
            playlistJson: Value(fatJson),
          ),
        );
      });
      recorder.statements.clear();
    });

    tearDown(() => db.close());

    test('书籍清单：结果正确，且不读 chapters_json / toc_json 等大列', () async {
      final List<StorageBookRef> refs = await loadStorageBookRefs(db);
      expect(refs, hasLength(1));
      expect(refs.single.id, 'book-a');
      expect(refs.single.title, 'Book A');
      expect(refs.single.extractDir, '/docs/fushi_books/book-a');
      expect(refs.single.audioPaths, contains('/docs/audiobooks/book-a'));
      _expectNoFatSelect(recorder.statements);
    });

    test('视频清单：结果正确，且不读 playlist_json 等大列', () async {
      final List<StorageVideoRef> refs = await loadStorageVideoRefs(db);
      expect(refs, hasLength(1));
      expect(refs.single.id, 'video-1');
      expect(refs.single.title, 'Video 1');
      expect(refs.single.videoPath, '/docs/videos/v1.mkv');
      _expectNoFatSelect(recorder.statements);
    });

    test('视频分组：取 id 最小的现存合集，别的媒体类型的成员不算；成员表不整表读回（BUG-5536）', () async {
      await db
          .into(db.videoBooks)
          .insert(
            VideoBooksCompanion.insert(
              bookUid: 'video-2',
              title: 'Video 2',
              videoPath: '/docs/videos/v2.mkv',
            ),
          );
      final int older = await db.createMediaCollection('作品 A');
      final int newer = await db.createMediaCollection('播放列表 B');
      final int epubOnly = await db.createMediaCollection('书单 C');
      expect(older < newer && newer < epubOnly, isTrue);
      // video-1 同时在两个合集里：按建立先后取较早的那个。
      await db.addToCollection(newer, MediaKind.video, 'video-1');
      await db.addToCollection(older, MediaKind.video, 'video-1');
      // 同 key 的非视频成员不能把视频归进书单。
      await db.addToCollection(epubOnly, MediaKind.epub, 'video-2');
      recorder.statements.clear();

      final List<StorageVideoRef> refs = await loadStorageVideoRefs(db);
      final Map<String, String?> groupOf = <String, String?>{
        for (final StorageVideoRef r in refs) r.id: r.group,
      };
      expect(groupOf, <String, String?>{'video-1': '作品 A', 'video-2': null});

      final List<String> memberReads = <String>[
        for (final String sql in recorder.statements)
          if (sql.contains('media_collection_items')) sql,
      ];
      expect(memberReads, isNotEmpty);
      for (final String sql in memberReads) {
        expect(
          sql.contains('media_type = ?') && sql.contains('GROUP BY'),
          isTrue,
          reason: '合集成员必须在 SQL 侧按类型过滤并分组，不能整表读回: $sql',
        );
      }
      _expectNoFatSelect(recorder.statements);
    });
  });

  group('开页扫描不在调用方 isolate 上做同步文件 IO', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('storage_no_sync_io');
    });

    tearDown(() {
      try {
        tempRoot.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 偶发句柄延迟释放：留给系统临时目录清理。
      }
    });

    test('类目扫描 + 随包组件 + Anime4K 占用', () async {
      final String docsPath = p.join(tempRoot.path, 'docs');
      final String supportPath = p.join(tempRoot.path, 'support');
      final String cachePath = p.join(tempRoot.path, 'cache');
      final String shadersPath = p.join(tempRoot.path, 'shaders');
      final String booksRoot = p.join(
        docsPath,
        EngineStorageArea.epubBooks.relativePath,
      );
      _writeFile(p.join(booksRoot, 'book-a', 'content.xhtml'), 300);
      _writeFile(p.join(supportPath, 'fushi.db'), 200);
      _writeFile(p.join(cachePath, 'tmp.bin'), 100);
      _writeFile(p.join(shadersPath, anime4kManifestFileNames().first), 50);

      final _NoSyncIoOverrides guard = _NoSyncIoOverrides();
      final ({
        List<StorageCategoryUsage> usage,
        List<BundledComponentUsage> bundled,
        int anime4k,
      })
      result = await IOOverrides.runWithIOOverrides(() async {
        final StorageUsageService service = StorageUsageService(
          documentsRoot: () async => Directory(docsPath),
          supportRoot: () async => Directory(supportPath),
          cacheRoots: () async => <Directory>[Directory(cachePath)],
          documentsRootIsFushiOwned: () async => true,
        );
        return (
          usage: await service
              .scanCategories(
                books: <StorageBookRef>[
                  StorageBookRef(
                    id: 'book-a',
                    title: 'Book A',
                    extractDir: p.join(booksRoot, 'book-a'),
                  ),
                ],
                dictionaryNames: const <String>['Dict'],
                videos: <StorageVideoRef>[
                  StorageVideoRef(
                    id: 'video-1',
                    title: 'Video 1',
                    videoPath: p.join(docsPath, 'videos', 'v1.mkv'),
                  ),
                ],
              )
              .toList(),
          bundled: await service.scanBundledComponents(),
          anime4k: await anime4kInstalledBytes(
            shaderDirectory: () async => Directory(shadersPath),
          ),
        );
      }, guard);

      expect(guard.violations, isEmpty);
      // 扫描确实跑完、量到了真实字节（不是因为什么都没做才没碰同步 IO）。
      final Map<StorageCategoryId, int> bytes = <StorageCategoryId, int>{
        for (final StorageCategoryUsage u in result.usage) u.id: u.bytes,
      };
      expect(bytes.keys.toSet(), StorageCategoryId.values.toSet());
      expect(bytes[StorageCategoryId.books], 300);
      expect(bytes[StorageCategoryId.database], greaterThanOrEqualTo(200));
      expect(bytes[StorageCategoryId.cache], 100);
      expect(result.anime4k, 50);
      expect(result.bundled, isA<List<BundledComponentUsage>>());
    });

    test('探针自检：调用方 isolate 上的同步 IO 会被记下', () async {
      final _NoSyncIoOverrides guard = _NoSyncIoOverrides();
      IOOverrides.runWithIOOverrides(() {
        expect(
          () => Directory(tempRoot.path).existsSync(),
          throwsA(isA<StateError>()),
        );
      }, guard);
      expect(guard.violations, <String>[
        'Directory.existsSync(${tempRoot.path})',
      ]);
    });
  });
}

void _expectNoFatSelect(List<String> statements) {
  expect(statements, isNotEmpty);
  for (final String sql in statements) {
    for (final String column in _fatColumns) {
      expect(
        sql.contains(column),
        isFalse,
        reason: 'storage listing must not read "$column": $sql',
      );
    }
    // 带大列的两张表必须显式列出投影列（整行 `SELECT *` 会把以后新增的大列
    // 也一并拉回来）。
    if (sql.contains('"epub_books"') || sql.contains('"video_books"')) {
      expect(
        RegExp(r'SELECT\s+\*', caseSensitive: false).hasMatch(sql),
        isFalse,
        reason: 'storage listing must project explicit columns: $sql',
      );
    }
  }
}
