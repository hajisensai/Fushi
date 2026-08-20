// TODO-1274 网络来源扫描测试（无需真实 SFTP/FTP/WebDAV 服务器）：
//  (1) buildNetworkFileSystem 路由：local → LocalSourceFileSystem；
//      sftp/ftp → NetworkSourceFileSystem，连接参数/凭据注入正确。
//  (2) 网络「视频」来源仅 WebDAV：SFTP/FTP 记 lastScanError、不插入任何视频
//      （远端路径无 HTTP 直链不可播）；WebDAV 按流媒体书**原地**入库——
//      videoPath=URL、sidecar 字幕 URL 进 streamSpecJson、标题百分号解码、
//      不抽封面、不建合集。
//  (3) 网络「书」来源：注入 fake fs，扫描时先 copyToLocal 下载远端 EPUB 再导入，
//      epub_books.sourceId 回填、mediaCount=1、无错误。
//  (4) 网络「漫画」来源：整卷镜像下载后经 MangaImporter 导入（sourceId 回填）；
//      重扫命中标题预检，零页图重下载。

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
import 'package:fushi/src/media/video/url_stream_video.dart'
    show StreamVideoSpec;
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

/// 虚拟网络 fs：把「远端命名空间路径」（`/remote/...` 或百分号编码的
/// `https://...` href）映射到本地真文件。列目录 / 读文本 / 下载全部离线可测。
class _FakeVirtualNetworkFs implements SourceFileSystem {
  _FakeVirtualNetworkFs(this.files);

  /// virtualPath → 本地真文件路径。
  final Map<String, String> files;

  int copyToLocalCalls = 0;

  @override
  bool get isLocal => false;

  static String _decodedName(String vpath) {
    final String raw = vpath.substring(vpath.lastIndexOf('/') + 1);
    if (vpath.startsWith('http://') || vpath.startsWith('https://')) {
      return Uri.decodeComponent(raw);
    }
    return raw;
  }

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async {
    final String prefix = dirPath.endsWith('/') ? dirPath : '$dirPath/';
    final List<SourceFileEntry> out = <SourceFileEntry>[];
    for (final String vpath in files.keys) {
      if (!vpath.startsWith(prefix)) continue;
      final String rest = vpath.substring(prefix.length);
      // 递归模式只回文件（对齐真实实现）；非递归只列一层。
      if (!recursive && rest.contains('/')) continue;
      out.add(SourceFileEntry(
        name: _decodedName(vpath),
        path: vpath,
        isDirectory: false,
      ));
    }
    return out;
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) async {
    final String dir = filePath.substring(0, filePath.lastIndexOf('/'));
    final List<SourceFileEntry> entries = await listFiles(dir);
    return entries.map((SourceFileEntry e) => e.name).toList();
  }

  @override
  Future<String> readText(String filePath) async =>
      File(files[filePath]!).readAsString();

