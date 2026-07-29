import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:hibiki/src/mining/metadata/galgame_metadata_source.dart';
import 'package:hibiki_core/hibiki_core.dart';

const String kTrackingProviderBangumi = 'bangumi';

enum TrackingMediaType {
  book('book'),
  bookChapter('book_chapter'),
  video('video'),
  videoCollection('video_collection'),
  game('game');

  const TrackingMediaType(this.value);
  final String value;
}

enum TrackingKind {
  anime('anime'),
  novel('novel'),
  manga('manga'),
  game('game');

  const TrackingKind(this.value);
  final String value;
}

enum TrackingProgressMode {
  episode('episode'),
  chapter('chapter'),
  volume('volume'),

  /// 只同步收藏状态，没有话数/卷数进度。
  ///
  /// Bangumi 游戏条目 `eps`/`volumes` 恒为 0，唯一可写的是收藏 `type`。此模式下
  /// [MediaTrackingOutboxRow.progress] 存的**不是进度而是 Bangumi 收藏 type**
  /// （1 想玩 / 2 玩过 / 3 在玩 / 4 搁置 / 5 弃坑），由本字段唯一确定其解释方式，
  /// 与 episode/chapter/volume 决定 progress 落 `ep_status` 还是 `vol_status` 同构。
  status('status');

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

typedef AutoGameTrackingSource = ({
  String name,
  int? bangumiSubjectId,
});

typedef PersistedGameTrackingStatus = ({
  String gameId,
  String name,
  int? bangumiSubjectId,
  int status,
  int evidenceAt,
});

typedef CompletedVideoTrackingProgress = ({
  TrackingMediaType mediaType,
  String mediaKey,
  int localProgress,
  bool completed,
  int evidenceAt,
});

typedef PersistedBookTrackingProgress = ({
  String mediaKey,
  TrackingMediaType mediaType,
  int localProgress,
  bool completed,
  int evidenceAt,
});

/// 本地已经产生过可同步进度、但尚未建立 Bangumi 映射的条目。
///
/// 这份列表专供 UI 明确指出「哪些需要手动关联」。它与映射表是互补关系，不把
/// “没有映射”误写成“没有看过/读过”。
class MediaTrackingUnlinkedItem {
  const MediaTrackingUnlinkedItem({
    required this.mediaType,
    required this.mediaKey,
    required this.mediaTitle,
    required this.kind,
    required this.lastActivityAt,
  });

