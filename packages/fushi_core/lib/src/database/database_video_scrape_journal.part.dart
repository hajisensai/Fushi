// 视频库刮削展示层的「变了哪些作品」日志（拍板 design-nmv-video16-scrape-refresh）。
//
// [FushiDatabase.watchVideoScrapePresentationChanged] 只说「这几张表变了」，不说
// 变了哪几行，消费方（视频库页）只能整表重读重算。大库刮削批次里每 2 s 一轮，
// 3000 行实测每轮占 UI isolate 中位 19.8 ms / P95 35.3 ms（PR #3829 测量组 m3）。
//
// 这里用本连接的 TEMP 表 + TEMP 触发器记下每次写入碰到的**归属键**（视频 uid /
// 合集 id / 作品 id / 「外部身份变了」），消费方按游标只取自己上次以来的增量，
// 只重读这些键的行。触发器挂在 SQLite 层，任何写入路径（DAO、customStatement、
// 外键级联、全量清理）都逃不掉，不靠写入方各自记得登记。
//
// - TEMP 对象只活在本连接里、不进 schema、不进备份；库是单连接
//   （`NativeDatabase.createInBackground`，无读连接池），所有写入都经过它。
// - 连接重开（备份恢复 / 换库）后 TEMP 对象消失：重新安装时换一个新 epoch，旧游标
//   读到 null，消费方退回整表重读，不会漏。
// - 只有第一次有消费方要游标时才安装，没人用就零开销。
part of 'database.dart';

/// 日志游标：[epoch] 标识这一份日志（连接重开 / 重装后换新），[seq] 是已消费到的
/// 序号（含）。
class VideoScrapeJournalCursor {
  const VideoScrapeJournalCursor({required this.epoch, required this.seq});

  final int epoch;
  final int seq;

  @override
  bool operator ==(Object other) =>
      other is VideoScrapeJournalCursor &&
      other.epoch == epoch &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(epoch, seq);

  @override
  String toString() => 'VideoScrapeJournalCursor($epoch, $seq)';
}

/// 自某个游标以来刮削展示层写入碰到的归属键（已去重、已把分集 / 季解析成视频 uid）。
class VideoScrapePresentationDelta {
  const VideoScrapePresentationDelta({
    required this.cursor,
    required this.bookUids,
    required this.collectionIds,
    required this.workIds,
    required this.identitiesChanged,
    required this.shelfBookUids,
  });

  /// 读完这批增量后的新游标。
  final VideoScrapeJournalCursor cursor;

  /// 按视频 uid 归属的刮削数据变了（条目刮削资料、作品 book_uid 归属、分集绑定 /
  /// 分集图 / 季号、本地特典、媒体图组）。
  final Set<String> bookUids;

  /// 按合集 id 归属的刮削数据变了（合集刮削资料、作品 collection_id 归属、媒体图组）。
  final Set<int> collectionIds;

  /// 作品自身或其作品级图片变了。
  final Set<int> workIds;

  /// 外部身份（provider identities）变了：依赖「身份 → 作品 → 合集」解析的派生
  /// （订阅行）要重算。
  final bool identitiesChanged;

  /// 书架行的标题 / 封面变了（刮削会写 `video_books.title` / `cover_path`）。
  final Set<String> shelfBookUids;

  bool get isEmpty =>
      bookUids.isEmpty &&
      collectionIds.isEmpty &&
      workIds.isEmpty &&
      !identitiesChanged &&
      shelfBookUids.isEmpty;

  /// 碰到的键总数（消费方据此判断「增量比整表重读还贵」）。
  int get keyCount =>
      bookUids.length +
      collectionIds.length +
      workIds.length +
      shelfBookUids.length;
}