  @override
  Future<String> copyToLocal(String filePath, String destDir) async {
    copyToLocalCalls++;
    final String local = p.join(destDir, _decodedName(filePath));
    File(local).writeAsBytesSync(File(files[filePath]!).readAsBytesSync());
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
      'network VIDEO source over SFTP is rejected (WebDAV only): '
      'scan records error, no video inserted', () async {
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

  group('network VIDEO source over WebDAV imports stream-in-place (fake fs)',
      () {
    testWidgets(
        'entry URLs become stream books with decoded titles; same-series '
        'episodes group into a collection; m3u8 manifest imports as a '
        'playlist of remote-URL episodes', (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      final Directory tmp =
          Directory.systemTemp.createTempSync('net_webdav_video_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // 占位本地字节：流播导入只该下载清单文本，不碰视频/字幕字节。
      final String dummy = p.join(tmp.path, 'dummy.bin');
      File(dummy).writeAsBytesSync(<int>[0]);
      final String manifest = p.join(tmp.path, 'best.m3u8');
      File(manifest).writeAsStringSync('#EXTM3U\nclip 1.mkv\nclip 2.mkv\n');

      const String root = 'https://dav.example.com/media';
      final _FakeVirtualNetworkFs fs = _FakeVirtualNetworkFs(<String, String>{
        '$root/Show%20A/Show%20A%20S01E01.mkv': dummy,
        '$root/Show%20A/Show%20A%20S01E01.srt': dummy,
        '$root/Show%20A/Show%20A%20S01E02.mkv': dummy,
        '$root/Lists/Best%20Of.m3u8': manifest,
      });

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Remote WebDAV Vids',
        mediaKind: 'video',
        rootPath: root,
        transport: const Value('webdav'),
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source, fs: fs);
      });

      final List<VideoBookRow> videos = await VideoBookRepository(db).listAll();
      // 2 部直扫单集 + 清单拆出的 2 集。
      expect(videos, hasLength(4));
      final VideoBookRow e01 = videos.singleWhere((VideoBookRow v) =>
          v.videoPath == '$root/Show%20A/Show%20A%20S01E01.mkv');
      expect(e01.title, 'Show A S01E01',
          reason: 'title must be percent-decoded, not the raw href basename');
      expect(e01.coverPath, isNull,
          reason: 'no cover extraction for remote streams');
      expect(e01.sourceId, sid);
      final StreamVideoSpec spec =
          StreamVideoSpec.fromStorageJson(e01.streamSpecJson);
      expect(spec.subtitleUrl, '$root/Show%20A/Show%20A%20S01E01.srt',
          reason: 'sidecar subtitle rides in streamSpecJson (played via the '
              'stream channel, not local cue parsing)');
      expect(spec.subtitleFileName, 'Show A S01E01.srt');
      expect(fs.copyToLocalCalls, 1,
          reason: 'only the m3u8 manifest text is downloaded; video and '
              'subtitle bytes stream in place');

      // 清单集：相对明文条目解析成编码后的远端 URL（可直接喂播放器）。
      final VideoBookRow clip1 = videos.singleWhere(
          (VideoBookRow v) => v.videoPath == '$root/Lists/clip%201.mkv');
      expect(clip1.sourceId, sid);

      // 归组：同系列两集折叠成 'Show A' 合集（解码名）；清单成 'Best Of' 合集。
      final List<MediaCollectionRow> collections =
          await db.getAllMediaCollections();
      expect(
        collections.map((MediaCollectionRow c) => c.name).toSet(),
        <String>{'Show A', 'Best Of'},
        reason: '合集名必须是解码后的（不能带 %20）',
      );

      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 3, reason: '2 部直扫视频 + 1 个清单合集');
      expect(after.lastScanError, isNull);
    });
  });

  group('network MANGA source mirrors the volume then imports (fake fs)', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('net_manga_fixture_');
      pp = Directory.systemTemp.createTempSync('net_manga_pp_');
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

    testWidgets(
        'volume downloads page-by-page and imports with sourceId; '
        're-scan hits the title pre-check with zero page downloads',
        (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);

      // 本地 fixture 站位远端卷：Vol1.mokuro + Vol1/ 两张页图。
      final String pageA = p.join(tmp.path, 'p001.jpg');
      final String pageB = p.join(tmp.path, 'p002.jpg');
      File(pageA).writeAsBytesSync(<int>[1, 2, 3]);
      File(pageB).writeAsBytesSync(<int>[4, 5, 6]);
      final String mokuroLocal = p.join(tmp.path, 'Vol1.mokuro');
      File(mokuroLocal).writeAsStringSync(jsonEncode(<String, Object?>{
        'version': '0.2.0',
        'title': 'RemoteManga',
        'pages': <Object?>[
          <String, Object?>{
            'img_width': 800,
            'img_height': 1200,
            'img_path': 'Vol1/p001.jpg',
            'blocks': <Object?>[],
          },
          <String, Object?>{
            'img_width': 800,
            'img_height': 1200,
            'img_path': 'Vol1/p002.jpg',
            'blocks': <Object?>[],
          },
        ],
      }));

      final _FakeVirtualNetworkFs fs = _FakeVirtualNetworkFs(<String, String>{
        '/remote/manga/Vol1.mokuro': mokuroLocal,
        '/remote/manga/Vol1/p001.jpg': pageA,
        '/remote/manga/Vol1/p002.jpg': pageB,
      });

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Remote Manga',
        mediaKind: 'manga',
        rootPath: '/remote/manga',
        transport: const Value('sftp'),
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source, fs: fs);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(books.single.title, 'RemoteManga');
      expect(books.single.format, 'manga');
      expect(books.single.sourceId, sid);
      expect(fs.copyToLocalCalls, 2,
          reason: 'both pages are mirrored before import');

      SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
      expect(after.lastScanError, isNull);

      // 重扫：标题预检命中已入库卷，零页图重下载、不重复导入、不算错误。
      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(after, fs: fs);
      });
      expect(await db.getAllEpubBooks(), hasLength(1));
      expect(fs.copyToLocalCalls, 2,
          reason: 're-scan must not re-download any page (title pre-check)');
      after = (await db.getMediaSourceById(sid))!;
      expect(after.lastScanError, isNull);
    });
  });
}
