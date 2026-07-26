import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:hibiki_core/hibiki_core.dart';

const String kTrackingProviderBangumi = 'bangumi';

enum TrackingMediaType {
  book('book'),
  video('video'),
  videoCollection('video_collection');

  const TrackingMediaType(this.value);
  final String value;
}

enum TrackingKind {
  anime('anime'),
  novel('novel'),
  manga('manga');

  const TrackingKind(this.value);
  final String value;
}

enum TrackingProgressMode {
  episode('episode'),
  chapter('chapter'),
  volume('volume');

  const TrackingProgressMode(this.value);
  final String value;
}

class PendingTrackingUpdate {
  const PendingTrackingUpdate({
    required this.outbox,
    required this.mapping,
  });

  final MediaTrackingOutboxRow outbox;
  final MediaTrackingMappingRow mapping;
}

/// 外部媒体映射与可靠待同步队列的单一数据入口。
///
/// 队列按 mapping 合并成一行，进度只取最大值、完成状态只会 false→true；成功/失败回写
/// 都带 [MediaTrackingOutboxRow.updatedAt] 乐观锁，网络请求期间若来了更高进度，旧请求
/// 不能误删或覆盖新事件。
class MediaTrackingRepository {
  const MediaTrackingRepository(this._db);

  final HibikiDatabase _db;

  Future<List<MediaTrackingMappingRow>> listMappings() =>
      (_db.select(_db.mediaTrackingMappings)
            ..orderBy([
              (t) => OrderingTerm(expression: t.kind),
              (t) => OrderingTerm(expression: t.mediaTitle),
            ]))
          .get();

  Future<MediaTrackingMappingRow?> findMapping({
    required TrackingMediaType mediaType,
    required String mediaKey,
    String provider = kTrackingProviderBangumi,
  }) =>
      (_db.select(_db.mediaTrackingMappings)
            ..where((t) =>
                t.provider.equals(provider) &
                t.mediaType.equals(mediaType.value) &
                t.mediaKey.equals(mediaKey)))
          .getSingleOrNull();

