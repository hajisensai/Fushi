import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_book_progress_sync.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import '../helpers/interconnect_legacy_host_scope.dart';

/// 互联书籍进度没接未来时间戳防护：host 上一条超限毒戳（时钟走快的设备写下的）
/// 在 client 抬戳（`毒戳 + 1`）与对齐（直接按戳取胜者）里永远胜出，被写进本端
/// `reader_positions.updatedAt` 并推回 host，扩散到各端。播放位置的对齐 / 落地
/// 也直接比戳。这里钉住：client 推出去的戳与落到本端的戳都不超过 `now + 余量`，
/// 对齐时 host 毒戳按 0 比较、本端胜出。

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

const String _bookKey = 'book-future';
const String _videoKey = 'video-future';

/// 记录每次 PUT 的假互联后端；GET 返回测试预置的 host 值。
class _RecordingBackend extends InterconnectSyncBackend
    with LegacyInterconnectHostScope {
  _RecordingBackend()
    : super.withProbe((String url, String token) async => true);

  RemoteBookProgress book = RemoteBookProgress.empty;
  PlaybackPosition video = (positionMs: 0, updatedAtMs: 0);
  final List<RemoteBookProgress> bookPuts = <RemoteBookProgress>[];
  final List<PlaybackPosition> videoPuts = <PlaybackPosition>[];

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async => book;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {
    bookPuts.add(progress);
  }

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => video;

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    videoPuts.add((positionMs: positionMs, updatedAtMs: updatedAtMs));
  }
}

Future<EpubBookRow> _seedBook(FushiDatabase db) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: _bookKey,
      title: _bookKey,
      epubPath: '/tmp/$_bookKey.epub',
      extractDir: '/tmp/$_bookKey',
      chapterCount: 3,
      chaptersJson: '["a","b","c"]',
      importedAt: 1,
    ),
  );
  return (await db.getEpubBook(_bookKey))!;
}

Future<void> _setLocalBook(
  FushiDatabase db,
  EpubBookRow book,
  RemoteBookProgress p,
) => db.upsertReaderPosition(
  ReaderPositionsCompanion(
    bookUid: Value(book.uid),
    sectionIndex: Value(p.sectionIndex),
    normCharOffset: Value(p.normCharOffset),
    charOffset: Value(p.charOffset),
    updatedAt: Value(p.updatedAtMs),
  ),
);

RemoteBookProgress _progress(int section, int offset, int at) =>
    RemoteBookProgress(
      sectionIndex: section,
      normCharOffset: offset,
      charOffset: 0,
      updatedAtMs: at,
    );

Future<void> _setLocalVideo(FushiDatabase db, PlaybackPosition p) async {
  await db.setPrefTyped<int>(
    videoRemotePositionPrefKey(_videoKey),
    p.positionMs,
  );
  await db.setPrefTyped<int>(
    videoRemotePositionAtPrefKey(_videoKey),
    p.updatedAtMs,
  );
}

/// applyRemote 用真实当前时刻截戳：上界在断言时取，而不是测试开头的 `now`。
int _capNow() =>
    DateTime.now().millisecondsSinceEpoch + kSyncFutureStampToleranceMs;

