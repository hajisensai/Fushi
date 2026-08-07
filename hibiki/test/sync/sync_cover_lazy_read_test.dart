import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-2657 ①：封面字节必须惰性读。
///
/// 每个后端的 `ensureBookFolder` 在书名→folderId 缓存命中时**直接 return**，封面
/// 根本用不上；旧实现却在调用前 `readAsBytesSync()` 读完整张封面图再丢弃，于是
/// 稳态下每本书每轮都白读一整张图。
///
/// 这里从两端钉死：
///  - `SyncManager` 侧：调用 `ensureBookFolder` **之前**不许碰磁盘（用「回调被调用
///    时封面文件才刚被创建」做判别器 —— eager 版只能读到 null）；
///  - 真后端侧（`InterconnectSyncBackend` 打真 `FushiSyncServer`）：cache-miss 那
///    轮的行为一字不变（封面照旧上传、字节逐字节一致），cache-hit 那轮回调一次都
///    不许被调用。

/// PNG magic header + 一点载荷，`detectCoverFormat` 会判成 `image/png` / `.png`。
final Uint8List _kCoverBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
]);

/// 模拟真后端形状的 fake：书名→folderId 缓存命中就早退（不碰封面回调），
/// 未命中才「新建文件夹 + 取封面上传」。
class _LazyCoverBackend implements SyncBackend {
  _LazyCoverBackend({this.onCacheMiss});

  /// cache-miss 分支在调用封面回调**之前**执行的副作用。
  final Future<void> Function()? onCacheMiss;

  final Map<String, String> _folders = <String, String>{};
  String? _root;

  /// 封面回调被调用的次数——稳态（缓存命中）必须保持不增。
  int coverProviderCalls = 0;

  /// 最近一次从回调取到的封面字节。
  Uint8List? lastCoverData;

  @override
  Future<String> findOrCreateRootFolder() async => _root ??= 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async {
    final String? cached = _folders[bookTitle];
    if (cached != null) return cached; // 缓存命中：封面回调一次都不碰。

    await onCacheMiss?.call();
    final String id = 'folder-$bookTitle';
    _folders[bookTitle] = id;
    if (readCoverData != null) {
      coverProviderCalls++;
      lastCoverData = await readCoverData();
    }
    return id;
  }

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio();

  @override
  void clearCache() {
    _root = null;
    _folders.clear();
  }

  @override
  void restoreCache({
    String? rootFolderId,
    Map<String, String>? titleToFolderId,
  }) {
    _root = rootFolderId;
    if (titleToFolderId != null) _folders.addAll(titleToFolderId);
  }

  @override
  String? get cachedRootFolderId => _root;

  @override
  Map<String, String> get cachedFolderIds =>
      Map<String, String>.unmodifiable(_folders);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<EpubBookRow> _insertBook(
  FushiDatabase db, {
  required String title,
  required String coverPath,
}) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    bookKey: title,
    title: title,
    epubPath: '/fake/$title.epub',
    extractDir: '/fake/$title',
    chapterCount: 1,
    chaptersJson: '[]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
    coverPath: Value<String?>(coverPath),
  ));
  return (await db.getAllEpubBooks()).firstWhere((r) => r.title == title);
}

void main() {
  test('SyncManager reads the cover only when the backend asks for it',
      () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('hibiki_cover_lazy_');
    addTearDown(() => tempDir.delete(recursive: true));
    final File coverFile = File('${tempDir.path}/cover.png');

    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final EpubBookRow book =
        await _insertBook(db, title: 'Book', coverPath: coverFile.path);

    // 判别器：封面文件在 syncBook 调用时**还不存在**，只有在后端进到 cache-miss
    // 分支、正要取封面的那一刻才被写出来。旧的 eager 版在 ensureBookFolder 之前
    // 就 readAsBytesSync 了，那时文件不存在 → 只能拿到 null。
    final backend = _LazyCoverBackend(
      onCacheMiss: () => coverFile.writeAsBytes(_kCoverBytes),
    );
    final SyncManager manager = SyncManager(db: db, backend: backend);

    expect(coverFile.existsSync(), isFalse);
    await manager.syncBook(
      book: book,
      syncStats: false,
      statsSyncMode: StatisticsSyncMode.merge,
      syncAudioBook: false,
    );

    expect(backend.coverProviderCalls, 1, reason: 'cache-miss 分支必须照旧拿到封面');
    expect(backend.lastCoverData, _kCoverBytes,
        reason: '惰性读必须读到回调触发时刻的真实文件内容；'
            '预读实现只会读到 null（那时文件还没被创建）');
  });

  test('a cached book folder triggers no cover read at all', () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('hibiki_cover_lazy_hit_');
    addTearDown(() => tempDir.delete(recursive: true));
    final File coverFile = File('${tempDir.path}/cover.png');
    await coverFile.writeAsBytes(_kCoverBytes);

    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final EpubBookRow book =
        await _insertBook(db, title: 'Book', coverPath: coverFile.path);

    final backend = _LazyCoverBackend();
    final SyncManager manager = SyncManager(db: db, backend: backend);

    for (int round = 0; round < 3; round++) {
      await manager.syncBook(
        book: book,
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );
    }

    // 第 1 轮 cache-miss 读一次，第 2/3 轮缓存命中一次都不读。
    expect(backend.coverProviderCalls, 1, reason: '缓存命中的书不许再读封面图');
  });

  test(
      'InterconnectSyncBackend: cache miss still uploads the cover, '
      'cache hit never reads it', () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('hibiki_cover_p2p_');
    addTearDown(() => tempDir.delete(recursive: true));
    await Directory('${tempDir.path}/sync-data').create(recursive: true);

    final String token = FushiSyncServer.generateToken();
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: tempDir.path,
      port: 0,
      token: token,
      allowLan: false,
    );
    await server.start();
    addTearDown(server.stop);

    final FushiDatabase db =
        FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}'),
    ]);
    await repo.setFushiClientToken(token);

    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    backend.clearCache();
    addTearDown(backend.clearCache);
    expect(await backend.restoreAuth(repo), isTrue);

    final String root = await backend.findOrCreateRootFolder();
    int reads = 0;
    Future<Uint8List?> readCover() async {
      reads++;
      return _kCoverBytes;
    }

    // ── cache miss：行为一字不变，封面照旧真上传 ──
    final String folder = await backend.ensureBookFolder(
      bookTitle: 'CoverBook',
      rootFolderId: root,
      readCoverData: readCover,
    );
    expect(reads, 1);

    final SyncFileRef? uploaded =
        await backend.findContentFile(folder, 'cover_1_6.png');
    expect(uploaded, isNotNull, reason: 'cache-miss 分支必须仍然上传封面');
    final File dest = File('${tempDir.path}/downloaded.png');
    await backend.downloadContentFile(fileId: uploaded!.id, destination: dest);
    expect(await dest.readAsBytes(), _kCoverBytes,
        reason: '上传的封面字节必须与回调返回的逐字节一致');

    // ── cache hit：回调一次都不许被调用 ──
    final String folder2 = await backend.ensureBookFolder(
      bookTitle: 'CoverBook',
      rootFolderId: root,
      readCoverData: readCover,
    );
    expect(folder2, folder);
    expect(reads, 1, reason: '缓存命中的快路径不许触碰封面回调');
  });
}
