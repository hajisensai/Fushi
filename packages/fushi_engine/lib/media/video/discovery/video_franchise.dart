/// 「整套下载」的系列解析：给一部作品，找出同系列的全部剧集与剧场版。
///
/// 三个来源，各管一段、结果合并去重（[mergeVideoFranchises]）：
///
/// * **TMDB collection**（[resolveVideoFranchise]）：`/collection/{id}` 一次给出有序的
///   全部电影，是长寿系列（哆啦A梦 40+ 部剧场版、名侦探柯南）最全的电影表；剧集
///   那半按系列名另搜 `/search/tv`，只收标题**完全相等**、类别与原语言一致的。
///   要 TMDB key。
/// * **MAL 关联链**（[resolveMalFranchise]）：不要 key。沿 Jikan `relations` 的
///   续作 / 前传 / 母篇 / 外传 / 重制走一遍，动画的季、剧场版都能串起来。不走
///   「Other」「Spin-off」「Character」——长寿作品在这几类上挂满联动与客串。
/// * **联网资料 + AI**（`ai_video_franchise_assistant.dart`）：维基百科条目交 AI 列作品，
///   逐部回资料源核对，核对不上的不进清单。
///
/// AniDB 不用：要注册 client 身份，限流拉几十部太慢。
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart'
    show MalRelatedWorks, MalRelation;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';
import 'package:fushi_engine/foundation/engine_log.dart';

/// `/search/collection` 的一条结果。
class TmdbCollectionHit {
  const TmdbCollectionHit({
    required this.id,
    required this.name,
    this.originalName,
  });

  final int id;
  final String name;
  final String? originalName;
}

/// 一个 TMDB 系列（collection）：名字 + 按上映顺序排好的电影。
class TmdbCollection {
  const TmdbCollection({
    required this.id,
    required this.name,
    required this.movies,
  });

  final int id;
  final String name;
  final List<VideoDiscoveryItem> movies;
}

/// 一个作品系列：剧集（每部一条，季由资源侧决定）+ 按上映顺序排好的剧场版。
class VideoFranchise {
  const VideoFranchise({
    required this.name,
    required this.series,
    required this.movies,
    this.truncated = false,
    this.more,
  });

  /// 显示名：有 collection 用它去掉「系列」后缀的名字，否则用锚点作品名。
  final String name;
  final List<VideoDiscoveryItem> series;
  final List<VideoDiscoveryItem> movies;

  /// 解析因失败停下（MAL 中途请求失败 / 某个来源整个出错）：[series] / [movies]
  /// 只是已经收到的那部分，不能当「全部」交给用户。还没查完但能接着查的不算——
  /// 那是 [more]。
  final bool truncated;

  /// 还没查完：调用它从断点接着查下一批，返回**到目前为止**的全部结果（含之前
  /// 各批）；最后一批的 [more] 为 null。只能调一次。
  ///
  /// 分批而不是一口气走完 / 撞上预算就停：长寿系列（哆啦A梦 100+ 个关联节点、
  /// Jikan 约 1 秒一个请求）一次走完要好几分钟，调用方每批报一次进度、用户随时
  /// 可取消；撞预算就停则是把半张清单当整套交出去（BUG-2937）。
  final Future<VideoFranchise> Function()? more;

  int get length => series.length + movies.length;

  /// 去掉 [more] 的快照（续查的结果回来后，旧的续查入口已经用过了）。
  VideoFranchise withoutMore() => VideoFranchise(
    name: name,
    series: series,
    movies: movies,
    truncated: truncated,
  );
}

/// 系列解析要的 TMDB 能力（生产实现是 `TmdbVideoDiscoveryProvider`；测试注入假的）。
abstract interface class VideoFranchiseSource {
  bool get isAvailable;
  Future<List<TmdbCollectionHit>> searchCollections(String query);
  Future<int?> movieCollectionId(int movieId);
  Future<TmdbCollection?> fetchCollection(int collectionId);
  Future<List<VideoDiscoveryItem>> searchSeries(String query);
}

/// 一次最多展开几个 collection（哆啦A梦在 TMDB 上可能拆成新旧两个）。
const int kVideoFranchiseMaxCollections = 4;

/// 用于搜系列的名字最多几个（标题 / 原名 / 别名）。
const int kVideoFranchiseMaxNames = 4;