  final TrackingMediaType mediaType;
  final String mediaKey;
  final String mediaTitle;
  final TrackingKind kind;
  final int lastActivityAt;
}

final RegExp _ignoredBookTocLabel = RegExp(
  r'^(?:目次|目录|目錄|contents?|table\s+of\s+contents|扉|title\s+page|表紙|cover|奥付|版权|版權|colophon|口絵|イラスト|插图|插圖|あとがき|后记|後記|著者紹介)$',
  caseSensitive: false,
);

String _normalizeBookHref(String value) {
  String path = value.split('#').first.split('?').first.replaceAll(r'\', '/');
  try {
    path = Uri.decodeComponent(path);
  } on ArgumentError {
    // Malformed percent escapes are kept verbatim, matching EPUB navigation.
  }
  final List<String> parts = <String>[];
  for (final String part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  return parts.join('/').toLowerCase();
}

/// 将 EPUB spine 位置保守换算为目录中的逻辑章节数。
///
/// Bangumi 的 `ep_status` 是作品“话数”，不能直接使用 EPUB 的 XHTML/spine 数量。
/// 只把已经越过的 TOC 项计为完成；同一 XHTML 内的多个锚点要等离开该 XHTML（或
/// 整本完成）才一并计入，宁可稍晚同步也不提前虚报。
int estimateCompletedBookChapters({
  required String chaptersJson,
  required String? tocJson,
  required int sectionIndex,
  required bool sectionCompleted,
  required bool bookCompleted,
  required int fallbackProgress,
}) {
  if (tocJson == null || tocJson.trim().isEmpty) {
    return math.max(0, fallbackProgress);
  }
  try {
    final dynamic chaptersValue = jsonDecode(chaptersJson);
    final dynamic tocValue = jsonDecode(tocJson);
    if (chaptersValue is! List || tocValue is! List) {
      return math.max(0, fallbackProgress);
    }
    final Map<String, int> chapterIndexes = <String, int>{};
    for (int index = 0; index < chaptersValue.length; index++) {
      final dynamic item = chaptersValue[index];
      if (item is! Map) continue;
      final String href = '${item['href'] ?? ''}'.trim();
      if (href.isEmpty) continue;
      chapterIndexes.putIfAbsent(_normalizeBookHref(href), () => index);
    }
    final List<int> tocIndexes = <int>[];
    final Set<String> seen = <String>{};

    void collect(dynamic value) {
      if (value is! List) return;
      for (final dynamic item in value) {
        if (item is! Map) continue;
        final String label = '${item['title'] ?? item['label'] ?? ''}'.trim();
        final String href = '${item['href'] ?? ''}'.trim();
        final String normalizedHref = _normalizeBookHref(href);
        final int? index = chapterIndexes[normalizedHref];
        final String identity = '$normalizedHref\u0000$label';
        if (index != null &&
            !_ignoredBookTocLabel.hasMatch(label) &&
            seen.add(identity)) {
          tocIndexes.add(index);
        }
        collect(item['children']);
      }
    }

    collect(tocValue);
    if (tocIndexes.isEmpty) return math.max(0, fallbackProgress);
    if (bookCompleted) return tocIndexes.length;
    return tocIndexes
        .where(
          (int index) =>
              index < sectionIndex ||
              (sectionCompleted && index == sectionIndex),
        )
        .length;
  } on FormatException {
    return math.max(0, fallbackProgress);
  }
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

  /// 列出全部「已有本地观看/阅读/游玩事实，但没有 Bangumi 映射」的条目。
  ///
  /// 视频合集优先于成员：同一季已经放进 playlist 时只提示一次合集，避免把十二集
  /// 全部写成十二条“需手动关联”。未归合集的已完成视频仍按单条列出。
  Future<List<MediaTrackingUnlinkedItem>> listUnlinkedHistory() async {
    final Set<String> mapped = <String>{
      for (final MediaTrackingMappingRow row in await listMappings())
        '${row.mediaType}|${row.mediaKey}',
    };
    bool isMapped(TrackingMediaType type, String key) =>
        mapped.contains('${type.value}|$key');

    final List<VideoBookRow> videos = await _db.allVideoBooks();
    final Map<String, VideoBookRow> videosByUid = <String, VideoBookRow>{
      for (final VideoBookRow video in videos) video.bookUid: video,
    };
    final List<MediaCollectionRow> collections =
        await _db.getAllMediaCollections();
    final List<MediaCollectionItemRow> members =
        await _db.getAllCollectionItems();
    final Map<int, List<MediaCollectionItemRow>> videoMembersByCollection =
        <int, List<MediaCollectionItemRow>>{};
    for (final MediaCollectionItemRow member in members) {
      if (member.mediaType != MediaKind.video.dbValue) continue;
      videoMembersByCollection
          .putIfAbsent(member.collectionId, () => <MediaCollectionItemRow>[])
          .add(member);
    }

    final List<MediaTrackingUnlinkedItem> result =
        <MediaTrackingUnlinkedItem>[];
    final Set<String> videosCoveredByPlaylist = <String>{};
    for (final MediaCollectionRow collection in collections) {
      final String key = collection.id.toString();
      if (collection.collectionType != 'playlist' ||
          !isMapped(TrackingMediaType.videoCollection, key)) {
        continue;
      }
      for (final MediaCollectionItemRow member
          in videoMembersByCollection[collection.id] ??
              const <MediaCollectionItemRow>[]) {
        if (videosByUid[member.entryKey]?.completedAt != null) {
          videosCoveredByPlaylist.add(member.entryKey);
        }
      }
    }
    for (final MediaCollectionRow collection in collections) {
      if (collection.collectionType != 'playlist') continue;
      final String key = collection.id.toString();
      if (isMapped(TrackingMediaType.videoCollection, key)) continue;
      final List<MediaCollectionItemRow> collectionMembers =
          videoMembersByCollection[collection.id] ??
              const <MediaCollectionItemRow>[];
      int lastCompletedAt = 0;
      final Set<String> completedMembers = <String>{};
      for (final MediaCollectionItemRow member in collectionMembers) {
        final VideoBookRow? video = videosByUid[member.entryKey];
        final DateTime? completedAt = video?.completedAt;
        if (completedAt == null ||
            videosCoveredByPlaylist.contains(member.entryKey) ||
            isMapped(TrackingMediaType.video, member.entryKey)) {
          continue;
        }
        completedMembers.add(member.entryKey);
        lastCompletedAt =
            math.max(lastCompletedAt, completedAt.millisecondsSinceEpoch);
      }
      if (completedMembers.isEmpty) continue;
      videosCoveredByPlaylist.addAll(completedMembers);
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: key,
          mediaTitle: collection.name,
          kind: TrackingKind.anime,
          lastActivityAt: lastCompletedAt,
        ),
      );
    }

    for (final VideoBookRow video in videos) {
      final DateTime? completedAt = video.completedAt;
      if (completedAt == null ||
          videosCoveredByPlaylist.contains(video.bookUid) ||
          isMapped(TrackingMediaType.video, video.bookUid)) {
        continue;
      }
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.video,
          mediaKey: video.bookUid,
          mediaTitle: video.title,
          kind: TrackingKind.anime,
          lastActivityAt: completedAt.millisecondsSinceEpoch,
        ),
      );
    }

