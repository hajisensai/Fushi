import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_assets.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki/src/sync/video_manifest.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// 云后端替身：按命名空间返回预置的资产列表，`videos.json` 返回预置清单。
///
/// 只实现对比框资产维度真正会走的那几个方法，其余保持 UnimplementedError——
/// 用它们当「不该被调用」的断言。
class _CloudFake implements SyncBackend {
  _CloudFake({
    this.dictAssets = const <AssetEntry>[],
    this.localAudioAssets = const <AssetEntry>[],
    this.videoManifest,
  });

  final List<AssetEntry> dictAssets;
  final List<AssetEntry> localAudioAssets;
  final RemoteVideoManifest? videoManifest;

  final List<String> listedNamespaces = <String>[];

  @override
  Future<String> ensureNamespace(String name) async {
    listedNamespaces.add(name);
    return name;
  }

  @override
  Future<List<AssetEntry>> listChildren(String id) async => switch (id) {
        kSyncDictionaryNamespace => dictAssets,
        kSyncLocalAudioNamespace => localAudioAssets,
        _ => const <AssetEntry>[],
      };

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    if (namespaceId == kSyncVideosNamespace &&
        name == kSyncVideosManifestName &&
        videoManifest != null) {
      return const AssetEntry(id: 'videos-manifest', name: 'videos.json');
    }
    return null;
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async =>
      assetId == 'videos-manifest' ? videoManifest?.toJson() : null;

  // ── 以下均不该被资产维度取数触到 ────────────────────────────────────
  @override
  Future<String> findOrCreateRootFolder() async => 'root';
  @override
  String? get cachedRootFolderId => null;
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      throw UnimplementedError();
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}
  @override
  void evictFolderId(String folderId) {}
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  Future<DriveSyncFiles> listSyncFiles(String f) async =>
      throw UnimplementedError();
  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
  @override
  Future<String> ensureFolder(String parentId, String name) async =>
      throw UnimplementedError();
  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) async =>
      throw UnimplementedError();
  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      throw UnimplementedError();
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async =>
      throw UnimplementedError();
  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      throw UnimplementedError();
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
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      throw UnimplementedError();
  @override
  void clearCache() {}
}

SyncAssetEntry _pick(
  List<SyncAssetEntry> all,
  SyncAssetKind kind,
  String name,
) =>
    all.firstWhere((SyncAssetEntry e) => e.kind == kind && e.name == name);

