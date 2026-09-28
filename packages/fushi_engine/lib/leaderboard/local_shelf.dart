// 本机书架汇总：把本地库 + 统计事实面折成排行榜的上报形状（设计 §3.2 / §3.3）。
//
// 数据来源（只读，一次性全表读，库规模是几千行量级）：
// - 字数 / 时长：`loadStatFacts(profileId:)` 的日面事实，按 (mediaKind, mediaKey) 汇总。
//   legacy 无身份行（mediaKey 为空）不归入任何作品，只进每日字数。
// - 书 / 漫画：`epub_books`（format manga → 漫画），读完 = completedAt 非空。
// - 视频：作品单位 = 刮削作品（剧 = collectionId，电影 = bookUid），无作品则按主合集，
//   再无则单个视频；读完 = 单位内全部成员都有 completedAt。
// - 游戏：`galgames`，playStatus 2 = 玩过（读完），3 = 在玩。
//
// 书 / 视频 / 游戏的库表本身不分 Profile（与库页口径一致），只有统计按 Profile 隔离。

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/work_refs.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/sync/online_novel_book.dart';

/// 书架上的一条本地作品。[localKey] 是本机稳定身份（`book:<bookKey>` /
/// `video:c<collectionId>` / `video:b<bookUid>` / `game:<id>`），同步状态按它记账。
class LocalShelfEntry {
  const LocalShelfEntry({
    required this.localKey,
    required this.upload,
    this.localCoverPath,
  });

  final String localKey;
  final ShelfEntryUpload upload;

  /// 本地封面文件（服务端缺封面时据此生成缩略图补传）。
  final String? localCoverPath;
}

class LocalShelf {
  const LocalShelf({
    required this.entries,
    required this.daily,
    this.dailyFrom,
  });

  static const LocalShelf empty = LocalShelf(
    entries: <LocalShelfEntry>[],
    daily: <DailyCharsUpload>[],
  );

  /// 服务端接受的最早日期（含，`YYYY-MM-DD`；服务端只收最近 10 年）。[daily] 已按它
  /// 过滤；同步时早于它的旧日期不发删除（会被 400），只从本地状态里忘掉。null = 不限。
  final String? dailyFrom;

  /// 按 [LocalShelfEntry.localKey] 升序。
  final List<LocalShelfEntry> entries;

  /// 每日全部种类的字数之和（只含 > 0 的日期），按日期升序。
  final List<DailyCharsUpload> daily;
}

/// 汇总 [profileId] 的本机书架。
///
/// 每日字数只保留服务端接受的窗口：最近 10 年（留一天余量）到明天（本地日可能比 UTC
/// 快一天；更晚的是坏时钟写下的数据，服务端判 future 拒收整批）。[now] 只给测试注入。
Future<LocalShelf> buildLocalShelf(
  FushiDatabase db, {
  required int profileId,
  DateTime? now,
}) async {
  final DateTime today = now ?? DateTime.now();
  final String dailyFrom = _dateKey(
    DateTime(
      today.year - kLeaderboardDailyWindowYears,
      today.month,
      today.day + 1,
    ),
  );
  final String dailyTo = _dateKey(
    DateTime(today.year, today.month, today.day + 1),
  );
  final StatFacts facts = await loadStatFacts(
    db,
    activityLimit: 0,
    profileId: profileId,
  );
  final _Totals totals = _Totals.fromFacts(facts.daily);
  final List<LocalShelfEntry> entries =
      <LocalShelfEntry>[
        ...await _bookEntries(db, totals),
        ...await _videoEntries(db, totals),
        ...await _gameEntries(db, totals),
      ]..sort(
        (LocalShelfEntry a, LocalShelfEntry b) =>
            a.localKey.compareTo(b.localKey),
      );
  return LocalShelf(
    entries: List<LocalShelfEntry>.unmodifiable(entries),
    daily: List<DailyCharsUpload>.unmodifiable(
      totals.dailyUploads().where(
        (DailyCharsUpload d) =>
            d.date.compareTo(dailyFrom) >= 0 && d.date.compareTo(dailyTo) <= 0,
      ),
    ),
    dailyFrom: dailyFrom,
  );
}