    final Map<String, ReaderPositionRow> positions =
        <String, ReaderPositionRow>{
      for (final ReaderPositionRow position
          in await _db.getAllReaderPositions())
        position.bookKey: position,
    };
    for (final EpubBookRow book in await _db.getAllEpubBooks()) {
      final ReaderPositionRow? position = positions[book.bookKey];
      final DateTime? completedAt = book.completedAt;
      if ((position == null && completedAt == null) ||
          isMapped(TrackingMediaType.book, book.bookKey)) {
        continue;
      }
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.book,
          mediaKey: book.bookKey,
          mediaTitle: book.title,
          kind: BookFormat.parseOrEpub(book.format) == BookFormat.manga
              ? TrackingKind.manga
              : TrackingKind.novel,
          lastActivityAt: math.max(
            position?.updatedAt ?? 0,
            completedAt?.millisecondsSinceEpoch ?? 0,
          ),
        ),
      );
    }

    for (final GalgameRow game in await _db.getAllGalgames()) {
      if (game.playStatus <= 0 || isMapped(TrackingMediaType.game, game.id)) {
        continue;
      }
      result.add(
        MediaTrackingUnlinkedItem(
          mediaType: TrackingMediaType.game,
          mediaKey: game.id,
          mediaTitle: game.name,
          kind: TrackingKind.game,
          lastActivityAt: game.addedAt,
        ),
      );
    }

    result.sort((MediaTrackingUnlinkedItem a, MediaTrackingUnlinkedItem b) {
      final int byTime = b.lastActivityAt.compareTo(a.lastActivityAt);
      return byTime != 0 ? byTime : a.mediaTitle.compareTo(b.mediaTitle);
    });
    return result;
  }

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

  /// 游戏刮削源里的 Bangumi 条目 id。
  ///
  /// `galgame_sources.source` 用的是刮削源 key（`bgm`），与本层的 provider 名
  /// （`bangumi`）不是同一个值域，不能互相套用。VNDB 的 `externalId` 形如 `v12345`，
  /// 不是 Bangumi subject id，必须按 source 过滤后再解析。
  int? _bangumiSubjectIdOf(List<GalgameSourceRow> sources) {
    for (final GalgameSourceRow row in sources) {
      if (row.source != GalgameMetadataSource.bgm.key) continue;
      final int? id = int.tryParse((row.externalId ?? '').trim());
      if (id != null && id > 0) return id;
    }
    return null;
  }

  Future<AutoGameTrackingSource?> loadAutoGameSource(String gameId) async {
    final GalgameRow? game = await _db.getGalgame(gameId);
    if (game == null) return null;
    return (
      name: game.name,
      bangumiSubjectId:
          _bangumiSubjectIdOf(await _db.getGalgameSources(gameId)),
    );
  }

  /// 返回自 [afterMs] 之后需要重新对齐的游戏收藏状态。
  ///
  /// 游戏状态是用户显式设置的离散值，正常路径在设置当下即时入队；本方法只兜两种
  /// 「事件已经发生过但当时发不出去」的情况：换账号后水位归零的全量重建，以及先设
  /// 状态、之后才刮到 Bangumi 条目或才建立映射。`galgames` 表没有「最后修改时刻」列，
  /// 因此 evidence 取 `max(mapping.updatedAt, addedAt)`——足以覆盖新增游戏与新建/
  /// 改动映射，状态本身的变更由即时入队负责，不依赖这里。
  Future<List<PersistedGameTrackingStatus>> loadPersistedGameTrackingStatus({
    required int afterMs,
  }) async {
    final List<GalgameRow> games = await _db.getAllGalgames();
    if (games.isEmpty) return const <PersistedGameTrackingStatus>[];
    final Map<String, List<GalgameSourceRow>> sources =
        await _db.getAllGalgameSources();
    final Map<String, MediaTrackingMappingRow> mappings =
        <String, MediaTrackingMappingRow>{};
    for (final MediaTrackingMappingRow mapping in await listMappings()) {
      if (mapping.provider != kTrackingProviderBangumi) continue;
      if (mapping.mediaType != TrackingMediaType.game.value) continue;
      mappings[mapping.mediaKey] = mapping;
    }

    final List<PersistedGameTrackingStatus> result =
        <PersistedGameTrackingStatus>[];
    for (final GalgameRow game in games) {
      // 0 = 未设置：用户从没表态过，不能凭空往远端写一个收藏状态。
      if (game.playStatus <= 0) continue;
      final int evidenceAt = math.max(
        mappings[game.id]?.updatedAt ?? 0,
        game.addedAt,
      );
      if (evidenceAt <= afterMs) continue;
      result.add((
        gameId: game.id,
        name: game.name,
        bangumiSubjectId:
            _bangumiSubjectIdOf(sources[game.id] ?? const <GalgameSourceRow>[]),
        status: game.playStatus,
        evidenceAt: evidenceAt,
      ));
    }
    return result;
  }

  /// 返回这本书「已读完多少章」，**null = 这本书没有章的概念，不要上报章进度**。
  ///
  /// 只有 `format='epub'` 的文字书有章。PDF / 漫画的 `chaptersJson` 是 `'[]'`、
  /// `tocJson` 是 null，阅读位置的 `sectionIndex` 存的是**页码**——旧实现在这里只
  /// 挡了 `'manga'`，PDF 一路走下去会在 [estimateCompletedBookChapters] 的
  /// 「无 toc 即早退」分支拿到 `fallbackProgress`，也就是把**当前页码当成已读章数**
  /// 报给 Bangumi。两个调用点（这里与下面 loadPersistedBookTrackingProgress）现在按
  /// 同一判据 [BookFormat.isPagedImageBook] 收口，缺一处就会重新漂开。
  Future<int?> loadBookChapterProgress({
    required String bookKey,
    required int fallbackProgress,
  }) async {
    final EpubBookRow? book = await _db.getEpubBook(bookKey);
    if (book == null) return math.max(0, fallbackProgress);
    if (BookFormat.parseOrEpub(book.format).isPagedImageBook) return null;
    final ReaderPositionRow? position = await _db.getReaderPosition(bookKey);
    if (position == null) return math.max(0, fallbackProgress);
    return estimateCompletedBookChapters(
      chaptersJson: book.chaptersJson,
      tocJson: book.tocJson,
      sectionIndex: position.sectionIndex,
      sectionCompleted: position.normCharOffset >= 9990,
      bookCompleted: book.completedAt != null,
      fallbackProgress: fallbackProgress,
    );
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

  /// 从阅读位置和书籍完成标记恢复自 [afterMs] 之后的可靠阅读事件。
  ///
  /// chapter 模式按已完成章节数恢复；volume 模式在读时用 -1 配合卷号 offset，
  /// 只报告“此前卷数”，当前卷读完才用 0 把本卷计入，避免刚打开第 N 卷就误报 N 卷。
  Future<List<PersistedBookTrackingProgress>>
      loadPersistedBookTrackingProgress({
    required int afterMs,
  }) async {
    final List<MediaTrackingMappingRow> mappings = await listMappings();
    final List<PersistedBookTrackingProgress> result =
        <PersistedBookTrackingProgress>[];
    for (final MediaTrackingMappingRow mapping in mappings) {
      final TrackingMediaType? mediaType =
          mapping.mediaType == TrackingMediaType.book.value
              ? TrackingMediaType.book
              : mapping.mediaType == TrackingMediaType.bookChapter.value
                  ? TrackingMediaType.bookChapter
                  : null;
      if (mapping.provider != kTrackingProviderBangumi || mediaType == null) {
        continue;
      }
      final EpubBookRow? book = await _db.getEpubBook(mapping.mediaKey);
      if (book == null) continue;
      final ReaderPositionRow? position =
          await _db.getReaderPosition(mapping.mediaKey);
      final DateTime? completedAt = book.completedAt;
      if (position == null && completedAt == null) continue;
      final int localEvidenceAt = math.max(
        position?.updatedAt ?? 0,
        completedAt?.millisecondsSinceEpoch ?? 0,
      );
      final int evidenceAt = math.max(mapping.updatedAt, localEvidenceAt);
      if (evidenceAt <= afterMs) continue;

      final bool isChapterCompanion =
          mediaType == TrackingMediaType.bookChapter;
      final bool isVolume =
          mapping.progressMode == TrackingProgressMode.volume.value;
      final bool completed = completedAt != null;
      final int localProgress;
      if (isChapterCompanion ||
          mapping.progressMode == TrackingProgressMode.chapter.value) {
        // 与 [loadBookChapterProgress] 同一判据：按页翻的书（PDF / 漫画）没有章，
        // 这里的 fallbackProgress 是 sectionIndex＝页码，报出去就是错数。宁可不报。
        if (BookFormat.parseOrEpub(book.format).isPagedImageBook) continue;
        localProgress = estimateCompletedBookChapters(
          chaptersJson: book.chaptersJson,
          tocJson: book.tocJson,
          sectionIndex: position?.sectionIndex ?? 0,
          sectionCompleted: (position?.normCharOffset ?? 0) >= 9990,
          bookCompleted: completed,
          fallbackProgress: (position?.sectionIndex ?? 0) +
              ((position?.normCharOffset ?? 0) >= 9990 ? 1 : 0),
        );
      } else if (isVolume) {
        localProgress = completed ? 0 : -1;
      } else {
        continue;
      }
      result.add((
        mediaKey: mapping.mediaKey,
        mediaType: mediaType,
        localProgress: localProgress,
        completed: isChapterCompanion ? false : completed,
        evidenceAt: evidenceAt,
      ));
    }
    return result;
  }

  Future<void> deleteMapping(int id) async {
    final MediaTrackingMappingRow? mapping =
        await (_db.select(_db.mediaTrackingMappings)
              ..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    if (mapping == null) return;
    if (mapping.mediaType != TrackingMediaType.book.value) {
      await (_db.delete(_db.mediaTrackingMappings)
            ..where((t) => t.id.equals(id)))
          .go();
      return;
    }
    await (_db.delete(_db.mediaTrackingMappings)
          ..where((t) =>
              t.provider.equals(mapping.provider) &
              t.mediaKey.equals(mapping.mediaKey) &
              t.mediaType.isIn(<String>[
                TrackingMediaType.book.value,
                TrackingMediaType.bookChapter.value,
              ])))
        .go();
  }

  /// 将本地 0-based [localProgress] 翻译为远端进度并入队。没有映射返回 false；
  /// 调用方据此无声跳过，播放/阅读主路径不受外部服务影响。
  ///
  /// [monotonic] 为 true（默认）时沿用“进度只增不减”的合并：观看/阅读进度天然单调，
  /// 取 max 可以让乱序到达的事件收敛到最新位置。收藏状态类事件必须传 false——它是
  /// 离散状态而非进度，取 max 会让「弃坑(5) → 在玩(3)」这种正当回退被永久吃掉，
  /// 用户再也改不回来。此时按最后写入者胜（LWW）覆盖。
  Future<bool> enqueueProgress({
    required TrackingMediaType mediaType,
    required String mediaKey,
    required int localProgress,
    required bool completed,
    bool monotonic = true,
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
      final int mergedProgress =
          monotonic ? math.max(existing.progress, progress) : progress;
      final bool mergedCompleted =
          monotonic ? (existing.completed || completed) : completed;
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

  /// 全部待同步行（**不**按 `nextAttemptAt` 过滤），带各自的映射。
  ///
  /// 与 [dueUpdates] 的区别是它服务于「展示」而不是「发送」：失败行退避最长 6 小时，
  /// 若 UI 也只看 due 的行，用户在退避窗口里看到的会是「零待办、零错误」，正好把
  /// 失败原因藏起来。按 updatedAt 倒序，最近的事件排在前面。
  Future<List<PendingTrackingUpdate>> allPending({int limit = 50}) async {
    final query = _db.select(_db.mediaTrackingOutbox).join(<Join>[
      innerJoin(
        _db.mediaTrackingMappings,
        _db.mediaTrackingMappings.id
            .equalsExp(_db.mediaTrackingOutbox.mappingId),
      ),
    ])
      ..orderBy(<OrderingTerm>[
        OrderingTerm(
          expression: _db.mediaTrackingOutbox.updatedAt,
          mode: OrderingMode.desc,
        ),
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