/// [VideoScrapePresentationDelta] 涉及的键按当前库状态重读回来的行。
///
/// 每张表只含与增量相关的行，排序与对应的全表读取（`getAll*`）一致，好让消费方
/// 用同一套聚合逻辑算出与整表重算逐项相同的结果。
class VideoScrapePresentationRows {
  const VideoScrapePresentationRows({
    required this.scrapeMeta,
    required this.collectionScrapeMeta,
    required this.works,
    required this.workImages,
    required this.episodes,
    required this.seasons,
    required this.episodeImages,
    required this.extras,
    required this.mediaImages,
  });

  /// `book_uid ∈ bookUids` 的条目刮削资料。
  final List<VideoScrapeMetaRow> scrapeMeta;

  /// `collection_id ∈ collectionIds` 的合集刮削资料。
  final List<CollectionScrapeMetaRow> collectionScrapeMeta;

  /// `collection_id ∈ collectionIds` 或 `book_uid ∈ bookUids` 的作品，按 id 升序。
  final List<VideoMetadataWorkRow> works;

  /// `work_id ∈ workIds` 的图片，按 id 升序。
  final List<VideoMetadataImageRow> workImages;

  /// `book_uid ∈ bookUids` 的分集，按 (season_id, episode_number, id)。
  final List<VideoMetadataEpisodeRow> episodes;

  /// 上面那些分集所在的季。
  final List<VideoMetadataSeasonRow> seasons;

  /// 上面那些分集的分集图，按 id 升序。
  final List<VideoMetadataImageRow> episodeImages;

  /// `book_uid ∈ bookUids` 的本地特典。
  final List<VideoMetadataExtraRow> extras;

  /// `collection_id ∈ collectionIds` 或 `book_uid ∈ bookUids` 的媒体图组，按
  /// [compareMediaImagesForDisplay]。
  final List<MediaImageRow> mediaImages;
}

/// 媒体图组的展示顺序：kind → position → id（id 兜底，同位次也有确定顺序）。
/// 全表读取 [FushiDatabase.getAllMediaImages] 与增量重读同一口径。
int compareMediaImagesForDisplay(MediaImageRow a, MediaImageRow b) {
  final int byKind = a.kind.compareTo(b.kind);
  if (byKind != 0) return byKind;
  final int byPosition = a.position.compareTo(b.position);
  if (byPosition != 0) return byPosition;
  return a.id.compareTo(b.id);
}

/// 分集的展示顺序：season_id → episode_number → id。全表读取
/// [FushiDatabase.getAllVideoMetadataEpisodes] 与增量重读同一口径。
int compareVideoMetadataEpisodesForDisplay(
  VideoMetadataEpisodeRow a,
  VideoMetadataEpisodeRow b,
) {
  final int bySeason = a.seasonId.compareTo(b.seasonId);
  if (bySeason != 0) return bySeason;
  final int byNumber = a.episodeNumber.compareTo(b.episodeNumber);
  if (byNumber != 0) return byNumber;
  return a.id.compareTo(b.id);
}

/// 日志里的键种类（TEMP 表 `kind` 列）。
abstract final class _ScrapeJournalKind {
  static const int book = 1;
  static const int collection = 2;
  static const int work = 3;
  static const int episode = 4;
  static const int season = 5;
  static const int identity = 6;
  static const int shelf = 7;
}

/// 日志最多保留的行数。超出时丢最旧的，并把下限抬上去：游标落在下限之前的
/// 消费方读到 null、退回整表重读（长时间不消费的页面不会让 TEMP 表无限长）。
const int _kVideoScrapeJournalRetainRows = 50000;

const String _kScrapeJournalTable = 'fushi_video_scrape_journal';
const String _kScrapeJournalMetaTable = 'fushi_video_scrape_journal_meta';

/// 一条触发器要记的键：`(kind, int 表达式, text 表达式)`，表达式里用 NEW / OLD。
typedef _ScrapeJournalKey = (int kind, String intExpr, String textExpr);