/// 服务端每日字数只收最近这么多年。
const int kLeaderboardDailyWindowYears = 10;

// ---------------------------------------------------------------------------
// 统计汇总

final RegExp _dateKeyShape = RegExp(r'^\d{4}-\d{2}-\d{2}$');

class _Totals {
  _Totals._(this._byMedia, this._charsByDate);

  factory _Totals.fromFacts(List<StatFact> facts) {
    final Map<String, (int, int)> byMedia = <String, (int, int)>{};
    final Map<String, int> charsByDate = <String, int>{};
    for (final StatFact f in facts) {
      if (f.chars > 0) {
        charsByDate[f.dateKey] = (charsByDate[f.dateKey] ?? 0) + f.chars;
      }
      if (f.mediaKey.isEmpty) continue;
      final String key = '${f.mediaKind}|${f.mediaKey}';
      final (int chars, int ms) old = byMedia[key] ?? (0, 0);
      byMedia[key] = (old.$1 + f.chars, old.$2 + f.ms);
    }
    return _Totals._(byMedia, charsByDate);
  }

  final Map<String, (int, int)> _byMedia;
  final Map<String, int> _charsByDate;

  /// (chars, ms)；负值（坏数据）夹到 0。
  (int, int) of(String mediaKind, String mediaKey) {
    final (int chars, int ms) v = _byMedia['$mediaKind|$mediaKey'] ?? (0, 0);
    return (v.$1 < 0 ? 0 : v.$1, v.$2 < 0 ? 0 : v.$2);
  }

  List<DailyCharsUpload> dailyUploads() {
    final List<String> dates =
        _charsByDate.keys
            .where(
              (String d) => _dateKeyShape.hasMatch(d) && _charsByDate[d]! > 0,
            )
            .toList()
          ..sort();
    return <DailyCharsUpload>[
      for (final String d in dates)
        DailyCharsUpload(date: d, chars: _charsByDate[d]!),
    ];
  }
}

// ---------------------------------------------------------------------------
// 共用

/// 本地日 `YYYY-MM-DD`。
String _localDate(int ms) => _dateKey(DateTime.fromMillisecondsSinceEpoch(ms));

String _dateKey(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
}

String? _nonEmpty(String? s) {
  final String? v = s?.trim();
  return v == null || v.isEmpty ? null : v;
}

String? _httpUrl(String? s) {
  final String? v = _nonEmpty(s);
  if (v == null) return null;
  final Uri? u = Uri.tryParse(v);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
  return v;
}

Map<String, Object?>? _jsonObject(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(raw);
    return decoded is Map<Object?, Object?>
        ? decoded.cast<String, Object?>()
        : null;
  } on FormatException {
    return null;
  }
}

/// 组装一条上报；refs 为空（标题归一化后为空且无任何强 ID）时返回 null——
/// 服务端必拒的形状不上报。
LocalShelfEntry? _entry({
  required String localKey,
  required LeaderboardKind kind,
  required List<String> refs,
  required String title,
  String author = '',
  String? coverUrl,
  bool nsfw = false,
  required bool finished,
  int? finishedAt,
  required int chars,
  required int ms,
  String? localCoverPath,
}) {
  if (refs.isEmpty) return null;
  return LocalShelfEntry(
    localKey: localKey,
    localCoverPath: _nonEmpty(localCoverPath),
    upload: ShelfEntryUpload(
      kind: kind,
      refs: refs,
      title: title.trim(),
      author: author.trim(),
      coverUrl: coverUrl,
      nsfw: nsfw,
      finished: finished,
      finishedAt: finishedAt,
      finishedDate: finishedAt == null ? null : _localDate(finishedAt),
      chars: chars,
      ms: ms,
    ),
  );
}

// ---------------------------------------------------------------------------
// 书 / 漫画

/// 在线漫画描述符的类型标记（app 侧 `OnlineMangaLibraryEntry.marker` /
/// `legacyMihonMarker`）。值已写进用户库的 `sourceMetadata`，永不会变。
const String _onlineMangaMarker = 'hibiki-online-manga';
const String _legacyMihonMarker = 'hibiki-mihon';

/// 互联对端被当成漫画源时的运行时标记：它的作品 key 是对端 bookKey（本机局域身份），
/// 不是跨用户可比的源内身份，不产 `src:` 键。
const String _interconnectRuntime = 'interconnect';