  Future<int> saveMapping({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required String mediaTitle,
    required TrackingKind kind,
    required int subjectId,
    required String subjectName,
    required TrackingProgressMode progressMode,
    required int progressOffset,
    String provider = kTrackingProviderBangumi,
  }) async {
    if (mediaKey.trim().isEmpty) {
      throw ArgumentError.value(mediaKey, 'mediaKey', 'must not be empty');
    }
    if (subjectId <= 0) {
      throw ArgumentError.value(subjectId, 'subjectId', 'must be positive');
    }
    if (progressOffset < 0) {
      throw ArgumentError.value(
          progressOffset, 'progressOffset', 'must be non-negative');
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final MediaTrackingMappingRow? existing = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (existing == null) {
      return _db.into(_db.mediaTrackingMappings).insert(
            MediaTrackingMappingsCompanion.insert(
              provider: Value<String>(provider),
              mediaType: mediaType.value,
              mediaKey: mediaKey,
              mediaTitle: mediaTitle,
              kind: kind.value,
              subjectId: subjectId,
              subjectName: subjectName,
              progressMode: progressMode.value,
              progressOffset: Value<int>(progressOffset),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await (_db.update(_db.mediaTrackingMappings)
          ..where((t) => t.id.equals(existing.id)))
        .write(
      MediaTrackingMappingsCompanion(
        mediaTitle: Value<String>(mediaTitle),
        kind: Value<String>(kind.value),
        subjectId: Value<int>(subjectId),
        subjectName: Value<String>(subjectName),
        progressMode: Value<String>(progressMode.value),
        progressOffset: Value<int>(progressOffset),
        updatedAt: Value<int>(now),
      ),
    );
    return existing.id;
  }

  Future<void> deleteMapping(int id) =>
      (_db.delete(_db.mediaTrackingMappings)..where((t) => t.id.equals(id)))
          .go();

  /// 将本地 0-based [localProgress] 翻译为远端进度并入队。没有映射返回 false；
  /// 调用方据此无声跳过，播放/阅读主路径不受外部服务影响。
  Future<bool> enqueueProgress({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int localProgress,
    required bool completed,
  }) async {
    final MediaTrackingMappingRow? mapping = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
    );
    if (mapping == null) return false;
    final int progress = math.max(0, localProgress + mapping.progressOffset);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction(() async {
      final MediaTrackingOutboxRow? existing =
          await (_db.select(_db.mediaTrackingOutbox)
                ..where((t) => t.mappingId.equals(mapping.id)))
              .getSingleOrNull();
      if (existing == null) {
        await _db.into(_db.mediaTrackingOutbox).insert(
              MediaTrackingOutboxCompanion.insert(
                mappingId: mapping.id,
                progress: progress,
                completed: Value<bool>(completed),
                updatedAt: now,
              ),
            );
        return;
      }
      final int mergedProgress = math.max(existing.progress, progress);
      final bool mergedCompleted = existing.completed || completed;
      // 毫秒时钟可能在同一 tick 连收两次事件；乐观锁版本必须严格递增，不能只写 now。
      final int eventVersion = math.max(now, existing.updatedAt + 1);
      await (_db.update(_db.mediaTrackingOutbox)
            ..where((t) => t.id.equals(existing.id)))
          .write(
        MediaTrackingOutboxCompanion(
          progress: Value<int>(mergedProgress),
          completed: Value<bool>(mergedCompleted),
          // 新事件应立即可重试；同时清掉旧错误，UI 不展示已经过时的失败。
          attemptCount: const Value<int>(0),
          nextAttemptAt: const Value<int>(0),
          lastError: const Value<String?>(null),
          updatedAt: Value<int>(eventVersion),
        ),
      );
    });
    return true;
  }

  Future<List<PendingTrackingUpdate>> dueUpdates({
    int limit = 20,
    int? nowMs,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final query = _db.select(_db.mediaTrackingOutbox).join(<Join>[
      innerJoin(
        _db.mediaTrackingMappings,
        _db.mediaTrackingMappings.id
            .equalsExp(_db.mediaTrackingOutbox.mappingId),
      ),
    ])
      ..where(_db.mediaTrackingOutbox.nextAttemptAt.isSmallerOrEqualValue(now))
      ..orderBy(<OrderingTerm>[
        OrderingTerm(expression: _db.mediaTrackingOutbox.updatedAt),
      ])
      ..limit(limit);
    final List<TypedResult> rows = await query.get();
    return rows
        .map(
          (TypedResult row) => PendingTrackingUpdate(
            outbox: row.readTable(_db.mediaTrackingOutbox),
            mapping: row.readTable(_db.mediaTrackingMappings),
          ),
        )
        .toList(growable: false);
  }

  Future<int> pendingCount() async {
    final Expression<int> count = _db.mediaTrackingOutbox.id.count();
    final TypedResult row = await (_db.selectOnly(_db.mediaTrackingOutbox)
          ..addColumns(<Expression>[count]))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> markSucceeded(MediaTrackingOutboxRow sent) => (_db
          .delete(_db.mediaTrackingOutbox)
        ..where(
            (t) => t.id.equals(sent.id) & t.updatedAt.equals(sent.updatedAt)))
      .go();

  Future<void> markFailed(
    MediaTrackingOutboxRow sent,
    Object error, {
    int? nowMs,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final int attempts = sent.attemptCount + 1;
    // 30s, 1m, 2m… 最长 6h；设置页“立即同步”会忽略此门槛主动重置。
    final int backoffSeconds =
        math.min(6 * 60 * 60, 30 * math.pow(2, attempts - 1).toInt());
    final String message = error.toString();
    await (_db.update(_db.mediaTrackingOutbox)
          ..where(
              (t) => t.id.equals(sent.id) & t.updatedAt.equals(sent.updatedAt)))
        .write(
      MediaTrackingOutboxCompanion(
        attemptCount: Value<int>(attempts),
        nextAttemptAt: Value<int>(now + backoffSeconds * 1000),
        lastError: Value<String>(
          message.length <= 500 ? message : message.substring(0, 500),
        ),
      ),
    );
  }

  Future<void> retryAllNow() => _db.update(_db.mediaTrackingOutbox).write(
        const MediaTrackingOutboxCompanion(
          nextAttemptAt: Value<int>(0),
        ),
      );
}