/// 解析 [anchor] 所在的系列；来源不可用返回 null。找不到任何同系列作品时返回
/// 只含锚点自己的系列（调用方据 [VideoFranchise.length] 判断「没有更多」）。
Future<VideoFranchise?> resolveVideoFranchise(
  VideoFranchiseSource source,
  VideoDiscoveryItem anchor,
) async {
  if (!source.isAvailable) return null;
  final VideoMediaReference reference = anchor.reference;
  final List<String> names = _anchorNames(reference);

  final List<int> collectionIds = <int>[];
  void addCollection(int? id) {
    if (id == null || collectionIds.contains(id)) return;
    if (collectionIds.length >= kVideoFranchiseMaxCollections) return;
    collectionIds.add(id);
  }

  final int? tmdbId = reference.tmdbId;
  if (reference.mediaKind == VideoMetadataMediaKind.movie && tmdbId != null) {
    addCollection(await source.movieCollectionId(tmdbId));
  }
  for (final String name in names) {
    for (final TmdbCollectionHit hit in await source.searchCollections(name)) {
      if (videoFranchiseCollectionMatches(hit, names)) addCollection(hit.id);
    }
  }

  final List<TmdbCollection> collections = <TmdbCollection>[
    for (final int id in collectionIds)
      if (await source.fetchCollection(id) case final TmdbCollection value)
        value,
  ];

  final _WorkSet movies = _WorkSet();
  if (reference.mediaKind == VideoMetadataMediaKind.movie) movies.add(anchor);
  for (final TmdbCollection collection in collections) {
    collection.movies.forEach(movies.add);
  }

  final List<String> seriesNames = <String>[
    ...names,
    // 搜索词用保留原写法的系列名：归一化会转小写、繁转简，喂给 TMDB 反而搜偏；
    // 是否同名由 [_titleEqualsAny] 归一化后再比。
    for (final TmdbCollection collection in collections)
      if (_displayBase(collection.name) case final String base) base,
  ];
  final _WorkSet series = _WorkSet();
  if (reference.mediaKind == VideoMetadataMediaKind.tv) series.add(anchor);
  // 配额 = 锚点名 + 每个 collection 一个：锚点名占满时，最有用的 collection 系列名
  // 也必须搜得到。
  final int queryBudget = names.length + collections.length;
  final Set<String> seenQueries = <String>{};
  for (final String query in seriesNames) {
    if (seenQueries.length >= queryBudget) break;
    if (!seenQueries.add(TitleNormalizer.normalize(query))) continue;
    for (final VideoDiscoveryItem item in await source.searchSeries(query)) {
      if (item.reference.mediaKind == VideoMetadataMediaKind.tv &&
          _titleEqualsAny(item.reference, seriesNames) &&
          _compatibleWith(anchor, item)) {
        series.add(item);
      }
    }
  }

  return VideoFranchise(
    name: collections.isEmpty
        ? reference.title
        : (_displayBase(collections.first.name) ?? reference.title),
    series: series.sortedByYear(),
    movies: movies.sortedByYear(),
  );
}

/// MAL 关联链要的能力（生产实现包 `MalVideoMetadataProvider`；测试注入假的）。
abstract interface class VideoFranchiseRelationSource {
  Future<MalRelatedWorks?> fetchRelatedWorks(String malId);

  /// 按标题搜 MAL 动画（锚点没有 MAL 身份时找它）。
  Future<List<VideoMetadataWork>> searchAnime(String title);
}

/// 沿 MAL 关联每批请求几部（Jikan 闸门约 1.1 秒一个请求：40 部 ≈ 45 秒报一次进度）。
///
/// 计的是请求数而不是收进清单的部数：OVA / Special 不收，但要请求一次才知道它是
/// OVA。**没有总上限**：关联图是有限的（只走 [kVideoFranchiseMalRelations]、访问过
/// 的不再走），批与批之间经 [VideoFranchise.more] 接着走，直到走完。旧做法是总
/// 上限 60 / 150 撞上就停（BUG-2935 / BUG-2937）：哆啦A梦从 1979 版出发，1979 版
/// 一层外传就 ~50 部，剧场版、同映短片、特别篇层层展开 100+ 个节点，停在哪里都是
/// 把半张清单当整套交出去。
const int kVideoFranchiseMalBatch = 40;

/// 沿着走的 MAL 关系（小写）。「Other」「Spin-off」「Character」「Summary」不走：
/// 长寿作品在这几类上挂满联动、客串与总集篇；「Alternative setting」也不走——
/// 高达 / Fate / 光之美少女经它能串进整个宇宙，几步就把上限耗在别的系列上。
const Set<String> kVideoFranchiseMalRelations = <String>{
  'sequel',
  'prequel',
  'parent story',
  'full story',
  'side story',
  'alternative version',
};

