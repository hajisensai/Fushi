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

typedef AutoVideoTrackingSource = ({
  String mediaTitle,
  String videoTitle,
  int? bangumiSubjectId,
  String? bangumiSubjectName,
  int? bangumiEpisodeCount,
});

typedef AutoBookTrackingSource = ({
  String title,
  String format,
});

typedef CompletedVideoTrackingProgress = ({
  TrackingMediaType mediaType,
  String mediaKey,
  int localProgress,
  bool completed,
  int evidenceAt,
});

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

  /// 自动识别只能补空白，绝不覆盖用户已经确认或手工修正过的映射。
  ///
  /// 唯一键冲突用 `insertOrIgnore` 收敛并发：播放器完成回调、阅读 debounce 和设置页
  /// 手工保存可能同时到达；最终以先落库者为准，自动路径不会把人工选择改回去。
  Future<MediaTrackingMappingRow> saveMappingIfAbsent({
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
    final MediaTrackingMappingRow? existing = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (existing != null) return existing;
    if (mediaKey.trim().isEmpty || subjectId <= 0 || progressOffset < 0) {
      throw ArgumentError('Invalid automatic media tracking mapping');
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.into(_db.mediaTrackingMappings).insert(
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
          mode: InsertMode.insertOrIgnore,
        );
    final MediaTrackingMappingRow? saved = await findMapping(
      mediaType: mediaType,
      mediaKey: mediaKey,
      provider: provider,
    );
    if (saved == null) {
      throw StateError('Automatic media tracking mapping was not persisted');
    }
    return saved;
  }

  /// 播放完成时用于自动映射的本地事实。优先返回视频刮削已确认的 Bangumi id；
  /// TMDB/offlineDb/manualUrl 的 id 不是 Bangumi subject id，必须丢弃，不能串源误写。
  Future<AutoVideoTrackingSource?> loadAutoVideoSource({
    required String bookUid,
    int? collectionId,
  }) async {
    final VideoBookRow? video = await _db.getVideoBookByBookUid(bookUid);
    if (video == null) return null;
    final MediaCollectionRow? collection = collectionId == null
        ? null
        : await _db.getMediaCollectionById(collectionId);
    final VideoScrapeMetaRow? scrape = await _db.getVideoScrapeMeta(bookUid);
    final bool isBangumi = scrape?.source == kTrackingProviderBangumi;
    final String collectionTitle = collection?.name.trim() ?? '';
    return (
      mediaTitle: collectionTitle.isEmpty ? video.title : collectionTitle,
      videoTitle: video.title,
      bangumiSubjectId:
          isBangumi ? int.tryParse(scrape!.subjectId.trim()) : null,
      bangumiSubjectName: isBangumi ? scrape!.title : null,
      bangumiEpisodeCount: isBangumi ? scrape!.episodeCount : null,
    );
  }

  Future<AutoBookTrackingSource?> loadAutoBookSource(String bookKey) async {
    final EpubBookRow? book = await _db.getEpubBook(bookKey);
    if (book == null) return null;
    return (title: book.title, format: book.format);
  }

  /// 返回自 [afterMs] 之后新增或重新映射的本地已完成视频进度。
  ///
  /// 旧版只在跨过 90% 阈值的瞬间发同步事件；状态语义修正后，已经完成且 outbox
  /// 早已清空的条目不会再自然触发。这里从 `completed_at` 的本地事实重建一次增量，
  /// 同时把 mapping.updatedAt 纳入 evidence，使“给旧完成条目新增/修改映射”也会补发。
  Future<List<CompletedVideoTrackingProgress>>
      loadCompletedVideoTrackingProgress({
    required int afterMs,
  }) async {
    final List<MediaTrackingMappingRow> mappings = await listMappings();
    final List<CompletedVideoTrackingProgress> result =
        <CompletedVideoTrackingProgress>[];

    for (final MediaTrackingMappingRow mapping in mappings) {
      if (mapping.provider != kTrackingProviderBangumi ||
          mapping.progressMode != TrackingProgressMode.episode.value) {
        continue;
      }

      if (mapping.mediaType == TrackingMediaType.video.value) {
        final VideoBookRow? video =
            await _db.getVideoBookByBookUid(mapping.mediaKey);
        final DateTime? completedAt = video?.completedAt;
        if (completedAt == null) continue;
        final int evidenceAt =
            math.max(mapping.updatedAt, completedAt.millisecondsSinceEpoch);
        if (evidenceAt <= afterMs) continue;
        result.add((
          mediaType: TrackingMediaType.video,
          mediaKey: mapping.mediaKey,
          localProgress: 0,
          completed: true,
          evidenceAt: evidenceAt,
        ));
        continue;
      }

      if (mapping.mediaType != TrackingMediaType.videoCollection.value) {
        continue;
      }
      final int? collectionId = int.tryParse(mapping.mediaKey);
      if (collectionId == null) continue;
      final List<MediaCollectionItemRow> items =
          (await _db.getCollectionItems(collectionId))
              .where((MediaCollectionItemRow item) =>
                  item.mediaType == MediaKind.video.dbValue)
              .toList(growable: false);
      int highestCompletedIndex = -1;
      int latestCompletedAt = 0;
      for (int index = 0; index < items.length; index++) {
        final VideoBookRow? video =
            await _db.getVideoBookByBookUid(items[index].entryKey);
        final DateTime? completedAt = video?.completedAt;
        if (completedAt == null) continue;
        highestCompletedIndex = index;
        latestCompletedAt =
            math.max(latestCompletedAt, completedAt.millisecondsSinceEpoch);
      }
      if (highestCompletedIndex < 0) continue;
      final int evidenceAt = math.max(mapping.updatedAt, latestCompletedAt);
      if (evidenceAt <= afterMs) continue;
      result.add((
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: mapping.mediaKey,
        localProgress: highestCompletedIndex,
        completed: highestCompletedIndex == items.length - 1,
        evidenceAt: evidenceAt,
      ));
    }
    return result;
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
