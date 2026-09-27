/// 「整套下载」的系列解析：给一部作品，找出同系列的全部剧集与剧场版。
///
/// 数据来源只有 TMDB：collection（`/collection/{id}`）一次给出有序的全部电影，
/// 是长寿系列（哆啦A梦 40+ 部剧场版、名侦探柯南）唯一可靠的全表。TMDB 的
/// collection **只收电影**，剧集那半按系列名另搜 `/search/tv`，只收标题**完全相等**
/// 的——宁可少列一部让用户补一句，也不把同名不同作的东西塞进一次几十条的下载。
///
/// MAL / AniDB 的关系链（Sequel / Side story）不在这里用：Jikan 限流、AniDB 要注册
/// client 身份，拉 40 部要几分钟；且 MAL 的「Other」对长寿作品噪声大。
library;

import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/title_normalizer.dart';

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
  });

  /// 显示名：有 collection 用它去掉「系列」后缀的名字，否则用锚点作品名。
  final String name;
  final List<VideoDiscoveryItem> series;
  final List<VideoDiscoveryItem> movies;

  int get length => series.length + movies.length;
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
  final Set<String> seenQueries = <String>{};
  for (final String query in seriesNames) {
    if (!seenQueries.add(TitleNormalizer.normalize(query))) continue;
    if (seenQueries.length > kVideoFranchiseMaxNames) break;
    for (final VideoDiscoveryItem item in await source.searchSeries(query)) {
      if (item.reference.mediaKind == VideoMetadataMediaKind.tv &&
          _titleEqualsAny(item.reference, seriesNames)) {
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

/// collection 名与作品名是否同一个系列：去掉「系列 / Collection」后缀后完全相等，
/// 或 collection 名以作品名开头（`Doraemon Collection` ⊃ `Doraemon`）。作品名短于
/// 3 个字符时只认完全相等——`Up` 不能吃进 `Superman Collection`。
bool videoFranchiseCollectionMatches(
  TmdbCollectionHit hit,
  List<String> names,
) {
  for (final String raw in names) {
    final String name = TitleNormalizer.normalize(raw);
    if (name.length < 2) continue;
    for (final String? candidate in <String?>[hit.name, hit.originalName]) {
      if (candidate == null) continue;
      final String normalized = TitleNormalizer.normalize(candidate);
      if (_stripCollectionSuffix(candidate) == name) return true;
      if (name.length >= 3 && normalized.startsWith('$name ')) return true;
    }
  }
  return false;
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
    final String titleKey =
        '${TitleNormalizer.normalize(reference.title)}|${reference.year}';
    final String? originalKey = reference.originalTitle == null
        ? null
        : '${TitleNormalizer.normalize(reference.originalTitle!)}|'
              '${reference.year}';
    if (_keys.contains(providerKey) ||
        _keys.contains(titleKey) ||
        (originalKey != null && _keys.contains(originalKey))) {
      return;
    }
    _keys
      ..add(providerKey)
      ..add(titleKey);
    if (originalKey != null) _keys.add(originalKey);
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
