import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi/src/sync/webdav_path_backend_mixin.dart';

/// WebDAV / 互联 client 共用的路径式三件套 [WebDavPathBackendMixin]。
///
/// 抽出前两后端各有一份逐字相同的 listBooks / ensureBookFolder / listSyncFiles；
/// 这里用 fake [WebDavOps] 锁住它们对原语的调用形状与 BUG-845 的尾斜杠规整。
void main() {
  // PNG 魔数：detectCoverFormat 据此判 image/png + .png。
  final Uint8List png = Uint8List.fromList(
      <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);

  late _FakeOps ops;
  late _Backend backend;

  setUp(() {
    ops = _FakeOps();
    backend = _Backend(ops);
  });

  group('listBooks', () {
    test('只返回子集合，剔除根自身与文件', () async {
      ops.children['https://dav.example/fushi-data/'] = <DavEntry>[
        _entry('https://dav.example/fushi-data/', 'fushi-data', true),
        _entry('https://dav.example/fushi-data/Book%20A/', 'Book A', true),
        _entry(
            'https://dav.example/fushi-data/videos.json', 'videos.json', false),
        _entry('https://dav.example/fushi-data/B', 'B', true),
      ];

      final List<SyncFileRef> books =
          await backend.listBooks('https://dav.example/fushi-data/');

      expect(books.map((SyncFileRef b) => b.name), <String>['Book A', 'B']);
      expect(books.first.id, 'https://dav.example/fushi-data/Book%20A/');
    });
  });

  group('ensureBookFolder', () {
    test('新书：MKCOL 一次、URL 编码书名、以 / 结尾、写入 folderIdCache', () async {
      final String id = await backend.ensureBookFolder(
        bookTitle: 'Book A',
        rootFolderId: 'https://dav.example/fushi-data/',
      );

      expect(id, 'https://dav.example/fushi-data/Book%20A/');
      expect(ops.ensured, <String>['https://dav.example/fushi-data/Book%20A/']);
      expect(backend.folderIdCache['Book A'], id);
    });

    test('命中缓存：不再 MKCOL；缓存里的无尾斜杠 href 补上 /（BUG-845）', () async {
      backend.folderIdCache['Book A'] =
          'https://dav.example/fushi-data/Book%20A';

      final String id = await backend.ensureBookFolder(
        bookTitle: 'Book A',
        rootFolderId: 'https://dav.example/fushi-data/',
      );

      expect(id, 'https://dav.example/fushi-data/Book%20A/');
      expect(ops.ensured, isEmpty);
    });

    test('封面：远端没有才 PUT，内容类型/扩展名按魔数判定', () async {
      await backend.ensureBookFolder(
        bookTitle: 'Book A',
        rootFolderId: 'https://dav.example/fushi-data/',
        readCoverData: () async => png,
      );

      expect(ops.puts, hasLength(1));
      expect(ops.puts.single.path,
          'https://dav.example/fushi-data/Book%20A/cover_1_6.png');
      expect(ops.puts.single.contentType, 'image/png');
      expect(ops.puts.single.bytes, png);
    });

    test('封面：远端已有则不重传', () async {
      ops.existing.add('https://dav.example/fushi-data/Book%20A/cover_1_6.png');

      await backend.ensureBookFolder(
        bookTitle: 'Book A',
        rootFolderId: 'https://dav.example/fushi-data/',
        readCoverData: () async => png,
      );

      expect(ops.puts, isEmpty);
    });

    test('封面上传失败是 best-effort：吞掉，目录仍返回并已缓存', () async {
      ops.failPut = true;

      final String id = await backend.ensureBookFolder(
        bookTitle: 'Book A',
        rootFolderId: 'https://dav.example/fushi-data/',
        readCoverData: () async => png,
      );

      expect(id, 'https://dav.example/fushi-data/Book%20A/');
      expect(backend.folderIdCache['Book A'], id);
    });
  });

  group('listSyncFiles', () {
    test('按前缀挑出 progress/statistics/audioBook，剔除目录自身与子集合', () async {
      const String folder = 'https://dav.example/fushi-data/Book%20A/';
      ops.children[folder] = <DavEntry>[
        _entry(folder, 'Book A', true),
        _entry('${folder}progress_1_6_x.json', 'progress_1_6_x.json', false),
        _entry(
            '${folder}statistics_1_6_y.json', 'statistics_1_6_y.json', false),
        _entry('${folder}audioBook_z.json', 'audioBook_z.json', false),
        _entry('${folder}book.epub', 'book.epub', false),
        _entry('${folder}sub/', 'sub', true),
      ];

      final SyncFileTrio trio = await backend.listSyncFiles(folder);

      expect(trio.progress?.name, 'progress_1_6_x.json');
      expect(trio.statistics?.name, 'statistics_1_6_y.json');
      expect(trio.audioBook?.name, 'audioBook_z.json');
    });

    test('空目录三者皆 null', () async {
      ops.children['https://dav.example/fushi-data/Empty/'] = <DavEntry>[];
      final SyncFileTrio trio =
          await backend.listSyncFiles('https://dav.example/fushi-data/Empty/');
      expect(trio.progress, isNull);
      expect(trio.statistics, isNull);
      expect(trio.audioBook, isNull);
    });
  });

  group('源码守卫：两个路径式后端不再各写一份三件套', () {
    const List<String> backends = <String>[
      'lib/src/sync/webdav_sync_backend.dart',
      'lib/src/sync/interconnect_sync_backend.dart',
    ];
    const List<String> banned = <String>[
      'Future<List<SyncFileRef>> listBooks(',
      'Future<String> ensureBookFolder(',
      'Future<SyncFileTrio> listSyncFiles(',
    ];

    for (final String path in backends) {
      test(path, () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path 不存在（请从 fushi/ 包根跑测试）');
        final String src = f.readAsStringSync();
        expect(src, contains('WebDavPathBackendMixin'),
            reason: '$path 必须混入 WebDavPathBackendMixin');
        for (final String needle in banned) {
          expect(src, isNot(contains(needle)),
              reason: '$path 里出现 `$needle`——三件套应只在 mixin 里有一份');
        }
      });
    }

    test('mixin 不擅自给三件套加 _ensureResolved 门（互联侧时序逐点保留）', () {
      final String src = File('lib/src/sync/webdav_path_backend_mixin.dart')
          .readAsStringSync();
      expect(src, isNot(contains('ensureResolved')));
    });
  });
}

