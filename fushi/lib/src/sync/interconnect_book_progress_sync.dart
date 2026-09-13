import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// 互联书籍进度位置基线在 `sync_baselines` 表里的 dimension（BUG-2506）。
///
/// 与云通道 SyncManager 的 `'progress'`（值是时间戳）**刻意分开**：那条基线描述的
/// 是「本机 ↔ 云盘文件箱」的共同祖先，互联这条描述的是「本机 ↔ host DB」；两条通道
/// 可以同时启用，共用一行会互相污染冲突判定。assetKey 用互联 wire 键 `bookKey`。
const String kInterconnectBookProgressDimension = 'progress_live';

/// 互联书籍进度的三方同步落地层（BUG-2506）：sweep（[SyncOrchestrator]）与
/// 冲突对比弹窗（`SyncCompareDialog`）共用同一份读 / 写 / 记基线，两处口径不会
/// 漂移。判定本身是纯函数 [resolveBookProgressThreeWay]，这里只做 IO。
///
/// 时间戳纪律：host 端 `putBookProgress` 仍是防御性的「取较新时间戳」——推本端
/// 进度时若 host 的时间戳更新（host 只是重开过书），照原样 PUT 会被 host 静默丢弃，
/// 于是每一轮都推、每一轮都被丢。所以 [pushLocal] 把时间戳抬到 `max(本端, host+1)`
/// 并同步写回本端行，让两端在这一刻真正对齐；抬的是「决定时刻」，位置一字不改。
class InterconnectBookProgressSync {
  const InterconnectBookProgressSync({
    required FushiDatabase db,
    required InterconnectSyncBackend backend,
  })  : _db = db,
        _backend = backend;

  final FushiDatabase _db;
  final InterconnectSyncBackend _backend;

  /// 本端 `reader_positions` 行 → 与 host 同形的进度（无行 = [RemoteBookProgress.empty]）。
  Future<RemoteBookProgress> localProgress(EpubBookRow book) async {
    // v82：wire 键仍是 bookKey（REST 路径冻结），本地子表键是书 uid。
    final ReaderPositionRow? row = await _db.getReaderPosition(book.uid);
    if (row == null) return RemoteBookProgress.empty;
    return RemoteBookProgress(
      sectionIndex: row.sectionIndex,
      normCharOffset: row.normCharOffset,
      charOffset: row.charOffset,
      updatedAtMs: row.updatedAt,
    );
  }

  /// host 端该书进度（host 无记录 → empty）。
  Future<RemoteBookProgress> remoteProgress(EpubBookRow book) =>
      _backend.remoteBookProgress(book.bookKey);

  /// 上次两端达成一致的位置基线（没有 → null）。
  Future<BookProgressBaseline?> baseline(EpubBookRow book) async =>
      BookProgressBaseline.decode(await _db.getSyncBaseline(
        book.bookKey,
        kInterconnectBookProgressDimension,
      ));

  /// 记下两端此刻达成一致的位置。
  Future<void> recordBaseline(EpubBookRow book, RemoteBookProgress agreed) =>
      _db.setSyncBaseline(
        book.bookKey,
        kInterconnectBookProgressDimension,
        BookProgressBaseline.of(agreed).encode(),
      );

  /// 本端胜出：推给 host（时间戳抬到严格新于 host，见类头），本端行同步对齐，
  /// 记基线。返回两端对齐后的进度。
  Future<RemoteBookProgress> pushLocal(
    EpubBookRow book, {
    required RemoteBookProgress local,
    required RemoteBookProgress remote,
    int? nowMs,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    int ts = local.updatedAtMs;
    if (ts <= remote.updatedAtMs) {
      ts = remote.updatedAtMs + 1;
      if (now > ts) ts = now;
    }
    final RemoteBookProgress agreed = RemoteBookProgress(
      sectionIndex: local.sectionIndex,
      normCharOffset: local.normCharOffset,
      charOffset: local.charOffset,
      updatedAtMs: ts,
    );
    await _backend.putRemoteBookProgress(book.bookKey, agreed);
    if (ts != local.updatedAtMs) {
      await _upsertLocal(book, agreed);
    }
    await recordBaseline(book, agreed);
    return agreed;
  }

  /// host 胜出：落回本端 `reader_positions`，记基线。
  Future<void> applyRemote(EpubBookRow book, RemoteBookProgress remote) async {
    await _upsertLocal(book, remote);
    await recordBaseline(book, remote);
  }

  /// 两端位置一致、只是时间戳不同：把较新的时间戳对齐到另一端（沿用此前 LWW
  /// 路径的对齐写法），记基线。位置相同时「较新」只决定 charOffset 精确锚与时刻。
  /// 返回本端行是否被改写（调用方据此计入「已拉取」让书架刷新）。
  Future<bool> alignSynced(
    EpubBookRow book, {
    required RemoteBookProgress local,
    required RemoteBookProgress remote,
  }) async {
    if (local.updatedAtMs <= 0 && remote.updatedAtMs <= 0) return false;
    final RemoteBookProgress winner =
        resolveBookProgressSync(local: local, remote: remote);
    if (winner.updatedAtMs > remote.updatedAtMs ||
        (winner.updatedAtMs == remote.updatedAtMs &&
            winner.charOffset != remote.charOffset)) {
      await _backend.putRemoteBookProgress(book.bookKey, winner);
    }
    final bool localChanged = winner.updatedAtMs != local.updatedAtMs ||
        winner.charOffset != local.charOffset;
    if (localChanged) {
      await _upsertLocal(book, winner);
    }
    await recordBaseline(book, winner);
    return localChanged;
  }

  Future<void> _upsertLocal(EpubBookRow book, RemoteBookProgress p) =>
      _db.upsertReaderPosition(ReaderPositionsCompanion(
        bookUid: Value(book.uid),
        sectionIndex: Value(p.sectionIndex),
        normCharOffset: Value(p.normCharOffset),
        charOffset: Value(p.charOffset),
        updatedAt: Value(p.updatedAtMs),
      ));
}
