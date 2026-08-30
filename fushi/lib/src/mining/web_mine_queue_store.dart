import 'dart:convert';

import 'package:drift/drift.dart';
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

  Future<int> pendingCount(String bookUid) async =>
      (await pending(bookUid)).length;

  Future<void> markDone(int id, {int? noteId, String? warning}) {
    return (db.update(
      db.webMineQueue,
    )..where(($WebMineQueueTable t) => t.id.equals(id))).write(
      WebMineQueueCompanion(
        status: const Value<String>(WebMineQueueStatus.done),
        noteId: Value<int?>(noteId),
        error: Value<String?>(warning),
        minedAt: Value<int?>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

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

  /// 清掉已完成 / 失败的历史行。
  Future<int> deleteFinished(String bookUid) {
    return (db.delete(db.webMineQueue)..where(
          ($WebMineQueueTable t) =>
              t.bookUid.equals(bookUid) &
              t.status.equals(WebMineQueueStatus.pending).not(),
        ))
        .go();
  }
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