/// `sourceMetadata` → (`src:` 键体, 远端封面 URL)。
///
/// - 在线漫画：`<sourceId>:<series.key>`（v2/v3 描述符；v1 旧 Mihon 描述符为
///   `<sourceId>:<manga.url>`），封面取 series.coverUrl / manga.thumbnail_url；
/// - LNReader 在线小说：`<pluginId>:<novelPath>`，无远端封面。
/// 其余（普通导入书、描述符损坏）返回 (null, null)。
(String?, String?) _sourceRefAndCover(String? sourceMetadata) {
  final Map<String, Object?>? j = _jsonObject(sourceMetadata);
  if (j == null) return (null, null);
  final Object? type = j['type'];
  if (type == kLnReaderOnlineBookMarker) {
    final String? plugin = _nonEmpty(j['pluginId']?.toString());
    final String? path = _nonEmpty(j['novelPath']?.toString());
    return (plugin == null || path == null ? null : '$plugin:$path', null);
  }
  final Object? series = type == _onlineMangaMarker
      ? j['series']
      : (type == _legacyMihonMarker ? j['manga'] : null);
  if (series is! Map<Object?, Object?>) return (null, null);
  if (j['runtime']?.toString() == _interconnectRuntime) return (null, null);
  final String? sourceId = _nonEmpty(j['sourceId']?.toString());
  final String? key = _nonEmpty(
    (type == _onlineMangaMarker ? series['key'] : series['url'])?.toString(),
  );
  final String? cover = _httpUrl(
    (series['coverUrl'] ?? series['thumbnail_url'])?.toString(),
  );
  return (sourceId == null || key == null ? null : '$sourceId:$key', cover);
}

Future<List<LocalShelfEntry>> _bookEntries(
  FushiDatabase db,
  _Totals totals,
) async {
  final $EpubBooksTable t = db.epubBooks;
  final List<TypedResult> rows =
      await (db.selectOnly(t)..addColumns(<Expression<Object>>[
            t.bookKey,
            t.title,
            t.author,
            t.coverPath,
            t.format,
            t.completedAt,
            t.isbn,
            t.sourceMetadata,
          ]))
          .get();
  final Map<String, int> bangumi = await _bangumiSubjects(
    db,
    'book', // TrackingMediaType.book.value
  );
  final List<LocalShelfEntry> out = <LocalShelfEntry>[];
  for (final TypedResult row in rows) {
    final String bookKey = row.read(t.bookKey)!;
    final DateTime? completedAt = row.read(t.completedAt);
    final (int chars, int ms) = totals.of(kActivityMediaBook, bookKey);
    if (completedAt == null && chars <= 0 && ms <= 0) continue;
    final String title = _nonEmpty(row.read(t.title)) ?? bookKey;
    final String author = _nonEmpty(row.read(t.author)) ?? '';
    final (String? sourceRef, String? coverUrl) = _sourceRefAndCover(
      row.read(t.sourceMetadata),
    );
    final int? subject = bangumi[bookKey];
    final LocalShelfEntry? e = _entry(
      localKey: 'book:$bookKey',
      kind: row.read(t.format) == BookFormat.manga.dbValue
          ? LeaderboardKind.manga
          : LeaderboardKind.book,
      refs: buildWorkRefs(
        bgmSubjectId: subject == null ? null : '$subject',
        isbn: row.read(t.isbn),
        sourceRef: sourceRef,
        title: title,
        author: author,
      ),
      title: title,
      author: author,
      coverUrl: coverUrl,
      finished: completedAt != null,
      finishedAt: completedAt?.millisecondsSinceEpoch,
      chars: chars,
      ms: ms,
      localCoverPath: row.read(t.coverPath),
    );
    if (e != null) out.add(e);
  }
  return out;
}

/// Bangumi 追踪映射：mediaKey → subjectId（[mediaType] = `TrackingMediaType.value`）。
Future<Map<String, int>> _bangumiSubjects(
  FushiDatabase db,
  String mediaType,
) async {
  final List<MediaTrackingMappingRow> rows =
      await (db.select(db.mediaTrackingMappings)..where(
            ($MediaTrackingMappingsTable m) =>
                m.provider.equals('bangumi') & m.mediaType.equals(mediaType),
          ))
          .get();
  return <String, int>{
    for (final MediaTrackingMappingRow r in rows)
      if (r.subjectId > 0) r.mediaKey: r.subjectId,
  };
}