mixin _FushiDbVideoScrapeJournal on _$FushiDatabase {
  /// 当前日志尾部的游标；日志还没装就先装上。
  ///
  /// 消费方在**发起整表读取之前**取一次：整表读到的快照至少包含这个游标之前的
  /// 全部写入，之后的写入由 [readVideoScrapePresentationDelta] 补上。
  Future<VideoScrapeJournalCursor> videoScrapePresentationJournalCursor() =>
      transaction(() async {
        final int epoch = await _ensureVideoScrapeJournal();
        return VideoScrapeJournalCursor(
          epoch: epoch,
          seq: await _videoScrapeJournalHead(),
        );
      });

  /// 自 [since] 以来的增量。日志重装过（epoch 不符）或 [since] 之后的行已被裁掉时
  /// 返回 null：增量不完整，消费方必须整表重读。
  Future<VideoScrapePresentationDelta?> readVideoScrapePresentationDelta(
    VideoScrapeJournalCursor since,
  ) => transaction(() async {
    final int epoch = await _ensureVideoScrapeJournal();
    if (epoch != since.epoch) return null;
    final QueryRow meta = await customSelect(
      'SELECT floor FROM temp.$_kScrapeJournalMetaTable',
    ).getSingle();
    if (since.seq < meta.read<int>('floor')) return null;
    final int head = await _videoScrapeJournalHead();
    final Set<String> bookUids = <String>{};
    final Set<int> collectionIds = <int>{};
    final Set<int> workIds = <int>{};
    final Set<int> episodeIds = <int>{};
    final Set<int> seasonIds = <int>{};
    final Set<String> shelfBookUids = <String>{};
    bool identitiesChanged = false;
    if (head > since.seq) {
      final List<QueryRow> rows = await customSelect(
        'SELECT DISTINCT kind, int_key, text_key '
        'FROM temp.$_kScrapeJournalTable WHERE seq > ? AND seq <= ?',
        variables: <Variable<Object>>[
          Variable<int>(since.seq),
          Variable<int>(head),
        ],
      ).get();
      for (final QueryRow row in rows) {
        final int? intKey = row.readNullable<int>('int_key');
        final String? textKey = row.readNullable<String>('text_key');
        switch (row.read<int>('kind')) {
          case _ScrapeJournalKind.book:
            if (textKey != null) bookUids.add(textKey);
          case _ScrapeJournalKind.collection:
            if (intKey != null) collectionIds.add(intKey);
          case _ScrapeJournalKind.work:
            if (intKey != null) workIds.add(intKey);
          case _ScrapeJournalKind.episode:
            if (intKey != null) episodeIds.add(intKey);
          case _ScrapeJournalKind.season:
            if (intKey != null) seasonIds.add(intKey);
          case _ScrapeJournalKind.identity:
            identitiesChanged = true;
          case _ScrapeJournalKind.shelf:
            if (textKey != null) shelfBookUids.add(textKey);
        }
      }
      // 分集图 / 季号变了 → 落到这些分集当前绑定的视频上。分集被删（或改绑）时
      // 分集表自己的触发器已记下旧 book_uid，这里只需解析仍存在的。
      bookUids.addAll(await _episodeBookUids(episodeIds, seasonIds));
    }
    await _pruneVideoScrapeJournal(head);
    return VideoScrapePresentationDelta(
      cursor: VideoScrapeJournalCursor(epoch: epoch, seq: head),
      bookUids: bookUids,
      collectionIds: collectionIds,
      workIds: workIds,
      identitiesChanged: identitiesChanged,
      shelfBookUids: shelfBookUids,
    );
  });

  /// 按 [delta] 涉及的键重读当前行（见 [VideoScrapePresentationRows]）。
  Future<VideoScrapePresentationRows> getVideoScrapePresentationRows(
    VideoScrapePresentationDelta delta,
  ) async {
    final List<VideoScrapeMetaRow> scrapeMeta = <VideoScrapeMetaRow>[];
    final List<VideoMetadataExtraRow> extras = <VideoMetadataExtraRow>[];
    final List<VideoMetadataEpisodeRow> episodes = <VideoMetadataEpisodeRow>[];
    final Map<int, VideoMetadataWorkRow> workRows =
        <int, VideoMetadataWorkRow>{};
    final Map<int, MediaImageRow> mediaImageRows = <int, MediaImageRow>{};
    for (final List<String> chunk in _journalChunks<String>(
      delta.bookUids.toList(growable: false),
    )) {
      scrapeMeta.addAll(
        await (select(
          videoScrapeMeta,
        )..where(($VideoScrapeMetaTable t) => t.bookUid.isIn(chunk))).get(),
      );
      extras.addAll(
        await (select(
          videoMetadataExtras,
        )..where(($VideoMetadataExtrasTable t) => t.bookUid.isIn(chunk))).get(),
      );
      episodes.addAll(
        await (select(videoMetadataEpisodes)
              ..where(($VideoMetadataEpisodesTable t) => t.bookUid.isIn(chunk)))
            .get(),
      );
      for (final VideoMetadataWorkRow row in await (select(
        videoMetadataWorks,
      )..where(($VideoMetadataWorksTable t) => t.bookUid.isIn(chunk))).get()) {
        workRows[row.id] = row;
      }
      for (final MediaImageRow row in await (select(
        mediaImages,
      )..where(($MediaImagesTable t) => t.bookUid.isIn(chunk))).get()) {
        mediaImageRows[row.id] = row;
      }
    }
    final List<CollectionScrapeMetaRow> collectionScrapeMetaRows =
        <CollectionScrapeMetaRow>[];
    for (final List<int> chunk in _journalChunks<int>(
      delta.collectionIds.toList(growable: false),
    )) {
      collectionScrapeMetaRows.addAll(
        await (select(collectionScrapeMeta)..where(
              ($CollectionScrapeMetaTable t) => t.collectionId.isIn(chunk),
            ))
            .get(),
      );
      for (final VideoMetadataWorkRow row
          in await (select(videoMetadataWorks)..where(
                ($VideoMetadataWorksTable t) => t.collectionId.isIn(chunk),
              ))
              .get()) {
        workRows[row.id] = row;
      }
      for (final MediaImageRow row in await (select(
        mediaImages,
      )..where(($MediaImagesTable t) => t.collectionId.isIn(chunk))).get()) {
        mediaImageRows[row.id] = row;
      }
    }
    final List<VideoMetadataImageRow> workImages = <VideoMetadataImageRow>[];
    for (final List<int> chunk in _journalChunks<int>(
      delta.workIds.toList(growable: false),
    )) {
      workImages.addAll(
        await (select(
          videoMetadataImages,
        )..where(($VideoMetadataImagesTable t) => t.workId.isIn(chunk))).get(),
      );
    }
    final List<VideoMetadataImageRow> episodeImages = <VideoMetadataImageRow>[];
    for (final List<int> chunk in _journalChunks<int>(<int>[
      for (final VideoMetadataEpisodeRow e in episodes) e.id,
    ])) {
      episodeImages.addAll(
        await (select(videoMetadataImages)
              ..where(($VideoMetadataImagesTable t) => t.episodeId.isIn(chunk)))
            .get(),
      );
    }
    final List<VideoMetadataSeasonRow> seasons = <VideoMetadataSeasonRow>[];
    for (final List<int> chunk in _journalChunks<int>(
      <int>{
        for (final VideoMetadataEpisodeRow e in episodes) e.seasonId,
      }.toList(growable: false),
    )) {
      seasons.addAll(
        await (select(
          videoMetadataSeasons,
        )..where(($VideoMetadataSeasonsTable t) => t.id.isIn(chunk))).get(),
      );
    }

    int imageById(VideoMetadataImageRow a, VideoMetadataImageRow b) =>
        a.id.compareTo(b.id);
    episodes.sort(compareVideoMetadataEpisodesForDisplay);
    workImages.sort(imageById);
    episodeImages.sort(imageById);
    return VideoScrapePresentationRows(
      scrapeMeta: scrapeMeta,
      collectionScrapeMeta: collectionScrapeMetaRows,
      works: workRows.values.toList()
        ..sort(
          (VideoMetadataWorkRow a, VideoMetadataWorkRow b) =>
              a.id.compareTo(b.id),
        ),
      workImages: workImages,
      episodes: episodes,
      seasons: seasons,
      episodeImages: episodeImages,
      extras: extras,
      mediaImages: mediaImageRows.values.toList()
        ..sort(compareMediaImagesForDisplay),
    );
  }

  /// 本连接上的日志是否已安装（测试 / 诊断用）。
  Future<bool> videoScrapeJournalInstalled() async => (await customSelect(
    "SELECT 1 FROM sqlite_temp_master WHERE type = 'table' AND name = ?",
    variables: <Variable<Object>>[Variable<String>(_kScrapeJournalMetaTable)],
  ).get()).isNotEmpty;

  /// 装上日志（已装则不动），返回本份日志的 epoch。调用方须在事务里。
  Future<int> _ensureVideoScrapeJournal() async {
    if (await videoScrapeJournalInstalled()) {
      final QueryRow meta = await customSelect(
        'SELECT epoch FROM temp.$_kScrapeJournalMetaTable',
      ).getSingle();
      return meta.read<int>('epoch');
    }
    await customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS $_kScrapeJournalTable ('
      'seq INTEGER PRIMARY KEY AUTOINCREMENT, '
      'kind INTEGER NOT NULL, int_key INTEGER, text_key TEXT)',
    );
    for (final String sql in _videoScrapeJournalTriggerSql()) {
      await customStatement(sql);
    }
    // epoch 取安装时刻（微秒）：同一进程里连接重开后装的新日志必然不同。
    final int epoch = DateTime.now().microsecondsSinceEpoch;
    await customStatement(
      'CREATE TEMP TABLE $_kScrapeJournalMetaTable '
      '(epoch INTEGER NOT NULL, floor INTEGER NOT NULL)',
    );
    await customStatement(
      'INSERT INTO temp.$_kScrapeJournalMetaTable (epoch, floor) VALUES (?, 0)',
      <Object>[epoch],
    );
    return epoch;
  }

  /// 已发出的最大序号。表被裁空时 `MAX(seq)` 为 NULL，改读 AUTOINCREMENT 的已发号，
  /// 游标不会倒退。
  Future<int> _videoScrapeJournalHead() async {
    final QueryRow? row = await customSelect(
      'SELECT seq FROM temp.sqlite_sequence WHERE name = ?',
      variables: <Variable<Object>>[Variable<String>(_kScrapeJournalTable)],
    ).getSingleOrNull();
    return row?.read<int>('seq') ?? 0;
  }

  Future<void> _pruneVideoScrapeJournal(int head) async {
    final int floor = head - _kVideoScrapeJournalRetainRows;
    if (floor <= 0) return;
    await customStatement(
      'DELETE FROM temp.$_kScrapeJournalTable WHERE seq <= ?',
      <Object>[floor],
    );
    await customStatement(
      'UPDATE temp.$_kScrapeJournalMetaTable SET floor = MAX(floor, ?)',
      <Object>[floor],
    );
  }

  Future<Set<String>> _episodeBookUids(
    Set<int> episodeIds,
    Set<int> seasonIds,
  ) async {
    final Set<String> out = <String>{};
    for (final List<int> chunk in _journalChunks<int>(
      episodeIds.toList(growable: false),
    )) {
      for (final VideoMetadataEpisodeRow row in await (select(
        videoMetadataEpisodes,
      )..where(($VideoMetadataEpisodesTable t) => t.id.isIn(chunk))).get()) {
        if (row.bookUid case final String uid) out.add(uid);
      }
    }
    for (final List<int> chunk in _journalChunks<int>(
      seasonIds.toList(growable: false),
    )) {
      for (final VideoMetadataEpisodeRow row
          in await (select(videoMetadataEpisodes)..where(
                ($VideoMetadataEpisodesTable t) => t.seasonId.isIn(chunk),
              ))
              .get()) {
        if (row.bookUid case final String uid) out.add(uid);
      }
    }
    return out;
  }

  static List<List<T>> _journalChunks<T>(List<T> items) =>
      _chunkForSqlVariables<T>(items, _kVideoDeleteChunkSize);

  /// 每张展示层表写入后记下的键。UPDATE 新旧两份都记（改归属时旧主人也要重算）。
  static List<String> _videoScrapeJournalTriggerSql() {
    final List<String> out = <String>[];
    void table(
      String name,
      List<_ScrapeJournalKey> Function(String row) keys, {
      List<String> ops = const <String>['INSERT', 'UPDATE', 'DELETE'],
      String? updateOf,
    }) {
      for (final String op in ops) {
        final List<String> rows = switch (op) {
          'INSERT' => <String>['NEW'],
          'DELETE' => <String>['OLD'],
          _ => <String>['OLD', 'NEW'],
        };
        // 每个键一条 INSERT … SELECT … WHERE 非空（NULL 归属不记）。
        final String body = <String>[
          for (final String row in rows)
            for (final _ScrapeJournalKey key in keys(row))
              'INSERT INTO temp.$_kScrapeJournalTable (kind, int_key, text_key) '
                  'SELECT ${key.$1}, ${key.$2}, ${key.$3} '
                  'WHERE ${key.$2} IS NOT NULL OR ${key.$3} IS NOT NULL;',
        ].join(' ');
        final String event = op == 'UPDATE' && updateOf != null
            ? 'UPDATE OF $updateOf'
            : op;
        out.add(
          'CREATE TEMP TRIGGER IF NOT EXISTS '
          'fushi_vsj_${name}_${op.toLowerCase()} '
          'AFTER $event ON $name BEGIN $body END',
        );
      }
    }

    _ScrapeJournalKey book(String row) =>
        (_ScrapeJournalKind.book, 'NULL', '$row.book_uid');
    _ScrapeJournalKey collection(String row) =>
        (_ScrapeJournalKind.collection, '$row.collection_id', 'NULL');
    _ScrapeJournalKey work(String row, String column) =>
        (_ScrapeJournalKind.work, '$row.$column', 'NULL');

    table('video_scrape_meta', (String r) => <_ScrapeJournalKey>[book(r)]);
    table(
      'collection_scrape_meta',
      (String r) => <_ScrapeJournalKey>[collection(r)],
    );
    table(
      'media_images',
      (String r) => <_ScrapeJournalKey>[collection(r), book(r)],
    );
    table(
      'video_metadata_works',
      (String r) => <_ScrapeJournalKey>[work(r, 'id'), collection(r), book(r)],
    );
    table(
      'video_metadata_provider_identities',
      (String r) => <_ScrapeJournalKey>[
        (_ScrapeJournalKind.identity, '0', 'NULL'),
      ],
    );
    table(
      'video_metadata_seasons',
      (String r) => <_ScrapeJournalKey>[
        (_ScrapeJournalKind.season, '$r.id', 'NULL'),
      ],
    );
    table(
      'video_metadata_episodes',
      (String r) => <_ScrapeJournalKey>[book(r)],
    );
    table(
      'video_metadata_images',
      (String r) => <_ScrapeJournalKey>[
        work(r, 'work_id'),
        (_ScrapeJournalKind.episode, '$r.episode_id', 'NULL'),
      ],
    );
    table('video_metadata_extras', (String r) => <_ScrapeJournalKey>[book(r)]);
    // 书架行只关心标题 / 封面的改动（刮削会写）；插入删除归 uid 流管。
    table(
      'video_books',
      (String r) => <_ScrapeJournalKey>[
        (_ScrapeJournalKind.shelf, 'NULL', '$r.book_uid'),
      ],
      ops: const <String>['UPDATE'],
      updateOf: 'title, cover_path',
    );
    return out;
  }
}
