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

/// 「已发出、尚未确认」的推送位置（BUG-3528）。值形态同基线（[BookProgressBaseline]
/// 编码）；推送成功并记下基线后删除。见 [InterconnectBookProgressSync.decide]。
const String kInterconnectBookProgressPendingDimension =
    'progress_live_pending';

/// 一轮书籍进度 sweep 开头一次读齐的本端状态（见
/// [InterconnectBookProgressSync.loadSweepSnapshot]）：`reader_positions` 按书 uid，
/// 位置基线 / 「待确认」基线按 bookKey（值是 [BookProgressBaseline.encode]）。
typedef BookProgressSweepSnapshot = ({
  Map<String, ReaderPositionRow> positions,
  Map<String, int> baselines,
  Map<String, int> pending,
});

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
  }) : _db = db,
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

  /// 一次读齐 sweep 判定要用的本端状态：全部 `reader_positions`（按书 uid）、
  /// 全部位置基线与「待确认」基线（按 bookKey），共三条查询，免逐本 N+1。
  Future<BookProgressSweepSnapshot> loadSweepSnapshot() async => (
    positions: <String, ReaderPositionRow>{
      for (final ReaderPositionRow row in await _db.getAllReaderPositions())
        row.bookUid: row,
    },
    baselines: await _db.getSyncBaselinesForDimension(
      kInterconnectBookProgressDimension,
    ),
    pending: await _db.getSyncBaselinesForDimension(
      kInterconnectBookProgressPendingDimension,
    ),
  );

  /// 从快照取本端进度（与 [localProgress] 同口径，零查询）。
  static RemoteBookProgress localProgressFromSnapshot(
    EpubBookRow book,
    BookProgressSweepSnapshot snapshot,
  ) {
    final ReaderPositionRow? row = snapshot.positions[book.uid];
    if (row == null) return RemoteBookProgress.empty;
    return RemoteBookProgress(
      sectionIndex: row.sectionIndex,
      normCharOffset: row.normCharOffset,
      charOffset: row.charOffset,
      updatedAtMs: row.updatedAt,
    );
  }

  /// 两端已完全收敛、这一轮无事可做（sweep 据此跳过，不再逐本读写基线）。
  ///
  /// 对应原路径 [decide] → synced → [alignSynced] 的净零情形：
  /// - 两端都无记录：[alignSynced] 本来就直接返回；
  /// - 两端位置、charOffset、时间戳全同，基线已等于该位置，且没有「待确认」
  ///   推送：不 PUT、不落本端，只是把同一个基线重写一遍、删一条不存在的行。
  /// 任何一项不成立都不算收敛，调用方回到原路径逐本重读、判定、落地，语义不变。
  static bool isSettled({
    required EpubBookRow book,
    required RemoteBookProgress local,
    required RemoteBookProgress remote,
    required BookProgressSweepSnapshot snapshot,
  }) {
    if (local.updatedAtMs <= 0 && remote.updatedAtMs <= 0) return true;
    if (snapshot.pending.containsKey(book.bookKey)) return false;
    if (local.updatedAtMs != remote.updatedAtMs ||
        local.charOffset != remote.charOffset ||
        !sameBookPosition(local, remote)) {
      return false;
    }
    return snapshot.baselines[book.bookKey] ==
        BookProgressBaseline.of(local).encode();
  }

  /// host 端该书进度（host 无记录 → empty）。
  Future<RemoteBookProgress> remoteProgress(EpubBookRow book) =>
      _backend.remoteBookProgress(book.bookKey);

  /// 上次两端达成一致的位置基线（没有 → null）。
  Future<BookProgressBaseline?> baseline(EpubBookRow book) async =>
      BookProgressBaseline.decode(
        await _db.getSyncBaseline(
          book.bookKey,
          kInterconnectBookProgressDimension,
        ),
      );

  /// 三方判定的唯一入口：sweep 与冲突弹窗都走这里，不各自读基线。
  ///
  /// 「写入落地、确认丢失」（BUG-3528）：host 慢时 PUT 在 host 端已经提交，客户端
  /// 却等到超时，[pushLocal] 在记基线之前就抛了，基线停在更早的位置。之后本机
  /// 接着读，下一轮两端都偏离旧基线——host 那份其实是本机自己的写入——被判成
  /// 冲突。所以推送前先记一条「待确认」位置；这里发现 host 正停在它上面，说明
  /// 那次写入确实到了，把它提升为基线再判定。
  Future<BookProgressSyncAction> decide(
    EpubBookRow book, {
    required RemoteBookProgress local,
    required RemoteBookProgress remote,
  }) async {
    BookProgressBaseline? base = await baseline(book);
    final BookProgressBaseline? pending = BookProgressBaseline.decode(
      await _db.getSyncBaseline(
        book.bookKey,
        kInterconnectBookProgressPendingDimension,
      ),
    );
    if (pending != null &&
        remote.updatedAtMs > 0 &&
        pending.matches(remote) &&
        (base == null || !base.matches(remote))) {
      await recordBaseline(book, remote);
      base = pending;
    }
    return resolveBookProgressThreeWay(
      local: local,
      remote: remote,
      base: base,
    );
  }

  /// 记下两端此刻达成一致的位置；同时作废「待确认」推送（两端已对齐，它不再
  /// 携带信息）。
  Future<void> recordBaseline(
    EpubBookRow book,
    RemoteBookProgress agreed,
  ) async {
    await _db.setSyncBaseline(
      book.bookKey,
      kInterconnectBookProgressDimension,
      BookProgressBaseline.of(agreed).encode(),
    );
    await _db.deleteSyncBaseline(
      book.bookKey,
      kInterconnectBookProgressPendingDimension,
    );
  }

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
    // 先记「待确认」再发：PUT 超时而 host 已提交时，下一轮 [decide] 靠它认出
    // host 上那份是本机自己的写入（BUG-3528）。
    await _db.setSyncBaseline(
      book.bookKey,
      kInterconnectBookProgressPendingDimension,
      BookProgressBaseline.of(agreed).encode(),
    );
    await _backend.putRemoteBookProgress(book.bookKey, agreed);
    if (ts != local.updatedAtMs) {
      // 比较后写入（BUG-3537）：PUT 期间本地若已被改写（本机阅读器 / 本机作为
      // host 收到的对端 PUT），抬戳对齐作废——本地留着更新的那份，下一轮它偏离
      // 基线、照常再推。host 此刻确实停在 [agreed]，基线照记。
      await _upsertLocalIfUnchanged(book, agreed, expected: local);
    }
    await recordBaseline(book, agreed);
    return agreed;
  }

  /// host 胜出：落回本端 `reader_positions`，记基线。返回是否真的落地。
  ///
  /// [local] 是判定时读到的本端进度。落地是「比较后写入」（BUG-3537）：判定与
  /// 这里之间（sweep 里隔着 DB 往返，冲突弹窗里隔着用户思考），本地可能已被本机
  /// 阅读器或本机作为互联 host 收到的对端 PUT 写进更新的进度；时间戳一变，这次
  /// 判定作废——不落地、不记基线，交给下一轮按新的本地事实重新判定（届时两端都
  /// 偏离基线就是真分叉，走冲突弹窗），绝不用 host 的旧值盖掉它。
  Future<bool> applyRemote(
    EpubBookRow book,
    RemoteBookProgress remote, {
    required RemoteBookProgress local,
  }) async {
    final bool landed = await _upsertLocalIfUnchanged(
      book,
      remote,
      expected: local,
    );
    if (landed) await recordBaseline(book, remote);
    return landed;
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
    final RemoteBookProgress winner = resolveBookProgressSync(
      local: local,
      remote: remote,
    );
    if (winner.updatedAtMs > remote.updatedAtMs ||
        (winner.updatedAtMs == remote.updatedAtMs &&
            winner.charOffset != remote.charOffset)) {
      await _backend.putRemoteBookProgress(book.bookKey, winner);
    }
    bool localChanged =
        winner.updatedAtMs != local.updatedAtMs ||
        winner.charOffset != local.charOffset;
    if (localChanged) {
      // 比较后写入（BUG-3537）：本地在判定后被改写就不对齐，下一轮再说。位置
      // 一致这件事在判定时成立、host 也停在这个位置，基线照记。
      localChanged = await _upsertLocalIfUnchanged(
        book,
        winner,
        expected: local,
      );
    }
    await recordBaseline(book, winner);
    return localChanged;
  }

  /// 本端落地的唯一写口：仅当本地时间戳仍是判定时读到的 [expected] 才写
  /// （[FushiDatabase.upsertReaderPositionIfUnchanged]，BUG-3537）。
  Future<bool> _upsertLocalIfUnchanged(
    EpubBookRow book,
    RemoteBookProgress p, {
    required RemoteBookProgress expected,
  }) => _db.upsertReaderPositionIfUnchanged(
    ReaderPositionsCompanion(
      bookUid: Value(book.uid),
      sectionIndex: Value(p.sectionIndex),
      normCharOffset: Value(p.normCharOffset),
      charOffset: Value(p.charOffset),
      updatedAt: Value(p.updatedAtMs),
    ),
    expectedUpdatedAt: expected.updatedAtMs,
  );
}