// ---------------------------------------------------------------------------
// 视频

const String _collectionMediaVideo = 'video';

class _VideoUnit {
  _VideoUnit(this.localKey, this.work);

  final String localKey;
  final VideoMetadataWorkRow? work;
  final List<VideoBookRow> members = <VideoBookRow>[];
  int? collectionId;
}

Future<List<LocalShelfEntry>> _videoEntries(
  FushiDatabase db,
  _Totals totals,
) async {
  final List<VideoBookRow> videos = await db.select(db.videoBooks).get();
  if (videos.isEmpty) return const <LocalShelfEntry>[];
  final List<VideoMetadataWorkRow> works = await db.getAllVideoMetadataWorks();
  final Map<String, VideoMetadataWorkRow> workByBook =
      <String, VideoMetadataWorkRow>{
        for (final VideoMetadataWorkRow w in works)
          if (w.bookUid != null) w.bookUid!: w,
      };
  final Map<int, VideoMetadataWorkRow> workByCollection =
      <int, VideoMetadataWorkRow>{
        for (final VideoMetadataWorkRow w in works)
          if (w.collectionId != null) w.collectionId!: w,
      };
  // 视频 → 它所在的全部合集（升序）：有刮削作品的合集优先当作品单位。
  final Map<String, List<int>> collectionsOf = <String, List<int>>{};
  for (final MediaCollectionItemRow item in await db.getAllCollectionItems()) {
    if (item.mediaType != _collectionMediaVideo) continue;
    (collectionsOf[item.entryKey] ??= <int>[]).add(item.collectionId);
  }
  final Map<String, int> primaryCollection = await db
      .getPrimaryCollectionIdByEntry();
  final Map<int, MediaCollectionRow> collections = <int, MediaCollectionRow>{
    for (final MediaCollectionRow c in await db.getAllMediaCollections())
      c.id: c,
  };

  final Map<String, _VideoUnit> units = <String, _VideoUnit>{};
  _VideoUnit unitFor(String localKey, VideoMetadataWorkRow? work) =>
      units[localKey] ??= _VideoUnit(localKey, work);

  for (final VideoBookRow v in videos) {
    final VideoMetadataWorkRow? movie = workByBook[v.bookUid];
    final List<int> memberOf = (collectionsOf[v.bookUid] ?? <int>[])..sort();
    final int? scrapedCollection = memberOf
        .where((int c) => workByCollection.containsKey(c))
        .firstOrNull;
    final int? collectionId = movie != null
        ? null
        : scrapedCollection ??
              primaryCollection['$_collectionMediaVideo|${v.bookUid}'];
    final _VideoUnit unit = collectionId == null
        ? unitFor('video:b${v.bookUid}', movie)
        : (unitFor('video:c$collectionId', workByCollection[collectionId])
            ..collectionId = collectionId);
    unit.members.add(v);
  }

  final Map<int, List<VideoMetadataProviderIdentityRow>> identities =
      await _videoWorkIdentities(db);
  final Map<int, String> posters = await _videoWorkPosters(db);
  final List<LocalShelfEntry> out = <LocalShelfEntry>[];
  for (final _VideoUnit unit in units.values) {
    int chars = 0;
    int ms = 0;
    int? finishedAt = 0;
    for (final VideoBookRow m in unit.members) {
      final (int c, int t) = totals.of(kActivityMediaVideo, m.bookUid);
      chars += c;
      ms += t;
      final int? done = m.completedAt?.millisecondsSinceEpoch;
      finishedAt = done == null || finishedAt == null
          ? null
          : (done > finishedAt ? done : finishedAt);
    }
    final bool finished = finishedAt != null;
    if (!finished && chars <= 0 && ms <= 0) continue;
    final VideoMetadataWorkRow? work = unit.work;
    final MediaCollectionRow? collection = unit.collectionId == null
        ? null
        : collections[unit.collectionId];
    final String title =
        _nonEmpty(work?.title) ??
        _nonEmpty(collection?.name) ??
        _nonEmpty(unit.members.first.title) ??
        unit.localKey;
    final _VideoRefs ids = _VideoRefs.of(
      work,
      work == null
          ? const <VideoMetadataProviderIdentityRow>[]
          : identities[work.id] ?? const <VideoMetadataProviderIdentityRow>[],
    );
    final LocalShelfEntry? e = _entry(
      localKey: unit.localKey,
      kind: LeaderboardKind.video,
      refs: buildWorkRefs(
        bgmSubjectId: ids.bgm,
        anidbAid: ids.anidb,
        malId: ids.mal,
        tmdbRef: ids.tmdb,
        title: title,
      ),
      title: title,
      coverUrl: work == null ? null : posters[work.id],
      finished: finished,
      finishedAt: finished ? finishedAt : null,
      chars: chars,
      ms: ms,
      localCoverPath:
          _nonEmpty(collection?.coverPath) ??
          unit.members
              .map((VideoBookRow m) => _nonEmpty(m.coverPath))
              .whereType<String>()
              .firstOrNull,
    );
    if (e != null) out.add(e);
  }
  return out;
}