DavEntry _entry(String href, String name, bool isCollection) =>
    DavEntry(href: href, displayName: name, isCollection: isCollection);

class _Put {
  const _Put(this.path, this.bytes, this.contentType);
  final String path;
  final List<int> bytes;
  final String contentType;
}

/// 只截四个原语；其余 [WebDavOps] 成员从不被三件套触碰。
class _FakeOps extends WebDavOps {
  _FakeOps()
      : super(
          baseUrl: 'https://dav.example',
          username: 'u',
          password: 'p',
        );

  final Map<String, List<DavEntry>> children = <String, List<DavEntry>>{};
  final List<String> ensured = <String>[];
  final Set<String> existing = <String>{};
  final List<_Put> puts = <_Put>[];
  bool failPut = false;

  @override
  Future<List<DavEntry>> propfindChildren(String path) async =>
      children[path] ?? (throw StateError('unexpected PROPFIND $path'));

  @override
  Future<void> ensureCollection(String path) async => ensured.add(path);

  @override
  Future<bool> headFile(String path) async => existing.contains(path);

  @override
  Future<void> putBytes(
      String path, List<int> bytes, String contentType) async {
    if (failPut) throw const SocketException('boom');
    puts.add(_Put(path, bytes, contentType));
  }
}

class _Backend extends SyncBackend
    with SyncFolderCache, WebDavPathBackendMixin {
  _Backend(this.ops);

  final _FakeOps ops;

  @override
  WebDavOps get davOps => ops;

  @override
  String get davLogTag => '[test]';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not used in this test');
}
