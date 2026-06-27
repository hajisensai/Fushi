/// Task T3.4：orchestrator 音频 live 同步集成测试。
///
/// 用例 A：互联（HibikiClientSyncBackend）+ syncLocalAudio=true
///   → 本地音频经 live 端点双向（pull/push），不经 `__local_audio__` 暂存路径。
/// 用例 B：互联 + syncAudioBookFiles=true
///   → 有声书包经 live 端点上传本端独有包，不自动拉取远端独有包，
///     也不经 `audiobook.hibikiaudio` 书文件夹暂存。
/// 用例 C：互联 + 开关关（syncLocalAudio=false / syncAudioBookFiles=false）
///   → 对应 live 方法不被调用（计数器=0）。
/// 用例 D：云后端（非 HibikiClientSyncBackend）
///   → 仍走原 syncLocalAudioPackages / syncAudiobookPackages（__local_audio__ 路径）。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_storage.dart' show EpubStorage;
import 'package:hibiki/src/models/local_audio_manager.dart'
    show LocalAudioDbEntry;
import 'package:hibiki/src/models/local_audio_source_pref.dart'
    show LocalAudioSourcePref;
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';

// ── helpers ───────────────────────────────────────────────────────────────────

HibikiDatabase _memDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 在 host [db] 里植入一本「带内容」的 EPUB：把一个 [EpubImporter] 能真正解析的
/// 最小 EPUB 结构（mimetype + container.xml + content.opf + 一个 xhtml 章节）写入
/// [extractDir]，并插入 EpubBooks 行。host 的 `exportBook` 会把该目录重打包成 .epub
/// 供 `getRemoteBook` 下载，client 再走真实 `EpubImporter.importFromPath` 导入。
Future<void> _seedHostBookWithContent({
  required HibikiDatabase db,
  required String title,
  required String bookKey,
  required String extractDir,
}) async {
  Directory(extractDir).createSync(recursive: true);
  File(p.join(extractDir, 'mimetype'))
      .writeAsStringSync('application/epub+zip');
  final Directory metaInf = Directory(p.join(extractDir, 'META-INF'))
    ..createSync();
  File(p.join(metaInf.path, 'container.xml')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  File(p.join(extractDir, 'content.opf')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''');
  File(p.join(extractDir, 'chapter.xhtml')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>Hello.</p></body>
</html>
''');

  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      epubPath: p.join(extractDir, 'original.epub'),
      extractDir: extractDir,
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ),
  );
}

/// 构造并认证一个 [HibikiClientSyncBackend]，fake probe 总返回 true。
Future<HibikiClientSyncBackend> _buildClientBackend({
  required String base,
  required String token,
}) async {
  final HibikiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(<HibikiClientUrl>[
    HibikiClientUrl(url: base, enabled: true),
  ]);
  await repo.setHibikiClientToken(token);
  final HibikiClientSyncBackend backend =
      HibikiClientSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

/// 构造只开 syncLocalAudio 或 syncAudioBookFiles 的 orchestrator。
SyncOrchestrator _audioOrchestrator({
  required HibikiDatabase db,
  required SyncBackend backend,
  required Directory tmp,
  bool syncLocalAudio = false,
  bool syncAudioBookFiles = false,
  List<LocalAudioDbEntry> localAudioEntries = const <LocalAudioDbEntry>[],
  Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported,
}) =>
    SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: tmp,
      audioDatabaseRoot: tmp,
      tempDir: tmp,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncAudioBookFiles: syncAudioBookFiles,
      syncDictionary: false,
      syncLocalAudio: syncLocalAudio,
      localAudioEntries: localAudioEntries,
      onLocalAudioImported: onLocalAudioImported,
    );

// ── Fake staged backend（云路径用）────────────────────────────────────────────

class _FakeSyncBackend implements SyncBackend {
  _FakeSyncBackend(this._store);
  final FakeAssetStore _store;

  int ensureNamespaceCalled = 0;