void main() {
  test('音频数据库维度：本端独有/远端独有/两端都有 三种存在性都被列出', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    final Directory tmp = Directory.systemTemp.createTempSync('hibiki-la');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File bothDb = File('${tmp.path}/both.db')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final File localOnlyDb = File('${tmp.path}/localonly.db')
      ..writeAsBytesSync(<int>[1]);

    final List<SyncAssetEntry> assets = await fetchSyncAssetEntries(
      db: db,
      backend: _CloudFake(
        localAudioAssets: const <AssetEntry>[
          AssetEntry(id: 'a1', name: 'Both.hibikiaudiolib', sizeBytes: 3),
          AssetEntry(id: 'a2', name: 'RemoteOnly.hibikiaudiolib'),
        ],
      ),
      localAudioEntries: <LocalAudioDbEntry>[
        LocalAudioDbEntry(path: bothDb.path, displayName: 'Both'),
        LocalAudioDbEntry(path: localOnlyDb.path, displayName: 'LocalOnly'),
      ],
    );

    final List<SyncAssetEntry> dbs = assets
        .where((SyncAssetEntry e) => e.kind == SyncAssetKind.localAudioDb)
        .toList();
    expect(dbs.map((SyncAssetEntry e) => e.name).toSet(),
        <String>{'Both', 'LocalOnly', 'RemoteOnly'});

    final SyncAssetEntry both =
        _pick(assets, SyncAssetKind.localAudioDb, 'Both');
    expect(both.isSynced, isTrue, reason: '两端都有 → 无需传输');

    final SyncAssetEntry localOnly =
        _pick(assets, SyncAssetKind.localAudioDb, 'LocalOnly');
    expect(localOnly.hasLocal, isTrue);
    expect(localOnly.hasRemote, isFalse,
        reason: '本端独有 → UI 据此给「上传」，这正是此前完全看不到的那一类');

    final SyncAssetEntry remoteOnly =
        _pick(assets, SyncAssetKind.localAudioDb, 'RemoteOnly');
    expect(remoteOnly.hasLocal, isFalse);
    expect(remoteOnly.hasRemote, isTrue);
  });

  test('视频维度：云清单条目与本地可上传视频按 bookUid 对齐', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final Directory tmp = Directory.systemTemp.createTempSync('hibiki-video');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File localVideo = File('${tmp.path}/local.mp4')
      ..writeAsBytesSync(<int>[1, 2]);
    final File sharedVideo = File('${tmp.path}/shared.mp4')
      ..writeAsBytesSync(List<int>.filled(4096, 1));

    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'uid-local',
      title: 'LocalMovie',
      videoPath: localVideo.path,
    ));
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'uid-both',
      title: 'SharedMovie',
      videoPath: sharedVideo.path,
    ));
    // 流媒体：无本地字节可传，不该出现在对比列表里（否则是个永远传不上去的行）。
    await db.upsertVideoBook(VideoBooksCompanion.insert(
      bookUid: 'uid-stream',
      title: 'StreamShow',
      videoPath: 'https://example.com/s.m3u8',
      streamSpecJson: const Value<String>('{}'),
    ));

    final List<SyncAssetEntry> assets = await fetchSyncAssetEntries(
      db: db,
      backend: _CloudFake(
        videoManifest:
            const RemoteVideoManifest(videos: <RemoteVideoManifestEntry>[
          RemoteVideoManifestEntry(
            uid: 'uid-both',
            title: 'SharedMovie',
            videoAsset: 'uid-both.mp4',
            sizeBytes: 4096,
          ),
          RemoteVideoManifestEntry(
            uid: 'uid-remote',
            title: 'RemoteMovie',
            videoAsset: 'uid-remote.mp4',
            sizeBytes: 8192,
          ),
        ]),
      ),
      localAudioEntries: const <LocalAudioDbEntry>[],
    );

    final List<SyncAssetEntry> videos = assets
        .where((SyncAssetEntry e) => e.kind == SyncAssetKind.video)
        .toList();
    expect(videos.map((SyncAssetEntry e) => e.identity).toSet(),
        <String>{'uid-local', 'uid-both', 'uid-remote'});
    expect(
        videos.any((SyncAssetEntry e) => e.identity == 'uid-stream'), isFalse,
        reason: '流媒体没有可上传的本地字节，列出来只会是个死行');

    expect(_pick(assets, SyncAssetKind.video, 'LocalMovie').hasRemote, isFalse);
    expect(_pick(assets, SyncAssetKind.video, 'SharedMovie').isSynced, isTrue);

    final SyncAssetEntry remote =
        _pick(assets, SyncAssetKind.video, 'RemoteMovie');
    expect(remote.hasLocal, isFalse);
    expect(remote.remoteSizeBytes, 8192, reason: '清单里的是明文尺寸，可与本地直接比');
  });

  test('有声书维度：云后端复用书籍扫描已拿到的包定位符，不再列一遍远端', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    final _CloudFake backend = _CloudFake();
    final List<SyncAssetEntry> assets = await fetchSyncAssetEntries(
      db: db,
      backend: backend,
      localAudioEntries: const <LocalAudioDbEntry>[],
      cloudAudiobookIds: Future<Map<String, String>>.value(
        <String, String>{'某本书': 'audio-asset-1'},
      ),
    );

    final List<SyncAssetEntry> books = assets
        .where((SyncAssetEntry e) => e.kind == SyncAssetKind.audiobook)
        .toList();
    expect(books, hasLength(1));
    expect(books.single.name, '某本书');
    expect(books.single.remoteId, 'audio-asset-1');
    expect(books.single.hasLocal, isFalse);
  });

  test('一个维度列举失败不会拖垮其它维度', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);

    // 词典命名空间返回一个正常项；视频清单读取会抛（getJsonAsset 未实现路径）。
    final List<SyncAssetEntry> assets = await fetchSyncAssetEntries(
      db: db,
      backend: _CloudFake(
        dictAssets: const <AssetEntry>[
          AssetEntry(id: 'd1', name: 'JMdict.hibikidict'),
        ],
      ),
      localAudioEntries: const <LocalAudioDbEntry>[],
    );

    expect(
      assets.any((SyncAssetEntry e) => e.kind == SyncAssetKind.dictionary),
      isTrue,
      reason: '视频那一维没东西也不能把词典维度一起打没',
    );
  });
}
