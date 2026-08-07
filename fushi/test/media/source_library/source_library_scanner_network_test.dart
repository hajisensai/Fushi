// TODO-1274 网络来源扫描测试（无需真实 SFTP/FTP 服务器）：
//  (1) buildNetworkFileSystem 路由：local → LocalSourceFileSystem；
//      sftp/ftp → NetworkSourceFileSystem，连接参数/凭据注入正确。
//  (2) 网络「视频」来源被拒：scan 记 lastScanError、不插入任何视频（远端路径不可播）。
//  (3) 网络「书」来源：注入 fake fs，扫描时先 copyToLocal 下载远端 EPUB 再导入，
//      epub_books.sourceId 回填、mediaCount=1、无错误。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/source_library/source_file_system.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

Uint8List _encodeArchive(List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile f in files) {
    archive.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

const String _containerXml = '<?xml version="1.0" encoding="UTF-8"?>'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

String _contentOpf(String title) => '<?xml version="1.0" encoding="UTF-8"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
    'unique-identifier="book-id">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>$title</dc:title></metadata>'
    '<manifest><item id="chapter" href="chapter.xhtml" '
    'media-type="application/xhtml+xml"/></manifest>'
    '<spine><itemref idref="chapter"/></spine></package>';

const String _chapterXhtml = '<?xml version="1.0" encoding="UTF-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>C</title></head>'
    '<body><p>Hello world.</p></body></html>';

void _writeEpub(String path, String title) {
  final Uint8List bytes = _encodeArchive(<ArchiveFile>[
    _textFile('META-INF/container.xml', _containerXml),
    _textFile('OEBPS/content.opf', _contentOpf(title)),
    _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
  ]);
  File(path).writeAsBytesSync(bytes);
}

/// Fake network fs serving ONE remote EPUB from a real on-disk file. copyToLocal
/// "downloads" it by copying the bytes into the scanner's scratch temp dir.
class _FakeNetworkBookFs implements SourceFileSystem {
  _FakeNetworkBookFs({required this.localEpubPath, required this.remotePath});

  final String localEpubPath;
  final String remotePath; // e.g. /remote/novel.epub

  int copyToLocalCalls = 0;

  @override
  bool get isLocal => false;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async =>
      <SourceFileEntry>[
        SourceFileEntry(
          name: p.basename(remotePath),
          path: remotePath,
          isDirectory: false,
          sizeBytes: File(localEpubPath).lengthSync(),
        ),
      ];

  @override
  Future<List<String>> listSiblingNames(String filePath) async =>
      const <String>[];

  @override
  Future<String> readText(String filePath) async => throw UnimplementedError();

  @override
  Future<String> copyToLocal(String filePath, String destDir) async {
    copyToLocalCalls++;
    final String local = p.join(destDir, p.basename(remotePath));
    File(local).writeAsBytesSync(File(localEpubPath).readAsBytesSync());
    return local;
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  group('buildNetworkFileSystem (routing, no IO)', () {
    test('local → LocalSourceFileSystem', () {
      final SourceFileSystem fs = SourceLibraryScanner.buildNetworkFileSystem(
        transport: 'local',
        config: const <String, Object?>{},
      );
      expect(fs, isA<LocalSourceFileSystem>());
      expect(fs.isLocal, isTrue);
    });

    test('sftp → NetworkSourceFileSystem with injected params + secret', () {
      final SourceFileSystem fs = SourceLibraryScanner.buildNetworkFileSystem(
        transport: 'sftp',
        config: const <String, Object?>{
          'host': 'ssh.example.com',
          'port': 2222,
          'username': 'reader',
        },
        password: 'pw',
        privateKey: '-----BEGIN KEY-----',
      );
      expect(fs, isA<NetworkSourceFileSystem>());
      final NetworkSourceConfig cfg = (fs as NetworkSourceFileSystem).config;
      expect(cfg.transport, 'sftp');
      expect(cfg.host, 'ssh.example.com');
      expect(cfg.port, 2222);
      expect(cfg.username, 'reader');
      expect(cfg.password, 'pw');
      expect(cfg.privateKey, '-----BEGIN KEY-----');
    });

    test('ftp default port 21 + useTls when host config omits port', () {
      final SourceFileSystem fs = SourceLibraryScanner.buildNetworkFileSystem(
        transport: 'ftp',
        config: const <String, Object?>{
          'host': 'ftp.example.com',
          'username': 'u',
          'useTls': true,
        },
        password: 'p',
      );
      final NetworkSourceConfig cfg = (fs as NetworkSourceFileSystem).config;
      expect(cfg.port, 21);
      expect(cfg.useTls, isTrue);
    });

    test('sftp default port 22 when omitted; empty secret → null fields', () {
      final SourceFileSystem fs = SourceLibraryScanner.buildNetworkFileSystem(
        transport: 'sftp',
        config: const <String, Object?>{'host': 'h', 'username': 'u'},
        password: '',
        privateKey: '',
      );
      final NetworkSourceConfig cfg = (fs as NetworkSourceFileSystem).config;
      expect(cfg.port, 22);
      expect(cfg.password, isNull);
      expect(cfg.privateKey, isNull);
    });

    test('webdav → NetworkSourceFileSystem，username 注入 + isWebDav 路由', () {
      // WebDAV 的 configJson 只存 username（URL 即 rootPath，另行传入 host/port 仅
      // 为字段对齐，NetworkSourceFileSystem 忽略）；密码经凭据存储注入。
      final SourceFileSystem fs = SourceLibraryScanner.buildNetworkFileSystem(
        transport: 'webdav',
        config: const <String, Object?>{'username': 'reader'},
        password: 'pw',
      );
      expect(fs, isA<NetworkSourceFileSystem>());
      final NetworkSourceConfig cfg = (fs as NetworkSourceFileSystem).config;
      expect(cfg.transport, 'webdav');
      expect(cfg.isWebDav, isTrue);
      expect(cfg.username, 'reader');
      expect(cfg.password, 'pw');
    });
  });

  test(
      'network VIDEO source is rejected: scan records error, no video inserted',
      () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Remote Vids',
      mediaKind: 'video',
      rootPath: '/remote/vids',
      transport: const Value('sftp'),
      configJson: Value(
        '{"host":"ssh.example.com","port":22,"username":"u","useTls":false}',
      ),
      createdAt: 1000,
    ));
    final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

    // No credentials configured / no server contacted: the video guard throws
    // BEFORE any network I/O, so this is deterministic and offline.
    await SourceLibraryScanner(db).scan(source);

    final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
    expect(after.lastScanError, isNotNull,
        reason:
            'network video sources are unsupported and must record an error');
    expect(await VideoBookRepository(db).listAll(), isEmpty,
        reason: 'no video may be imported from an unsupported network source');
  });

  group('network BOOK source downloads then imports (fake fs)', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('todo1274_net_book_');
      pp = Directory.systemTemp.createTempSync('todo1274_net_pp_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pp.path,
      );
      EpubStorage.debugBaseDirectoryOverride = pp.path;
    });
    tearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      for (final Directory d in <Directory>[tmp, pp]) {
        try {
          if (d.existsSync()) d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets('remote EPUB is copyToLocal-downloaded then imported',
        (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      // A real on-disk EPUB standing in for the remote file the fake fs serves.
      final String localEpub = p.join(tmp.path, 'novel.epub');
      _writeEpub(localEpub, 'RemoteNovel');
      final _FakeNetworkBookFs fs = _FakeNetworkBookFs(
        localEpubPath: localEpub,
        remotePath: '/remote/books/novel.epub',
      );

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Remote Books',
        mediaKind: 'book',
        rootPath: '/remote/books',
        transport: const Value('sftp'),
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source, fs: fs);
      });

      // The remote EPUB was downloaded (copyToLocal invoked) before import.
      expect(fs.copyToLocalCalls, 1,
          reason: 'network book scan must download the remote EPUB first');

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(books.single.title, 'RemoteNovel');
      expect(books.single.sourceId, sid,
          reason: 'scanned remote book must be backfilled with its source id');

      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
      expect(after.lastScanError, isNull);
    });
  });
}
