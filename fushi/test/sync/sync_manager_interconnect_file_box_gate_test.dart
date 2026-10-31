// 互联文件箱只有本 client 写、host 从不读回（书内容走 live 端点）：单本同步路径（退出书 /
// 对比弹窗）照样传 syncContent，SyncManager 必须自己拦住，不能把 EPUB / sidecar 推进
// host 上没人读的文件箱。补缺书文件（PR #2406）后这条门尤其要紧：否则每次退出书都探针、
// 缺了就整本上传。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_manager.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_engine/sync/ttu_models.dart';
import 'package:path/path.dart' as p;

const String _title = 'Interconnect Box Book';

class _FileBoxBackend extends InterconnectSyncBackend {
  _FileBoxBackend() : super.withProbe((String url, String token) async => true);

  int contentProbes = 0;
  int contentUploads = 0;
  int folderListings = 0;
  final List<String> jsonWrites = <String>[];
  int progressWrites = 0;

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    SyncCoverDataProvider? readCoverData,
  }) async => 'folder';

  @override
  Future<SyncFileTrio> listSyncFiles(String folderId) async =>
      const SyncFileTrio();

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    progressWrites++;
  }

  @override
  Future<SyncFileRef?> findContentFile(String folderId, String fileName) async {
    contentProbes++;
    return null;
  }

  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    SyncTransferProgress? onProgress,
  }) async {
    contentUploads++;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    folderListings++;
    return const <AssetEntry>[];
  }

  @override
  Future<void> putJsonAsset(
    String namespaceId,
    String name,
    Object? json,
  ) async {
    jsonWrites.add(name);
  }
}

void main() {
  late FushiDatabase db;
  late Directory tmp;
  late EpubBookRow book;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    tmp = await Directory.systemTemp.createTemp('fushi_ic_file_box');
    final File opf = File(p.join(tmp.path, 'extracted', 'content.opf'));
    await opf.parent.create(recursive: true);
    await opf.writeAsString('<package/>');
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: sanitizeTtuFilename(_title),
        title: _title,
        epubPath: p.join(tmp.path, 'original.epub'),
        extractDir: opf.parent.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    book = (await db.getAllEpubBooks()).single;
    final int tagId = await db.getOrCreateTagByName('Local tag');
    await db.addTagToBook(book.bookKey, tagId);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  for (final bool exporting in <bool>[false, true]) {
    test('interconnect file box gets no book content or sidecars '
        '(${exporting ? 'progress export' : 'unread book'})', () async {
      if (exporting) {
        await db.upsertReaderPosition(
          ReaderPositionsCompanion(
            bookUid: Value(book.uid),
            sectionIndex: const Value(0),
            normCharOffset: const Value(5000),
            updatedAt: const Value(120),
          ),
        );
      }
      final _FileBoxBackend backend = _FileBoxBackend();
      expect(
        syncChannelScopeOf(backend),
        SyncChannelScope.forBackendType(SyncBackendType.fushiServer),
        reason: 'precondition: this backend is the interconnect channel',
      );

      final SyncBookResult result = await SyncManager(db: db, backend: backend)
          .syncBook(
            book: book,
            syncStats: false,
            statsSyncMode: StatisticsSyncMode.merge,
            syncAudioBook: false,
            syncContent: true,
          );

      expect(result.error, isNull);
      expect(result.contentError, isNull);
      if (exporting) {
        expect(result.direction, SyncResult.exported);
        expect(backend.progressWrites, 1);
      }
      expect(backend.contentProbes, 0);
      expect(backend.contentUploads, 0);
      expect(backend.folderListings, 0);
      expect(backend.jsonWrites, isEmpty);
    });
  }
}