void main() {
  late FushiDatabase db;
  late _RecordingBackend backend;
  final int now = DateTime.now().millisecondsSinceEpoch;
  final int poison = now + const Duration(days: 1).inMilliseconds;
  final int cap = now + kSyncFutureStampToleranceMs;

  setUp(() {
    db = _memDb();
    backend = _RecordingBackend();
  });

  tearDown(() async {
    await db.close();
  });

  group('书籍进度', () {
    test('pushLocal：host 毒戳不被「+1」抬进推送戳与本端行', () async {
      final EpubBookRow book = await _seedBook(db);
      final InterconnectBookProgressSync sync = InterconnectBookProgressSync(
        db: db,
        backend: backend,
      );
      final RemoteBookProgress local = _progress(2, 200, now - 60000);
      await _setLocalBook(db, book, local);
      // host 此刻就是判定时读到的那份（live 写入的前置条件核对它，BUG-4388）。
      backend.book = _progress(1, 100, poison);

      final RemoteBookProgress agreed = (await sync.pushLocal(
        book,
        local: local,
        remote: _progress(1, 100, poison),
        nowMs: now,
      )).agreed;

      expect(backend.bookPuts, hasLength(1));
      expect(backend.bookPuts.single.updatedAtMs, lessThanOrEqualTo(cap));
      expect(backend.bookPuts.single.sectionIndex, 2);
      expect(agreed.updatedAtMs, lessThanOrEqualTo(cap));
      final ReaderPositionRow row = (await db.getReaderPosition(book.uid))!;
      expect(row.updatedAt, lessThanOrEqualTo(cap));
      expect(row.sectionIndex, 2);
    });

    test('alignSynced：位置相同、host 毒戳 → 本端不被对齐成毒戳，推本端戳给 host', () async {
      final EpubBookRow book = await _seedBook(db);
      final InterconnectBookProgressSync sync = InterconnectBookProgressSync(
        db: db,
        backend: backend,
      );
      final RemoteBookProgress local = _progress(1, 100, now - 60000);
      await _setLocalBook(db, book, local);
      backend.book = _progress(1, 100, poison);

      final bool localChanged = await sync.alignSynced(
        book,
        local: local,
        remote: _progress(1, 100, poison),
      );

      expect(localChanged, isFalse);
      final ReaderPositionRow row = (await db.getReaderPosition(book.uid))!;
      expect(row.updatedAt, now - 60000);
      expect(backend.bookPuts, hasLength(1));
      expect(backend.bookPuts.single.updatedAtMs, now - 60000);
    });

    test('applyRemote：host 胜出但带毒戳 → 落到本端的戳截到 now + 余量', () async {
      final EpubBookRow book = await _seedBook(db);
      final InterconnectBookProgressSync sync = InterconnectBookProgressSync(
        db: db,
        backend: backend,
      );
      final RemoteBookProgress local = _progress(1, 100, now - 60000);
      await _setLocalBook(db, book, local);

      final bool landed = await sync.applyRemote(
        book,
        _progress(3, 300, poison),
        local: local,
      );

      expect(landed, isTrue);
      final ReaderPositionRow row = (await db.getReaderPosition(book.uid))!;
      expect(row.sectionIndex, 3);
      expect(row.normCharOffset, 300);
      expect(row.updatedAt, lessThanOrEqualTo(_capNow()));
    });
  });

  group('播放位置', () {
    test('alignSynced：位置相同、host 毒戳 → 本端不被对齐成毒戳，推本端戳给 host', () async {
      final InterconnectPlaybackPositionSync sync =
          InterconnectPlaybackPositionSync(
            db: db,
            backend: backend,
            kind: PlaybackPositionKind.video,
          );
      final PlaybackPosition local = (
        positionMs: 5000,
        updatedAtMs: now - 60000,
      );
      await _setLocalVideo(db, local);
      backend.video = (positionMs: 5000, updatedAtMs: poison);

      final bool localChanged = await sync.alignSynced(
        _videoKey,
        local: local,
        remote: (positionMs: 5000, updatedAtMs: poison),
      );

      expect(localChanged, isFalse);
      expect(
        await db.getPrefTyped<int>(videoRemotePositionAtPrefKey(_videoKey), 0),
        now - 60000,
      );
      expect(backend.videoPuts, <PlaybackPosition>[
        (positionMs: 5000, updatedAtMs: now - 60000),
      ]);
    });

    test('applyRemote：host 胜出但带毒戳 → 落到本端的戳截到 now + 余量', () async {
      final InterconnectPlaybackPositionSync sync =
          InterconnectPlaybackPositionSync(
            db: db,
            backend: backend,
            kind: PlaybackPositionKind.video,
          );
      final PlaybackPosition local = (
        positionMs: 5000,
        updatedAtMs: now - 60000,
      );
      await _setLocalVideo(db, local);

      final bool landed = await sync.applyRemote(_videoKey, (
        positionMs: 9000,
        updatedAtMs: poison,
      ), local: local);

      expect(landed, isTrue);
      expect(
        await db.getPrefTyped<int>(videoRemotePositionPrefKey(_videoKey), 0),
        9000,
      );
      expect(
        await db.getPrefTyped<int>(videoRemotePositionAtPrefKey(_videoKey), 0),
        lessThanOrEqualTo(_capNow()),
      );
    });
  });
}