/// 长片下限（分钟）：AMPAS / BFI 对「长片」的定义是 40 分钟以上。MAL 把同映
/// 短片（哆啦A梦剧场版同映的 15–30 分钟短片、The☆Doraemons、天象馆片）也标
/// `Movie`，不按片长分就会默认勾选进「全部剧场版」（BUG-2936）。片长未知的照收。
const int kVideoFranchiseMinFeatureMinutes = 40;

/// MAL `type` → 系列里的哪一段；null = 不收（OVA / Special / PV / CM / Music /
/// 短于 [kVideoFranchiseMinFeatureMinutes] 的同映短片——这些是特典或番外，不是
/// 「全部季 + 全部剧场版」）。
VideoMetadataMediaKind? _malFranchiseKind(MalRelatedWorks related) =>
    switch (related.malType?.trim().toLowerCase()) {
      'movie' =>
        _isShortFilm(related.work) ? null : VideoMetadataMediaKind.movie,
      'tv' || 'ona' => VideoMetadataMediaKind.tv,
      _ => null,
    };

bool _isShortFilm(VideoMetadataWork work) {
  final int? minutes = work.runtimeMinutes;
  return minutes != null && minutes < kVideoFranchiseMinFeatureMinutes;
}

/// MAL 关联链展开的系列（第一批；没走完时经 [VideoFranchise.more] 接着走）；
/// 锚点既没有 MAL 身份、按标题也搜不到时返回 null。
Future<VideoFranchise?> resolveMalFranchise(
  VideoFranchiseRelationSource source,
  VideoDiscoveryItem anchor, {
  int batchSize = kVideoFranchiseMalBatch,
}) async {
  final String? start = await _anchorMalId(source, anchor);
  if (start == null) return null;
  return _MalFranchiseWalk(
    source,
    fallbackName: anchor.reference.title,
    start: int.parse(start),
    batchSize: batchSize,
  ).next();
}

/// 一次 MAL 关联图广度优先遍历的全部状态：批与批之间就停在这里，
/// [VideoFranchise.more] 是指向 [next] 的入口。
class _MalFranchiseWalk {
  _MalFranchiseWalk(
    this._source, {
    required String fallbackName,
    required int start,
    required int batchSize,
  }) : _fallbackName = fallbackName,
       _batchSize = batchSize,
       _queue = <int>[start];

  final VideoFranchiseRelationSource _source;
  final String _fallbackName;
  final int _batchSize;
  final List<int> _queue;
  final Set<int> _visited = <int>{};
  final _WorkSet _series = _WorkSet();
  final _WorkSet _movies = _WorkSet();
  String? _name;
  bool _failed = false;

  /// 再走一批（最多 [_batchSize] 个请求），交出到目前为止的全部结果。
  Future<VideoFranchise> next() async {
    int fetched = 0;
    while (!_failed && _queue.isNotEmpty && fetched < _batchSize) {
      final int id = _queue.removeAt(0);
      if (!_visited.add(id)) continue;
      fetched++;
      await _visit(id);
    }
    _queue.removeWhere(_visited.contains);
    return VideoFranchise(
      name: _name ?? _fallbackName,
      series: _series.sortedByYear(),
      movies: _movies.sortedByYear(),
      truncated: _failed,
      more: !_failed && _queue.isNotEmpty ? next : null,
    );
  }

  Future<void> _visit(int id) async {
    final MalRelatedWorks? related;
    try {
      related = await _source.fetchRelatedWorks('$id');
    } on Object catch (error, stack) {
      // 走到第 40 部碰上一次 5xx / 限流重试用尽：停在这里、交出已经收集到的，
      // 而不是让前面 39 部一起作废；标 truncated 如实说清单不全。
      engineLog.logDiagnostic(
        'VideoFranchise.malTraversal',
        'stopped at mal:$id after ${_visited.length - 1} works: $error\n$stack',
      );
      _failed = true;
      return;
    }
    if (related == null) return;
    _name ??= related.work.title;
    final VideoMetadataMediaKind? kind = _malFranchiseKind(related);
    if (kind != null) {
      final VideoDiscoveryItem item = VideoDiscoveryItem.fromMetadataWork(
        work: related.work.kind == kind
            ? related.work
            : related.work.copyWith(kind: kind),
        discoveryCategory: VideoDiscoveryCategory.anime,
        externalId: '$id',
      );
      (kind == VideoMetadataMediaKind.movie ? _movies : _series).add(item);
    }
    for (final MalRelation relation in related.relations) {
      if (kVideoFranchiseMalRelations.contains(
            relation.relation.trim().toLowerCase(),
          ) &&
          !_visited.contains(relation.malId)) {
        _queue.add(relation.malId);
      }
    }
  }
}

