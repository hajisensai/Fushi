import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// `web_mine_queue`（schema v90）的读写：网页播放器观看时入队、重放时按书取待办、
/// 逐条标 done / failed。纯 DB 层，不碰播放器。
class WebMineQueueStore {
  const WebMineQueueStore(this.db);

  final FushiDatabase db;

  Future<int> enqueue({
    required String bookUid,
    required String videoKey,
    required String href,
    required int cueStartMs,
    required int cueEndMs,
    required String sentence,
    required Map<String, String> fields,
    String? cueSentence,
    DateTime? now,
  }) {
    return db
        .into(db.webMineQueue)
        .insert(
          WebMineQueueCompanion.insert(
            bookUid: bookUid,
            videoKey: videoKey,
            href: href,
            cueStartMs: cueStartMs,
            cueEndMs: cueEndMs,
            sentence: sentence,
            cueSentence: Value<String?>(cueSentence),
            fieldsJson: jsonEncode(fields),
            createdAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
          ),
        );
  }

  /// 待办按入队顺序（id 升序）。
  Future<List<WebMineQueueRow>> pending(String bookUid) {
    return (db.select(db.webMineQueue)
          ..where(
            ($WebMineQueueTable t) =>
                t.bookUid.equals(bookUid) &
                t.status.equals(WebMineQueueStatus.pending),
          )
          ..orderBy(<OrderingTerm Function($WebMineQueueTable)>[
            ($WebMineQueueTable t) => OrderingTerm.asc(t.id),
          ]))
        .get();
  }

  /// 有**网页档**待办的书，按各自最早一条待办的入队顺序（后台空闲自动制卡逐本跑）。
  ///
  /// 只取 `bookUid` 一列，在库里分组：调度每 30 秒问一次，整行读会把每条待办的
  /// `fieldsJson`（整份 Anki 字段，含词典释义）一起搬进 UI isolate，再在 Dart 里丢掉。
  /// `href != ''` 排掉本地视频「看完再制卡」的暂存行（`VideoMineQueue.stage` 写空
  /// `href`）：它们共用这张表，但媒体早已备好、不靠重放，后台重放调度认领不了。
  /// 这条过滤只属于本查询——[pending] 是两边共用的，不能带上。
  Future<List<String>> pendingBookUids() async {
    final Expression<int> firstId = db.webMineQueue.id.min();
    final List<TypedResult> rows =
        await (db.selectOnly(db.webMineQueue)
              ..addColumns(<Expression<Object>>[db.webMineQueue.bookUid])
              ..where(
                db.webMineQueue.status.equals(WebMineQueueStatus.pending) &
                    db.webMineQueue.href.equals('').not(),
              )
              ..groupBy(<Expression<Object>>[db.webMineQueue.bookUid])
              ..orderBy(<OrderingTerm>[OrderingTerm.asc(firstId)]))
            .get();
    return <String>[
      for (final TypedResult row in rows) row.read(db.webMineQueue.bookUid)!,
    ];
  }

  /// [bookUid] 的待办条数。`COUNT(*)`，不读行（每次入队、每轮结束都要问一次）。
  Future<int> pendingCount(String bookUid) =>
      _count(bookUid, const <String>[WebMineQueueStatus.pending]);

  /// [bookUid] 还留在队列里的条数（待办 + 失败），角标用。
  Future<int> openCount(String bookUid) => _count(bookUid, const <String>[
    WebMineQueueStatus.pending,
    WebMineQueueStatus.failed,
  ]);

  Future<int> _count(String bookUid, List<String> statuses) async {
    final Expression<int> rows = countAll();
    final TypedResult result =
        await (db.selectOnly(db.webMineQueue)
              ..addColumns(<Expression<Object>>[rows])
              ..where(
                db.webMineQueue.bookUid.equals(bookUid) &
                    db.webMineQueue.status.isIn(statuses),
              ))
            .getSingle();
    return result.read(rows) ?? 0;
  }

  /// 一行写完了：直接出表。
  ///
  /// 完成行没有任何读取方（列表、角标、调度都只看 pending / failed），留着只会让
  /// 每条都带整份 `fieldsJson` 的表无限长大。
  ///
  /// 行不在了，[warning]（网页档重放时「没录到音频」「片段合成失败退回封面」之类，卡
  /// 照样建成但缺东西）就没有列可写，改记一条诊断日志，带上行 id 与 [noteId]：用户反馈
  /// 「卡没声音」时凭它对得上是哪张卡、当时缺了什么。[noteId] 本身不必留——卡已在 Anki 里。
  Future<void> markDone(int id, {int? noteId, String? warning}) async {
    await remove(id);
    if (warning != null && warning.isNotEmpty) {
      ErrorLogService.instance.logDiagnostic(
        'web_mine_queue.markDone',
        'row $id mined with warnings: $warning (noteId: ${noteId ?? 'none'})',
      );
    }
  }

  /// 删掉旧版本留下的 `done` 行（那时完成只改状态、不删行），返回删了几行。只动
  /// `done`：pending / failed 是用户还没处理完的东西。
  Future<int> deleteDone() {
    return (db.delete(db.webMineQueue)..where(
          ($WebMineQueueTable t) => t.status.equals(WebMineQueueStatus.done),
        ))
        .go();
  }

  /// [deleteDone] 的「每个库只做一遍」版本，app 启动时由首页首帧调一次（`HomePage`）。
  /// 读方法（[pendingBookUids]、`VideoMineQueue.openCount`）不带这个删除副作用（#3722
  /// c15 遗留：以前挂在这两个读入口里，非 Windows 且不再打开本地视频播放页的用户旧
  /// done 行永远留着）。现在的代码不再产生 `done` 行，扫过一次之后表里就不会再有，
  /// 不必每次都扫全表。删失败（库正在关）不记「已扫」，下次启动再来。
  Future<void> sweepLegacyDone() async {
    if (_legacyDoneSwept[db] ?? false) return;
    await deleteDone();
    _legacyDoneSwept[db] = true;
  }

  static final Expando<bool> _legacyDoneSwept = Expando<bool>(
    'webMineQueueLegacyDoneSwept',
  );

  Future<void> markFailed(int id, String error) {
    return (db.update(
      db.webMineQueue,
    )..where(($WebMineQueueTable t) => t.id.equals(id))).write(
      WebMineQueueCompanion(
        status: const Value<String>(WebMineQueueStatus.failed),
        error: Value<String?>(error),
        minedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// 失败行重新排队（用户点「重试失败项」）。
  Future<int> requeueFailed(String bookUid) {
    return (db.update(db.webMineQueue)..where(
          ($WebMineQueueTable t) =>
              t.bookUid.equals(bookUid) &
              t.status.equals(WebMineQueueStatus.failed),
        ))
        .write(
          const WebMineQueueCompanion(
            status: Value<String>(WebMineQueueStatus.pending),
            error: Value<String?>(null),
          ),
        );
  }

  Future<int> remove(int id) => (db.delete(
    db.webMineQueue,
  )..where(($WebMineQueueTable t) => t.id.equals(id))).go();
}

/// 行里冻结的 Anki 字段映射。
Map<String, String> decodeWebMineFields(String fieldsJson) {
  try {
    final Object? raw = jsonDecode(fieldsJson);
    if (raw is Map) {
      return <String, String>{
        for (final MapEntry<dynamic, dynamic> e in raw.entries)
          e.key.toString(): e.value?.toString() ?? '',
      };
    }
  } catch (_) {}
  return const <String, String>{};
}