  @override
  Future<String> ensureNamespace(String name) {
    ensureNamespaceCalled++;
    return _store.ensureNamespace(name);
  }

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _store.ensureFolder(parentId, name);
  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) =>
      _store.listChildren(namespaceId);
  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) =>
      _store.findAsset(namespaceId, name);
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) =>
      _store.putAsset(namespaceId, name, file, onProgress: onProgress);
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) =>
      _store.getAsset(assetId, destination, onProgress: onProgress);
  @override
  Future<Object?> getJsonAsset(String assetId) => _store.getJsonAsset(assetId);
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _store.putJsonAsset(namespaceId, name, json);
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _store.deleteAsset(id, isFolder: isFolder);
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) =>
      _store.ensureFolder(rootFolderId, bookTitle);
  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async =>
      const DriveSyncFiles(progress: null, statistics: null, audioBook: null);
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      const <DriveFile>[];
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async {}
  @override
  Future<void> signOut({required SyncRepository repo}) async {}
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {}
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {}
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {}
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async {}
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      null;
  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => 'root';
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  @override
  void evictFolderId(String folderId) {}
}

// ── main ──────────────────────────────────────────────────────────────────────

void main() {
  // 这些用例跑真实 HibikiSyncServer（真 socket），故**不能**初始化
  // TestWidgetsFlutterBinding（它会把所有 HttpClient 请求拦成 HTTP 400）。
  // 用例 B2 的 client 侧真实 EpubImporter 需要书籍存储基目录，而 path_provider
  // 在无 binding 时不可用 → 改用 EpubStorage.debugBaseDirectoryOverride 注入。
  late Directory work;
  late Directory epubBaseDir;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('orch_live_audio_');
    epubBaseDir =
        await Directory.systemTemp.createTemp('orch_live_audio_epub_base_');
    EpubStorage.debugBaseDirectoryOverride = epubBaseDir.path;
  });
  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    if (work.existsSync()) await work.delete(recursive: true);
    try {
      if (epubBaseDir.existsSync()) await epubBaseDir.delete(recursive: true);
    } catch (_) {}
  });

  // ── 用例 A：互联 live + syncLocalAudio=true ──────────────────────────────

  group('用例A: 互联 live 路径（syncLocalAudio=true）', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    late String serverBase;
    const String token = 'orch-live-audio-token';

    /// host 上植入一个本地音频来源 "NHK ラジオ"（fake .db 文件 + LocalAudioDbEntry）。
    late Directory hostAudioDir;
    late File hostDbFile;

    setUp(() async {
      hostDb = _memDb();

      // 准备 host 音频文件：exportLocalAudio 需要一个存在的文件（exportLocalAudioPackage
      // 只 zip 文件内容，不解析 SQLite 格式）。写入最小 SQLite 文件头即可。
      hostAudioDir = Directory(p.join(work.path, 'host_audio'))
        ..createSync(recursive: true);
      hostDbFile = File(p.join(hostAudioDir.path, 'nhk_radio.db'));
      // SQLite 文件头 magic（前 16 字节）：足以让文件非空并通过 existsSync 检查。
      hostDbFile.writeAsBytesSync(
        <int>[
          0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite f"
          0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00
        ], // "ormat 3\0"
      );

      final List<LocalAudioDbEntry> hostEntries = <LocalAudioDbEntry>[
        LocalAudioDbEntry(
          path: hostDbFile.path,
          displayName: 'NHK ラジオ',
          enabled: true,
          sources: const <LocalAudioSourcePref>[],
        ),
      ];

      final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        localAudioEntries: hostEntries,
        localAudioStagingDir: Directory(work.path),
        onLocalAudioImported: (LocalAudioPackageContents c) async {},
      );

      server = HibikiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: libSvc,
      );
      await server.start();
      serverBase = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    test('pull：本地无 NHK ラジオ，syncLocalAudio=true → 拉取并注册，localAudioImported=1',
        () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      final Directory tmp = Directory(p.join(work.path, 'tmp_pull'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final List<String> imported = <String>[];
      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncLocalAudio: true,
        localAudioEntries: const <LocalAudioDbEntry>[], // 本地无音频来源
        onLocalAudioImported: (LocalAudioPackageContents c) async {
          imported.add(c.displayName);
        },
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncLocalAudioLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'live pull local audio 无错误: ${report.errors}');
      expect(report.localAudioImported, 1, reason: 'NHK ラジオ 应从 host pull 并注册');
      expect(imported, contains('NHK ラジオ'),
          reason: 'onLocalAudioImported 应被调用');
    });

    test('push：本地有 Local ライブラリ，host 无 → 推送到 host', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      // 本地音频来源：写最小 SQLite 文件头（exportLocalAudioPackage 只 zip，不解析）
      final Directory localAudioDir =
          Directory(p.join(work.path, 'local_audio'))..createSync();
      final File localDbFile = File(p.join(localAudioDir.path, 'local_lib.db'));
      localDbFile.writeAsBytesSync(<int>[
        0x53,
        0x51,
        0x4c,
        0x69,
        0x74,
        0x65,
        0x20,
        0x66,
        0x6f,
        0x72,
        0x6d,
        0x61,
        0x74,
        0x20,
        0x33,
        0x00
      ]);

      final List<LocalAudioDbEntry> localEntries = <LocalAudioDbEntry>[
        LocalAudioDbEntry(
          path: localDbFile.path,
          displayName: 'Local ライブラリ',
          enabled: true,
          sources: const <LocalAudioSourcePref>[],
        ),
      ];

      final Directory tmp = Directory(p.join(work.path, 'tmp_push'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncLocalAudio: true,
        localAudioEntries: localEntries,
        onLocalAudioImported: (LocalAudioPackageContents c) async {},
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncLocalAudioLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'live push local audio 无错误: ${report.errors}');
      expect(report.localAudioExported, 1, reason: 'Local ライブラリ 应被推送到 host');
    });

    test('live 路径不经 __local_audio__ 暂存目录（服务端 sync-data 下无该目录）', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      final Directory tmp = Directory(p.join(work.path, 'tmp_no_staging'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncLocalAudio: true,
        localAudioEntries: const <LocalAudioDbEntry>[],
        onLocalAudioImported: (LocalAudioPackageContents c) async {},
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncLocalAudioLiveForTest(report, backend);

      // live 路径绕过暂存：server sync-data 目录下不应出现 __local_audio__ 目录。
      final String syncDataDir = p.join(work.path, 'server_data', 'sync-data');
      if (Directory(syncDataDir).existsSync()) {
        final List<FileSystemEntity> children =
            Directory(syncDataDir).listSync();
        final bool hasLocalAudioFolder = children.any(
          (FileSystemEntity e) =>
              e is Directory && p.basename(e.path) == '__local_audio__',
        );
        expect(hasLocalAudioFolder, isFalse,
            reason: 'live 路径不应在 sync-data 下创建 __local_audio__ 暂存目录');
      }
      expect(report.errors, isEmpty);
    });
  });

  // ── 用例 B：互联 live + syncAudioBookFiles=true（上传语义）───────────────

  group('用例B: 互联 live 上传路径（syncAudioBookFiles=true）', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    late String serverBase;
    const String token = 'orch-live-audiobook-token';

    setUp(() async {
      hostDb = _memDb();

      // host 上植入一本有声书（Audiobooks + SrtBooks 行 + 空音频目录）。
      final Directory hostAudioRoot =
          Directory(p.join(work.path, 'host_audiobook_root'))
            ..createSync(recursive: true);

      // 先插入书籍行（audiobook 需要对应的 epub_books 行）
      await hostDb.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'HostAudioBook',
          title: 'Host Audio Book',
          epubPath: p.join(work.path, 'host_audio.epub'),
          extractDir: '',
          chapterCount: 1,
          chaptersJson: '["ch1"]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      // 准备最小 SRT 文件（SrtBook srtPath 需要真实路径）
      final File hostSrtFile = File(p.join(work.path, 'host_audio.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\ntest\n');

      // 插入 SrtBook
      await hostDb.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'uid-host-srt-1',
          title: 'Host Audio Book',
          srtPath: hostSrtFile.path,
          importedAt: DateTime.now().millisecondsSinceEpoch,
          bookKey: const Value('HostAudioBook'),
          audioRoot: Value(hostAudioRoot.path),
        ),
      );

      // 插入 Audiobook
      await hostDb.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: 'HostAudioBook',
          audioRoot: Value(hostAudioRoot.path),
          alignmentFormat: 'srt',
          alignmentPath: hostSrtFile.path,
        ),
      );

      final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        audioDatabaseRoot: hostAudioRoot,
        onLocalAudioImported: (LocalAudioPackageContents c) async {},
      );

      server = HibikiSyncServer(
        syncDataDir: p.join(work.path, 'server_data_b'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: libSvc,
      );
      await server.start();
      serverBase = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    test('本地无 HostAudioBook 有声书 → 不自动拉取远端独有有声书', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      final Directory tmp = Directory(p.join(work.path, 'tmp_ab_pull'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncAudioBookFiles: true,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncAudiobooksLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'live audiobook upload 无错误: ${report.errors}');
      expect(report.audiobooksImported, 0,
          reason: 'Upload audiobook files 不能把远端独有有声书自动拉到本机');
      expect(await localDb.getAudiobookByBookKey('HostAudioBook'), isNull);
    });

    test(
        'pull（TODO-809）：本地有 HostAudioBook 的 EPUB 但缺音频，host 有 → '
        '双向拉取下载并解包落盘', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      // 本地已有同 bookKey 的 EPUB 书行，但没有 Audiobook/SrtBook（缺音频）。
      // 这是 toPull 唯一应动作的场景：有书可绑，不会落孤儿有声书行。
      await localDb.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'HostAudioBook',
          title: 'Host Audio Book',
          epubPath: p.join(work.path, 'local_host_audio.epub'),
          extractDir: '',
          chapterCount: 1,
          chaptersJson: '["ch1"]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      expect(await localDb.getAudiobookByBookKey('HostAudioBook'), isNull,
          reason: '前置：本地此时缺音频');

      final Directory tmp = Directory(p.join(work.path, 'tmp_ab_pull_ok'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncAudioBookFiles: true,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncAudiobooksLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'live pull audiobook 无错误: ${report.errors}');
      expect(report.audiobooksImported, 1,
          reason: 'host 独有有声书且本地有同 bookKey EPUB → 应被拉取导入');
      expect(report.booksImported, 0,
          reason: '场景B：本地已有 EPUB → 只补音频，绝不重导 EPUB（TODO-873 守护绿路径）');
      expect(await localDb.getAudiobookByBookKey('HostAudioBook'), isNotNull,
          reason: '拉取后本地应出现 HostAudioBook 的 Audiobook 行');
    });

    test('push：本地有 LocalAudioBook 有声书，host 无 → 推送到 host', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      // 插入本地有声书（本地独有，host 不含此 bookKey）
      final Directory localAudioRoot =
          Directory(p.join(work.path, 'local_audiobook_root'))
            ..createSync(recursive: true);

      await localDb.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'LocalAudioBook',
          title: 'Local Audio Book',
          epubPath: p.join(work.path, 'local_audio.epub'),
          extractDir: '',
          chapterCount: 1,
          chaptersJson: '["ch1"]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final File localSrtFile = File(p.join(work.path, 'local_audio.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\ntest\n');

      await localDb.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'uid-local-srt-1',
          title: 'Local Audio Book',
          srtPath: localSrtFile.path,
          importedAt: DateTime.now().millisecondsSinceEpoch,
          bookKey: const Value('LocalAudioBook'),
          audioRoot: Value(localAudioRoot.path),
        ),
      );
      await localDb.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: 'LocalAudioBook',
          audioRoot: Value(localAudioRoot.path),
          alignmentFormat: 'srt',
          alignmentPath: localSrtFile.path,
        ),
      );

      final Directory tmp = Directory(p.join(work.path, 'tmp_ab_push'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncAudioBookFiles: true,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncAudiobooksLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'live push audiobook 无错误: ${report.errors}');
      expect(report.audiobooksExported, 1,
          reason: 'LocalAudioBook 有声书应被推送到 host');
    });
  });

  // ── 用例 B2：互联 live + 远端-only 带有声书自动灌 EPUB+音频（TODO-873）───

  group('用例B2: 远端-only 带有声书 → 自动下载 EPUB+音频（TODO-873）', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    late String serverBase;
    const String token = 'orch-live-remote-only-token';

    // host 端书名/bookKey：纯 ASCII，sanitizeTtuFilename 不变形，
    // client 导入后 localBookKey 与 host audiobook bookKey 一致（徽章配对硬保证）。
    const String remoteOnlyTitle = 'Remote Only Audio Book';
    const String remoteOnlyKey = 'Remote Only Audio Book';
    // host 上一本纯文本远端书（无有声书）——回归边界用，不应被自动灌。
    const String textOnlyTitle = 'Remote Text Only Book';
    const String textOnlyKey = 'Remote Text Only Book';

    setUp(() async {
      hostDb = _memDb();

      final Directory hostAudioRoot =
          Directory(p.join(work.path, 'host_b2_audio_root'))
            ..createSync(recursive: true);

      // ① 带有声书的远端-only 书：有内容 EPUB + Audiobook/SrtBook 行。
      await _seedHostBookWithContent(
        db: hostDb,
        title: remoteOnlyTitle,
        bookKey: remoteOnlyKey,
        extractDir: p.join(work.path, 'host_b2_extract'),
      );
      final File hostSrt = File(p.join(work.path, 'host_b2.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\ntest\n');
      await hostDb.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'uid-b2-srt-1',
          title: remoteOnlyTitle,
          srtPath: hostSrt.path,
          importedAt: DateTime.now().millisecondsSinceEpoch,
          bookKey: const Value(remoteOnlyKey),
          audioRoot: Value(hostAudioRoot.path),
        ),
      );
      await hostDb.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: remoteOnlyKey,
          audioRoot: Value(hostAudioRoot.path),
          alignmentFormat: 'srt',
          alignmentPath: hostSrt.path,
        ),
      );

      // ② 纯文本远端-only 书：有内容 EPUB，但无 Audiobook → 不进 listRemoteAudiobooks。
      await _seedHostBookWithContent(
        db: hostDb,
        title: textOnlyTitle,
        bookKey: textOnlyKey,
        extractDir: p.join(work.path, 'host_b2_text_extract'),
      );

      final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        audioDatabaseRoot: hostAudioRoot,
        onLocalAudioImported: (LocalAudioPackageContents c) async {},
      );

      server = HibikiSyncServer(
        syncDataDir: p.join(work.path, 'server_data_b2'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: libSvc,
      );
      await server.start();
      serverBase = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    test(
        '远端-only 带有声书 → sweep 后本地有 EpubBooks + Audiobooks 行，'
        '且 Audiobooks.bookKey == 本地 EpubBooks.bookKey（徽章配对硬断言）', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      // 前置：本地完全没有这本书。
      expect(await localDb.getAllEpubBooks(), isEmpty);

      final Directory tmp = Directory(p.join(work.path, 'tmp_b2_full'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncAudioBookFiles: true,
      );
      final SyncRunReport report = SyncRunReport();
      // 无 widget binding（保真 socket），真实事件循环直接推进 EpubImporter
      // 的 compute + 文件 IO，无需 runAsync。
      await orch.syncAudiobooksLiveForTest(report, backend);

      expect(report.errors, isEmpty,
          reason: 'remote-only full book sync 无错误: ${report.errors}');
      expect(report.booksImported, greaterThanOrEqualTo(1),
          reason: '远端-only 带有声书的 EPUB 应被自动拉入书架');
      expect(report.audiobooksImported, greaterThanOrEqualTo(1),
          reason: '远端-only 书的音频包应被自动拉取导入');

      final List<EpubBookRow> localBooks = await localDb.getAllEpubBooks();
      expect(
          localBooks.map((EpubBookRow b) => b.title), contains(remoteOnlyTitle),
          reason: 'EPUB 应落本地书架');

      final List<AudiobookRow> localAudiobooks =
          await localDb.getAllAudiobooks();
      expect(localAudiobooks, isNotEmpty, reason: '本地应出现 Audiobooks 行（徽章亮的前提）');

      // 徽章配对硬保证：Audiobooks 行的 bookKey 必须等于本地 EPUB 行的 bookKey，
      // 否则书架显示成普通书（症状① 直接回归点）。
      final EpubBookRow importedBook =
          localBooks.firstWhere((EpubBookRow b) => b.title == remoteOnlyTitle);
      expect(
        localAudiobooks
            .any((AudiobookRow a) => a.bookKey == importedBook.bookKey),
        isTrue,
        reason: 'Audiobooks.bookKey 必须与本地 EpubBooks.bookKey 配对，'
            '否则书架徽章退化为普通书',
      );
      expect(
          await localDb.getAudiobookByBookKey(importedBook.bookKey), isNotNull,
          reason: '按本地 EPUB bookKey 应能查到 Audiobook 行');
    });

    test('回归：远端-only 纯文本书（无有声书）→ sweep 后本地仍无此书（守边界）', () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      final Directory tmp = Directory(p.join(work.path, 'tmp_b2_text'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncAudioBookFiles: true,
      );
      final SyncRunReport report = SyncRunReport();
      await orch.syncAudiobooksLiveForTest(report, backend);

      expect(report.errors, isEmpty, reason: '无错误: ${report.errors}');
      // 带有声书的书会被灌（booksImported>=1），但纯文本远端书绝不应进本地。
      final List<EpubBookRow> localBooks = await localDb.getAllEpubBooks();
      expect(
        localBooks.map((EpubBookRow b) => b.title),
        isNot(contains(textOnlyTitle)),
        reason: '纯文本远端书（不在 listRemoteAudiobooks）不应被自动灌',
      );
    });
  });

  // ── 用例 C：互联 + 开关关 ────────────────────────────────────────────────

  group('用例C: 互联 + 开关关（syncLocalAudio=false / syncAudioBookFiles=false）', () {
    late HibikiSyncServer server;
    late HibikiDatabase hostDb;
    late String serverBase;
    const String token = 'orch-live-audio-off-token';

    setUp(() async {
      hostDb = _memDb();
      // host 无需真实数据，只要 server 能响应
      final AppModelLibraryHostService libSvc = AppModelLibraryHostService(
        db: hostDb,
        dictionaryResourceRoot: Directory(work.path),
        packages: SyncAssetPackageService(db: hostDb),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        onLocalAudioImported: (LocalAudioPackageContents c) async {
          fail('onLocalAudioImported 不应在开关关时被调用');
        },
      );
      server = HibikiSyncServer(
        syncDataDir: p.join(work.path, 'server_data_c'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: libSvc,
      );
      await server.start();
      serverBase = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.stop());

    test(
        'syncLocalAudio=false → run() 不触发本地音频传输（localAudioImported=0, localAudioExported=0）',
        () async {
      final HibikiDatabase localDb = _memDb();
      addTearDown(localDb.close);

      final Directory tmp = Directory(p.join(work.path, 'tmp_c_audio'))
        ..createSync();
      final HibikiClientSyncBackend backend =
          await _buildClientBackend(base: serverBase, token: token);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: localDb,
        backend: backend,
        tmp: tmp,
        syncLocalAudio: false,
        syncAudioBookFiles: false,
        onLocalAudioImported: (LocalAudioPackageContents c) async {
          fail('onLocalAudioImported 不应在 syncLocalAudio=false 时被调用');
        },
      );
      final SyncRunReport report = await orch.run();

      expect(report.localAudioImported, 0,
          reason: 'syncLocalAudio=false 不应传输本地音频');
      expect(report.localAudioExported, 0);
      expect(report.audiobooksImported, 0,
          reason: 'syncAudioBookFiles=false 不应传输有声书');
      expect(report.audiobooksExported, 0);
      expect(report.errors, isEmpty, reason: '无错误: ${report.errors}');
    });
  });

  // ── 用例 D：云后端走原 syncLocalAudioPackages 路径 ───────────────────────

  group('用例D: 云后端（非 HibikiClient）走 __local_audio__ 暂存路径', () {
    test(
        'FakeSyncBackend + syncLocalAudio=true → 调用 ensureNamespace(__local_audio__)，不走 live 端点',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final _FakeSyncBackend backend = _FakeSyncBackend(store);
      final Directory tmp = Directory(p.join(work.path, 'tmp_d'))..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      final SyncOrchestrator orch = _audioOrchestrator(
        db: db,
        backend: backend,
        tmp: tmp,
        syncLocalAudio: true,
        localAudioEntries: const <LocalAudioDbEntry>[],
        onLocalAudioImported: (LocalAudioPackageContents c) async {},
      );
      final SyncRunReport report = await orch.run();

      // 云路径：ensureNamespace 被调用（__local_audio__ 命名空间）。
      expect(backend.ensureNamespaceCalled, greaterThanOrEqualTo(1),
          reason: '云后端路径应调用 ensureNamespace(__local_audio__)');
      expect(report.errors, isEmpty, reason: '云后端路径运行无错误: ${report.errors}');
    });

    test(
        'FakeSyncBackend + syncAudioBookFiles=true → 调用 ensureBookFolder，不走 live 端点',
        () async {
      final FakeAssetStore store = FakeAssetStore();
      final _FakeSyncBackend backend = _FakeSyncBackend(store);
      final Directory tmp = Directory(p.join(work.path, 'tmp_d2'))
        ..createSync();
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // 无本地有声书，syncAudiobookPackages 扫 getAllEpubBooks 返空列表 → 无传输
      final SyncOrchestrator orch = _audioOrchestrator(
        db: db,
        backend: backend,
        tmp: tmp,
        syncAudioBookFiles: true,
      );
      final SyncRunReport report = await orch.run();

      // 云路径：root folder 被请求（syncAudiobookPackages 需要 root）。
      // 不走 live 端点（_FakeSyncBackend 没有 listRemoteAudiobooks，调用会抛）。
      expect(report.audiobooksImported, 0);
      expect(report.audiobooksExported, 0);
      expect(report.errors, isEmpty,
          reason: '云后端 audiobook 路径运行无错误: ${report.errors}');
    });
  });
}