Future<String?> _anchorMalId(
  VideoFranchiseRelationSource source,
  VideoDiscoveryItem anchor,
) async {
  final VideoMediaReference reference = anchor.reference;
  final String direct =
      (reference.externalIds['mal'] ??
              (reference.providerId == 'mal' ? reference.mediaId : ''))
          .trim();
  if (int.tryParse(direct) != null) return direct;
  final List<String> names = _anchorNames(reference);
  final Set<String> wanted = <String>{
    for (final String name in names) TitleNormalizer.normalize(name),
  };
  final int? year = reference.year;
  String? fallback;
  for (final String name in names) {
    for (final VideoMetadataWork work in await source.searchAnime(name)) {
      final bool same =
          <String?>[work.title, work.originalTitle, ...work.aliases].any(
            (String? value) =>
                value != null &&
                wanted.contains(TitleNormalizer.normalize(value)),
          );
      if (!same) continue;
      final String? id = work.ids
          .where((VideoMetadataId value) => value.type == 'mal')
          .map((VideoMetadataId value) => value.value)
          .firstOrNull;
      if (id == null) continue;
      // 同名新旧版（HUNTER×HUNTER 1999 / 2011）：年份对得上的优先；锚点没年份
      // 或都对不上时才退到第一个同名的。
      final int? workYear = work.year;
      if (year != null && workYear != null && (workYear - year).abs() <= 1) {
        return id;
      }
      fallback ??= id;
    }
  }
  return fallback;
}

/// 合并几份系列清单：按标题 + 年份去重，剧集 / 剧场版各自按年份排；名字取第一份
/// 非空的（TMDB collection 名比 MAL 的首部标题更像系列名）。任一份因失败没走完，
/// 合并结果也算没走完：别的来源补上了多少无从核对。续查入口 [VideoFranchise.more]
/// 取第一份带的（只有 MAL 关联链分批）——合并层不能把它吞掉，否则后面的批次
/// 永远查不到。
VideoFranchise? mergeVideoFranchises(Iterable<VideoFranchise?> parts) {
  final List<VideoFranchise> present = <VideoFranchise>[
    for (final VideoFranchise? part in parts)
      if (part != null) part,
  ];
  if (present.isEmpty) return null;
  final _WorkSet series = _WorkSet();
  final _WorkSet movies = _WorkSet();
  for (final VideoFranchise part in present) {
    part.series.forEach(series.add);
    part.movies.forEach(movies.add);
  }
  return VideoFranchise(
    name: present.first.name,
    series: series.sortedByYear(),
    movies: movies.sortedByYear(),
    truncated: present.any((VideoFranchise part) => part.truncated),
    more: present
        .map((VideoFranchise part) => part.more)
        .firstWhere(
          (Future<VideoFranchise> Function()? more) => more != null,
          orElse: () => null,
        ),
  );
}

/// collection 名与作品名是否同一个系列：去掉「系列 / Collection」后缀后**完全相等**。
///
/// 不认前缀：`Air` ⊂ `Air Bud Collection`、`Monster` ⊂ `Monster High Collection`
/// 都是别的系列，而这里一旦误收，清单里就是几十部默认勾选的错作品。
bool videoFranchiseCollectionMatches(
  TmdbCollectionHit hit,
  List<String> names,
) {
  for (final String raw in names) {
    final String name = TitleNormalizer.normalize(raw);
    if (name.isEmpty) continue;
    for (final String? candidate in <String?>[hit.name, hit.originalName]) {
      if (candidate != null && _stripCollectionSuffix(candidate) == name) {
        return true;
      }
    }
  }
  return false;
}

/// 同名剧集是不是同一个系列的：类别（动画 / 真人剧）一致，原语言都已知时一致。
/// 泛名作品（`Monster`、`Nana`）在别国有同名剧，标题相等不够。
bool _compatibleWith(VideoDiscoveryItem anchor, VideoDiscoveryItem candidate) {
  if (anchor.reference.discoveryCategory !=
      candidate.reference.discoveryCategory) {
    return false;
  }
  final String? a = anchor.metadataWork?.originalLanguage?.trim().toLowerCase();
  final String? b = candidate.metadataWork?.originalLanguage
      ?.trim()
      .toLowerCase();
  if (a == null || a.isEmpty || b == null || b.isEmpty) return true;
  return a == b;
}

List<String> _anchorNames(VideoMediaReference reference) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String? value in <String?>[
      reference.title,
      reference.originalTitle,
      ...reference.aliases,
    ])
      if (value != null &&
          value.trim().isNotEmpty &&
          seen.add(TitleNormalizer.normalize(value)))
        value.trim(),
  ].take(kVideoFranchiseMaxNames).toList(growable: false);
}

