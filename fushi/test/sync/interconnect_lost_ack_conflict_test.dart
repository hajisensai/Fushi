import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_file_ref.dart';
import 'package:fushi/src/sync/sync_utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// BUG-3519：互联推送「写入已落地、确认丢失」被误判成冲突。
///
/// 实测时间线（手机 → 电脑 host）：15:39 读到第 87 页，15:40 sweep 推给 host，
/// 手机端 15 秒超时，host 却已经提交；手机没推进基线。16:34 读到第 131 页，
/// 下一轮两端都偏离旧基线 → 冲突弹窗，「远端」就是手机自己 15:39 的写入。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

RemoteBookProgress _page(int page, int at) => RemoteBookProgress(
  sectionIndex: page,
  normCharOffset: 0,
  charOffset: 0,
  updatedAtMs: at,
);

/// host 端照常提交，然后让客户端等到超时（确认包丢失）。
class _LostAckBackend extends InterconnectSyncBackend {
  _LostAckBackend() : super.withProbe((String url, String token) async => true);

  final Map<String, RemoteBookProgress> books = <String, RemoteBookProgress>{};
  final Map<String, PlaybackPosition> video = <String, PlaybackPosition>{};
  bool dropAck = false;
  bool dropWrite = false;

  void _afterCommit() {
    if (dropAck) throw TimeoutException('interconnect request timed out');
  }

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      books[bookKey] ?? RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    if (dropWrite) throw TimeoutException('interconnect request timed out');
    books[bookKey] = progress;
    _afterCommit();
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => video[id] ?? (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    if (dropWrite) throw TimeoutException('interconnect request timed out');
    video[id] = (positionMs: positionMs, updatedAtMs: updatedAtMs);
    _afterCommit();
  }
}

Future<EpubBookRow> _seedBook(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: 'shino2',
      title: 'shino2',
      epubPath: '/tmp/shino2/original.epub',
      extractDir: '/tmp/shino2',
      chapterCount: 1,
      chaptersJson: '["c"]',
      importedAt: 0,
    ),
  );
  return (await db.getEpubBook('shino2'))!;
}

Future<void> _setLocal(FushiDatabase db, EpubBookRow book, int page, int at) =>
    db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value(book.uid),
        sectionIndex: Value(page),
        normCharOffset: const Value(0),
        charOffset: const Value(0),
        updatedAt: Value(at),
      ),
    );

