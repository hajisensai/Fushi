/// BUG-4432：对比弹窗互联书进度的「应用」按用户**在这一行看到的** host 值落地。
/// 真 [FushiSyncServer] + [LocalLibraryHostService] + 真 [InterconnectSyncBackend]：
/// 加载对比数据后 host 被第三台设备改写——选本地不得覆盖那个用户没见过的新值，
/// 选远端也不得把它落回本机；该行结果是 noop（下一轮按新事实重判）。
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

import '../helpers/interconnect_legacy_host_scope.dart';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _bookKey = 'CmpRevalidate';

Future<void> _seedBook(FushiDatabase db) => db.insertEpubBook(
  EpubBooksCompanion.insert(
    bookKey: _bookKey,
    title: _bookKey,
    epubPath: '/tmp/$_bookKey.epub',
    extractDir: '/tmp/$_bookKey',
    chapterCount: 1,
    chaptersJson: '[{"characters":1000}]',
    importedAt: 1,
  ),
);

RemoteBookProgress _progress(int norm, int at) => RemoteBookProgress(
  sectionIndex: 0,
  normCharOffset: norm,
  charOffset: norm,
  updatedAtMs: at,
);

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late LocalLibraryHostService host;
  late FushiDatabase clientDb;
  late InterconnectSyncBackend backend;
  const String token = 'cmp-revalidate-token';

  setUp(() async {
    work = await Directory.systemTemp.createTemp('cmp_revalidate_');
    hostDb = _memDb();
    host = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: host,
    );
    await server.start();
    clientDb = _memDb();
    final SyncRepository repo = SyncRepository(clientDb);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:${server.port}', enabled: true),
    ]);
    await repo.setFushiClientToken(token);
    backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
  });

  tearDown(() async {
    await server.stop();
    await hostDb.close();
    await clientDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  /// 基线 1000、本机 3000、host 5000：两端都偏离基线 → 冲突行，用户看到 host = 5000。
  /// 加载之后第三台设备把 host 推到 8000。返回加载时的条目。
  Future<List<SyncCompareEntry>> loadThenHostMoves(int now) async {
    await _seedBook(hostDb);
    await _seedBook(clientDb);
    final EpubBookRow book = (await clientDb.getEpubBook(_bookKey))!;
    await clientDb.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value(book.uid),
        sectionIndex: const Value(0),
        normCharOffset: const Value(3000),
        charOffset: const Value(3000),
        updatedAt: Value(now - 2000),
      ),
    );
    await clientDb.setSyncBaseline(
      _bookKey,
      kInterconnectBookProgressDimension,
      const BookProgressBaseline(
        sectionIndex: 0,
        normCharOffset: 1000,
      ).encode(),
    );
    await host.putBookProgress(_bookKey, _progress(5000, now - 1000));

    final List<SyncCompareEntry> entries = await fetchCompareDataForTest(
      clientDb,
      backend,
    );
    final SyncCompareEntry row = entries.singleWhere(
      (SyncCompareEntry e) => e.bookKey == _bookKey,
    );
    expect(row.liveAction, BookProgressSyncAction.conflict);
    expect(row.liveRemoteProgress?.normCharOffset, 5000);

    await host.putBookProgress(_bookKey, _progress(8000, now + 60000));
    return entries;
  }

  Future<int> hostNorm() async =>
      (await host.getBookProgress(_bookKey)).normCharOffset;

  test('选本地：加载后 host 被第三台设备改写 → host 保持新值、该行 noop', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<SyncCompareEntry> entries = await loadThenHostMoves(now);

    final SyncCompareApplyResult result = await applySyncCompareChoices(
      db: clientDb,
      backend: backend,
      actionable: entries,
      choices: <String, SyncChoice>{_bookKey: SyncChoice.useLocal},
      tempDir: work,
    );

    expect(result.errors, isEmpty);
    expect(result.applied, 0);
    expect(await hostNorm(), 8000, reason: '用户没见过的 host 新值不被覆盖');
    expect(
      BookProgressBaseline.decode(
        await clientDb.getSyncBaseline(
          _bookKey,
          credentialScopedDimension(kInterconnectBookProgressDimension, token),
        ),
      )?.normCharOffset,
      1000,
    );
  });

  test('选远端：加载后 host 被第三台设备改写 → 不落回本机、该行 noop', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<SyncCompareEntry> entries = await loadThenHostMoves(now);

    final SyncCompareApplyResult result = await applySyncCompareChoices(
      db: clientDb,
      backend: backend,
      actionable: entries,
      choices: <String, SyncChoice>{_bookKey: SyncChoice.useRemote},
      tempDir: work,
    );

    expect(result.errors, isEmpty);
    expect(result.applied, 0);
    final EpubBookRow book = (await clientDb.getEpubBook(_bookKey))!;
    expect(
      (await clientDb.getReaderPosition(book.uid))!.normCharOffset,
      3000,
      reason: '用户没见过的 host 新值不落到本机',
    );
    expect(await hostNorm(), 8000);
  });
}