/// 归一化后去掉 collection 名的后缀词（中 / 日 / 英）。
String _stripCollectionSuffix(String name) {
  String value = TitleNormalizer.normalize(name);
  value = value.replaceAll(
    RegExp(
      r'(\s*(剧场版系列|電影系列|电影系列|系列|合集|劇場版シリーズ|シリーズ|コレクション'
      r'|film collection|movie collection|film series|movie series'
      r'|collection|movies|series))+$',
    ),
    '',
  );
  return value.replaceAll(RegExp(r'[\s\-:：（）()\[\]【】]+$'), '').trim();
}

/// 显示用的系列名：保留原大小写，只去掉后缀词。
String? _displayBase(String name) {
  final String stripped = name
      .replaceAll(
        RegExp(
          r'[\s（(]*(剧场版系列|電影系列|电影系列|系列|合集|劇場版シリーズ|シリーズ'
          r'|コレクション|Film Collection|Movie Collection|Film Series'
          r'|Movie Series|Collection|Movies|Series)[）)]*\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  return stripped.isEmpty ? null : stripped;
}

bool _titleEqualsAny(VideoMediaReference reference, List<String> names) {
  final Set<String> wanted = <String>{
    for (final String name in names) TitleNormalizer.normalize(name),
    for (final String name in names) _stripCollectionSuffix(name),
  }..removeWhere((String value) => value.isEmpty);
  return <String?>[
    reference.title,
    reference.originalTitle,
    ...reference.aliases,
  ].any(
    (String? value) =>
        value != null && wanted.contains(TitleNormalizer.normalize(value)),
  );
}

/// 按「标题 + 年份」去重的有序集合：MAL 来的锚点与 TMDB 搜出的同一部剧是两个
/// provider 身份，不能在清单里出现两次。
class _WorkSet {
  final List<VideoDiscoveryItem> _items = <VideoDiscoveryItem>[];
  final Set<String> _keys = <String>{};

  void add(VideoDiscoveryItem item) {
    final VideoMediaReference reference = item.reference;
    final String providerKey = '${reference.providerId}:${reference.mediaId}';
    // 外部 id（TMDB 条目带 mal、MAL 条目带 tmdb 时）是最硬的同一判据。
    final List<String> idKeys = <String>[
      providerKey,
      for (final MapEntry<String, String> id in reference.externalIds.entries)
        if (id.key == 'mal' || id.key == 'tmdb' || id.key == 'anidb')
          '${id.key}:${id.value}',
      if (reference.tmdbId != null) 'tmdb:${reference.tmdbId}',
    ];
    // 别名也算：TMDB 的原名与 MAL 的 title_japanese 常差一个「劇場版」前缀或
    // 副标题写法，只比 title / originalTitle 会把同一部电影列两次、下两次。
    final List<String> titles = <String>{
      for (final String? value in <String?>[
        reference.title,
        reference.originalTitle,
        ...reference.aliases,
      ])
        if (value != null && value.trim().isNotEmpty)
          TitleNormalizer.normalize(value),
    }.toList();
    // 年份 ±1：MAL 与 TMDB 对同一部剧的首播年常差一年（首播日跨年 / 时区）。
    final int? year = reference.year;
    final List<String> probes = <String>[
      for (final String title in titles)
        if (year == null)
          '$title|null'
        else
          for (int y = year - 1; y <= year + 1; y++) '$title|$y',
    ];
    if (idKeys.any(_keys.contains) || probes.any(_keys.contains)) return;
    _keys.addAll(idKeys);
    for (final String title in titles) {
      _keys.add('$title|$year');
    }
    _items.add(item);
  }

  /// 年份升序，年份未知的殿后；同年保持加入顺序（collection 已按上映日期排好）。
  List<VideoDiscoveryItem> sortedByYear() {
    final List<(int, VideoDiscoveryItem)> indexed = <(int, VideoDiscoveryItem)>[
      for (int i = 0; i < _items.length; i++) (i, _items[i]),
    ];
    indexed.sort(((int, VideoDiscoveryItem) a, (int, VideoDiscoveryItem) b) {
      final int? ya = a.$2.reference.year;
      final int? yb = b.$2.reference.year;
      if (ya != yb) {
        if (ya == null) return 1;
        if (yb == null) return -1;
        return ya.compareTo(yb);
      }
      return a.$1.compareTo(b.$1);
    });
    return List<VideoDiscoveryItem>.unmodifiable(<VideoDiscoveryItem>[
      for (final (int, VideoDiscoveryItem) entry in indexed) entry.$2,
    ]);
  }
}