class _VideoRefs {
  const _VideoRefs({this.bgm, this.anidb, this.mal, this.tmdb});

  /// 作品级 provider 身份 → 各命名空间键体。TMDB 的 tv / movie 是两个 id 空间，
  /// 按作品的 mediaType 区分。
  factory _VideoRefs.of(
    VideoMetadataWorkRow? work,
    List<VideoMetadataProviderIdentityRow> rows,
  ) {
    String? id(String provider) => rows
        .where((VideoMetadataProviderIdentityRow r) => r.provider == provider)
        .map((VideoMetadataProviderIdentityRow r) => _nonEmpty(r.externalId))
        .whereType<String>()
        .firstOrNull;
    final String? tmdb = id('tmdb');
    final String? mediaType = work?.mediaType;
    return _VideoRefs(
      bgm: id('bangumi'),
      anidb: id('anidb'),
      mal: id('mal'),
      tmdb: tmdb == null || (mediaType != 'tv' && mediaType != 'movie')
          ? null
          : '$mediaType:$tmdb',
    );
  }

  final String? bgm;
  final String? anidb;
  final String? mal;
  final String? tmdb;
}

Future<Map<int, List<VideoMetadataProviderIdentityRow>>> _videoWorkIdentities(
  FushiDatabase db,
) async {
  final List<VideoMetadataProviderIdentityRow> rows =
      await (db.select(db.videoMetadataProviderIdentities)..where(
            ($VideoMetadataProviderIdentitiesTable i) => i.workId.isNotNull(),
          ))
          .get();
  final Map<int, List<VideoMetadataProviderIdentityRow>> out =
      <int, List<VideoMetadataProviderIdentityRow>>{};
  for (final VideoMetadataProviderIdentityRow r in rows) {
    (out[r.workId!] ??= <VideoMetadataProviderIdentityRow>[]).add(r);
  }
  return out;
}