void main() {
  group('书籍进度', () {
    late FushiDatabase db;
    late _LostAckBackend backend;
    late InterconnectBookProgressSync sync;
    late EpubBookRow book;

    setUp(() async {
      db = _memDb();
      backend = _LostAckBackend();
      sync = InterconnectBookProgressSync(db: db, backend: backend);
      book = await _seedBook(db);
      // 两端此前在第 30 页达成一致。
      await _setLocal(db, book, 30, 1000);
      backend.books['shino2'] = _page(30, 1000);
      await sync.recordBaseline(book, _page(30, 1000));
    });

    tearDown(() => db.close());

    test('PUT 超时但 host 已提交 → 下一轮认出是本机写入，推送而不是冲突', () async {
      // 15:39 读到 87 页，推送时确认包丢失。
      await _setLocal(db, book, 87, 2000);
      backend.dropAck = true;
      await expectLater(
        sync.pushLocal(
          book,
          local: await sync.localProgress(book),
          remote: await sync.remoteProgress(book),
        ),
        throwsA(isA<TimeoutException>()),
      );
      backend.dropAck = false;
      expect(backend.books['shino2']!.sectionIndex, 87, reason: 'host 已提交');

      // 16:34 读到 131 页。
      await _setLocal(db, book, 131, 3000);
      final RemoteBookProgress local = await sync.localProgress(book);
      final RemoteBookProgress remote = await sync.remoteProgress(book);

      // 只看已确认基线（修复前的判据）就是截图里的幻象冲突。
      expect(
        resolveBookProgressThreeWay(
          local: local,
          remote: remote,
          base: await sync.baseline(book),
        ),
        BookProgressSyncAction.conflict,
      );

      expect(
        await sync.decide(book, local: local, remote: remote),
        BookProgressSyncAction.pushLocal,
      );
      expect((await sync.baseline(book))!.sectionIndex, 87);
    });

    test('PUT 根本没到 host、对端又独立改动 → 仍是真冲突', () async {
      await _setLocal(db, book, 87, 2000);
      backend.dropWrite = true;
      await expectLater(
        sync.pushLocal(
          book,
          local: await sync.localProgress(book),
          remote: await sync.remoteProgress(book),
        ),
        throwsA(isA<TimeoutException>()),
      );
      backend.dropWrite = false;
      backend.books['shino2'] = _page(50, 2500); // 另一台设备读到 50 页。

      await _setLocal(db, book, 131, 3000);
      expect(
        await sync.decide(
          book,
          local: await sync.localProgress(book),
          remote: await sync.remoteProgress(book),
        ),
        BookProgressSyncAction.conflict,
      );
    });

    test('推送成功后「待确认」被清掉', () async {
      await _setLocal(db, book, 87, 2000);
      await sync.pushLocal(
        book,
        local: await sync.localProgress(book),
        remote: await sync.remoteProgress(book),
      );
      expect(
        await db.getSyncBaseline(
          'shino2',
          kInterconnectBookProgressPendingDimension,
        ),
        isNull,
      );
      expect((await sync.baseline(book))!.sectionIndex, 87);
    });
  });

  group('播放位置', () {
    late FushiDatabase db;
    late _LostAckBackend backend;
    late InterconnectPlaybackPositionSync sync;

    setUp(() async {
      db = _memDb();
      backend = _LostAckBackend();
      sync = InterconnectPlaybackPositionSync(
        db: db,
        backend: backend,
        kind: PlaybackPositionKind.video,
      );
      backend.video['v'] = (positionMs: 100, updatedAtMs: 1000);
      await sync.recordBaseline('v', 100);
    });

    tearDown(() => db.close());

    Future<void> setLocal(int positionMs, int at) async {
      await db.setPrefTyped<int>(videoRemotePositionPrefKey('v'), positionMs);
      await db.setPrefTyped<int>(videoRemotePositionAtPrefKey('v'), at);
    }

    test('sweep 推送确认丢失 → 下一轮推送而不是冲突', () async {
      await setLocal(600, 2000);
      backend.dropAck = true;
      await expectLater(
        sync.pushLocal(
          'v',
          local: await sync.localPosition('v'),
          remote: await sync.remotePosition('v'),
        ),
        throwsA(isA<TimeoutException>()),
      );
      backend.dropAck = false;

      await setLocal(900, 3000);
      expect(
        await sync.decide(
          'v',
          local: await sync.localPosition('v'),
          remote: await sync.remotePosition('v'),
        ),
        BookProgressSyncAction.pushLocal,
      );
      expect(await sync.baseline('v'), 600);
    });

    test('播放页实时上报确认丢失 → 同样认出本机写入', () async {
      backend.dropAck = true;
      await expectLater(
        sync.reportLive('v', (positionMs: 600, updatedAtMs: 2000)),
        throwsA(isA<TimeoutException>()),
      );
      backend.dropAck = false;

      await setLocal(900, 3000);
      expect(
        await sync.decide(
          'v',
          local: await sync.localPosition('v'),
          remote: await sync.remotePosition('v'),
        ),
        BookProgressSyncAction.pushLocal,
      );
    });
  });

  group('findSyncFileByPrefix', () {
    const SyncFileRef older = SyncFileRef(
      id: 'old',
      name: 'progress_1_6_1792308000000_0.52.json',
    );
    const SyncFileRef newer = SyncFileRef(
      id: 'new',
      name: 'progress_1_6_1792312477727_0.78.json',
    );

    test('同前缀多份时取时间戳最新，与列表顺序无关', () {
      expect(
        findSyncFileByPrefix(<SyncFileRef>[older, newer], 'progress_')!.id,
        'new',
      );
      expect(
        findSyncFileByPrefix(<SyncFileRef>[newer, older], 'progress_')!.id,
        'new',
      );
    });

    test('解析不出时间戳的视为最旧；无匹配返回 null', () {
      const SyncFileRef odd = SyncFileRef(id: 'odd', name: 'progress_x.json');
      expect(
        findSyncFileByPrefix(<SyncFileRef>[odd, older], 'progress_')!.id,
        'old',
      );
      expect(findSyncFileByPrefix(<SyncFileRef>[odd], 'progress_')!.id, 'odd');
      expect(findSyncFileByPrefix(<SyncFileRef>[older], 'statistics_'), isNull);
    });
  });
}