/// 作品 → 首张封面图的远端 URL（`cover`；旧行可能仍叫 `poster`），按 position 取最前。
Future<Map<int, String>> _videoWorkPosters(FushiDatabase db) async {
  final List<VideoMetadataImageRow> rows =
      await (db.select(db.videoMetadataImages)
            ..where(
              ($VideoMetadataImagesTable i) =>
                  i.workId.isNotNull() &
                  i.kind.isIn(<String>['cover', 'poster']),
            )
            ..orderBy(<OrderClauseGenerator<$VideoMetadataImagesTable>>[
              ($VideoMetadataImagesTable i) =>
                  OrderingTerm(expression: i.position),
              ($VideoMetadataImagesTable i) => OrderingTerm(expression: i.id),
            ]))
          .get();
  final Map<int, String> out = <int, String>{};
  for (final VideoMetadataImageRow r in rows) {
    final String? url = _httpUrl(r.remoteUrl);
    if (url != null) out.putIfAbsent(r.workId!, () => url);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 游戏

const int _playStatusFinished = 2;
const int _playStatusPlaying = 3;

Future<List<LocalShelfEntry>> _gameEntries(
  FushiDatabase db,
  _Totals totals,
) async {
  final List<GalgameRow> games = await db.getAllGalgames();
  if (games.isEmpty) return const <LocalShelfEntry>[];
  final Map<String, List<GalgameSourceRow>> sources = await db
      .getAllGalgameSources();
  final List<LocalShelfEntry> out = <LocalShelfEntry>[];
  for (final GalgameRow g in games) {
    final (int chars, int ms) = totals.of(kActivityMediaGame, g.id);
    final bool finished = g.playStatus == _playStatusFinished;
    final bool reading =
        g.playStatus == _playStatusPlaying || chars > 0 || ms > 0;
    if (!finished && !reading) continue;
    final _GameMeta meta = _GameMeta.of(
      g,
      sources[g.id] ?? const <GalgameSourceRow>[],
    );
    final LocalShelfEntry? e = _entry(
      localKey: 'game:${g.id}',
      kind: LeaderboardKind.game,
      refs: buildWorkRefs(
        bgmSubjectId: meta.bgmId,
        vndbId: meta.vndbId,
        title: meta.title,
        author: meta.developer,
      ),
      title: meta.title,
      author: meta.developer,
      coverUrl: meta.coverUrl,
      nsfw: meta.nsfw,
      finished: finished,
      // 「玩过」但没有时刻（v114 前玩过且无会话）= 读完日期未知，只进总榜。
      finishedAt: finished ? g.completedAt : null,
      chars: chars,
      ms: ms,
      localCoverPath: g.coverPath,
    );
    if (e != null) out.add(e);
  }
  return out;
}

/// 游戏展示元数据：与 app 侧 `mergeDrafts`（契约 §2.4）同优先级的最小子集——
/// 标题 custom → bgm → vndb → 本地名；开发商 custom → vndb → bgm；成人向 custom →
/// bgm → vndb；封面 custom.coverSource → bgm → vndb。标题取原名而非中文名：排行榜
/// 跨语言共享，原名才是各地用户的公约数。
class _GameMeta {
  const _GameMeta({
    required this.title,
    required this.developer,
    required this.nsfw,
    this.coverUrl,
    this.bgmId,
    this.vndbId,
  });

  factory _GameMeta.of(GalgameRow g, List<GalgameSourceRow> rows) {
    GalgameSourceRow? row(String source) =>
        rows.where((GalgameSourceRow r) => r.source == source).firstOrNull;
    final GalgameSourceRow? bgmRow = row('bgm');
    final GalgameSourceRow? vndbRow = row('vndb');
    final Map<String, Object?> bgm = _jsonObject(bgmRow?.dataJson) ?? const {};
    final Map<String, Object?> vndb =
        _jsonObject(vndbRow?.dataJson) ?? const {};
    final Map<String, Object?> custom =
        _jsonObject(g.customDataJson) ?? const {};
    String? str(Map<String, Object?> m, String k) {
      final Object? v = m[k];
      return v is String ? _nonEmpty(v) : null;
    }

    bool? flag(Map<String, Object?> m) {
      final Object? v = m['nsfw'];
      return v is bool ? v : null;
    }

    final Map<String, Object?> preferredCover = switch (str(
      custom,
      'coverSource',
    )) {
      'bgm' => bgm,
      'vndb' => vndb,
      _ => const <String, Object?>{},
    };
    return _GameMeta(
      title:
          str(custom, 'name') ??
          str(bgm, 'name') ??
          str(vndb, 'name') ??
          _nonEmpty(g.name) ??
          g.id,
      developer:
          str(custom, 'developer') ??
          str(vndb, 'developer') ??
          str(bgm, 'developer') ??
          '',
      nsfw: flag(custom) ?? flag(bgm) ?? flag(vndb) ?? false,
      coverUrl: _httpUrl(
        str(preferredCover, 'coverUrl') ??
            str(bgm, 'coverUrl') ??
            str(vndb, 'coverUrl'),
      ),
      bgmId: _nonEmpty(bgmRow?.externalId),
      vndbId: _nonEmpty(vndbRow?.externalId),
    );
  }

  final String title;
  final String developer;
  final bool nsfw;
  final String? coverUrl;
  final String? bgmId;
  final String? vndbId;
}
