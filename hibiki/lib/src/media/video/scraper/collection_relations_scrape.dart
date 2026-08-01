/// 合集「相关作品」抓取与落库（TODO-2484 数据层）。
///
/// 数据流：合集已有刮削绑定（`collection_scrape_meta` 的 `(source, subjectId)`）
/// → 按源拉关联条目（Bangumi `/v0/subjects/{id}/subjects`；TMDB tv 的季列表 /
/// movie 的 `belongs_to_collection` 成员）→ 映射成 [CollectionRelationType]
/// → 已在本地库的目标（按 `(source, subjectId)` 反查已刮削合集，标题精确匹配
/// 兜底）自动填 `targetCollectionId` → `replaceCollectionRelations` 整体替换。
///
/// 失败纪律（对齐 `ScrapeNetworkException` 风格）：源失败不吞——记入
/// [CollectionRelationsScrapeReport.sourceErrors] 由调用方展示/记日志；且**源
/// 失败时不动库**（不能把上次刮到的关系清成空表）。
///
/// 本文件不持有 UI；详情页展示由后续线程消费 `watchCollectionRelations`。
library;

import 'package:drift/drift.dart' show Value;
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 相关作品关系类型（落库 wire 值见 [wire]，与 `collection_relations.relation_type`
/// 列一一对应；UI 层按枚举渲染，不解析源词）。
enum CollectionRelationType {
  prequel('prequel'),
  sequel('sequel'),
  sideStory('side_story'),
  movie('movie'),
  spinOff('spin_off'),
  other('other');

  const CollectionRelationType(this.wire);

  /// 落库字符串（固定小写下划线，冻结不改）。
  final String wire;

  /// 从落库字符串还原；未知值（前向兼容）归 [other]。
  static CollectionRelationType fromWire(String wire) {
    for (final CollectionRelationType type in values) {
      if (type.wire == wire) return type;
    }
    return CollectionRelationType.other;
  }
}

/// 纯函数：Bangumi `relation` 中文关系词 → [CollectionRelationType]。
///
/// 值域来自 Bangumi 关联条目页的实际用词（前传/续集/番外篇/剧场版/衍生…）；
/// 未收录的词（总集篇/主线故事/不同演绎…）一律 [CollectionRelationType.other]，
/// 不猜。
CollectionRelationType mapBangumiRelation(String relation) {
  final String r = relation.trim();
  if (r == '前传' || r == '前傳') return CollectionRelationType.prequel;
  if (r == '续集' || r == '續集') return CollectionRelationType.sequel;
  if (r == '番外篇' || r == '番外' || r == '外传' || r == '外傳') {
    return CollectionRelationType.sideStory;
  }
  if (r == '剧场版' || r == '劇場版') return CollectionRelationType.movie;
  if (r == '衍生' || r == '衍生作品') return CollectionRelationType.spinOff;
  return CollectionRelationType.other;
}

/// 一次相关作品刮削的结果摘要。
class CollectionRelationsScrapeReport {
  const CollectionRelationsScrapeReport({
    required this.written,
    required this.boundLocal,
    required this.sourceErrors,
  });

  /// 本次写入的关系边数（源成功但确实没有关联条目时为 0，且库被替换为空）。
  final int written;

  /// 其中自动绑定到本地合集的边数。
  final int boundLocal;

  /// 逐源错误（key = 源名，value = 技术描述）。非空时**库未被改动**。
  final Map<String, String> sourceErrors;
}

/// 抓取层中间产物：一条待落库的关系边（尚未做本地绑定）。
class _PendingRelation {
  const _PendingRelation({
    required this.type,
    required this.source,
    required this.subjectId,
    required this.title,
    this.coverUrl,
  });

  final CollectionRelationType type;
  final ScrapeSource source;
  final String subjectId;
  final String title;
  final String? coverUrl;
}

/// 抓取并落库合集 [collectionId] 的相关作品。
///
/// 前置：合集必须已有刮削绑定（`collection_scrape_meta` 有行），否则抛
/// [StateError]——调用方要么刚跑完 `applyCollectionScrape`（绑定必在），要么
/// 在 UI 上只对已刮削合集暴露该动作。
///
/// [bangumi] / [tmdb] 与绑定源对应者为 null 时按「源不可用」记入
/// [CollectionRelationsScrapeReport.sourceErrors]（如用户未配 TMDB key）。
/// 网络/解析失败同样记入 sourceErrors，**不抛出也不吞**；出错时不改动库。
Future<CollectionRelationsScrapeReport> scrapeCollectionRelations({
  required HibikiDatabase db,
  required int collectionId,
  BangumiClient? bangumi,
  TmdbClient? tmdb,
}) async {
  final CollectionScrapeMetaRow? meta =
      await db.getCollectionScrapeMeta(collectionId);
  if (meta == null) {
    throw StateError(
      'collection $collectionId has no scrape binding; scrape it first',
    );
  }

  final List<_PendingRelation> pending = <_PendingRelation>[];
  final Map<String, String> errors = <String, String>{};

  if (meta.source == ScrapeSource.bangumi.name) {
    if (bangumi == null) {
      errors[meta.source] = 'Bangumi client unavailable';
    } else {
      try {
        final List<BangumiRelatedSubject> related =
            await bangumi.fetchSubjectRelations(meta.subjectId);
        for (final BangumiRelatedSubject r in related) {
          pending.add(_PendingRelation(
            type: mapBangumiRelation(r.relation),
            source: ScrapeSource.bangumi,
            subjectId: r.subjectId,
            title: r.title,
            coverUrl: r.coverUrl,
          ));
        }
      } on ScrapeNetworkException catch (e) {
        errors[meta.source] = e.toString();
      }
    }
  } else if (meta.source == ScrapeSource.tmdb.name) {
    if (tmdb == null) {
      errors[meta.source] = 'TMDB client unavailable (no API key)';
    } else {
      try {
        pending.addAll(await _fetchTmdbRelations(tmdb, meta));
      } on ScrapeNetworkException catch (e) {
        errors[meta.source] = e.toString();
      }
    }
  } else {
    // offlineDb / manualUrl：没有关系端点，明说而不是装作「无关联」。
    errors[meta.source] = 'source has no relations endpoint';
  }

  if (errors.isNotEmpty) {
    return CollectionRelationsScrapeReport(
      written: 0,
      boundLocal: 0,
      sourceErrors: errors,
    );
  }

  // 本地绑定：(source, subjectId) 反查已刮削合集优先，标题精确匹配兜底；
  // 永不绑回自身（Bangumi 偶见自引用脏数据）。
  final List<MediaCollectionRow> allCollections =
      await db.getAllMediaCollections();
  final Map<String, int> titleToCollectionId = <String, int>{
    for (final MediaCollectionRow c in allCollections.reversed)
      if (c.id != collectionId) c.name: c.id,
  };

  int bound = 0;
  final List<CollectionRelationsCompanion> companions =
      <CollectionRelationsCompanion>[];
  for (int i = 0; i < pending.length; i++) {
    final _PendingRelation p = pending[i];
    int? target;
    final List<int> bySubject =
        await db.collectionIdsByScrapeSubject(p.source.name, p.subjectId);
    for (final int id in bySubject) {
      if (id != collectionId) {
        target = id;
        break;
      }
    }
    target ??= titleToCollectionId[p.title];
    if (target != null) bound++;
    companions.add(CollectionRelationsCompanion.insert(
      collectionId: collectionId,
      relationType: p.type.wire,
      sortIndex: Value<int>(i),
      targetCollectionId: Value<int?>(target),
      source: p.source.name,
      subjectId: p.subjectId,
      title: p.title,
      coverUrl: Value<String?>(p.coverUrl),
    ));
  }

  await db.replaceCollectionRelations(collectionId, companions);
  return CollectionRelationsScrapeReport(
    written: companions.length,
    boundLocal: bound,
    sourceErrors: const <String, String>{},
  );
}

/// TMDB 侧关联条目：tv → 季列表（特别篇季 = side_story，其余季 = other，季与
/// 季之间没有可靠的先后语义，不硬编 prequel/sequel）；movie →
/// `belongs_to_collection` 成员（按上映日期相对本条目分 prequel/sequel，无日期
/// 归 other），排除自身。
///
/// tv/movie 判定优先走 detailUrl（`themoviedb.org/tv|movie/<id>`）；旧数据缺
/// detailUrl 时先按 tv 试、404 再按 movie 试（两个 id 空间独立且会撞号，因此
/// 只在无法判定时才这样探测）。
Future<List<_PendingRelation>> _fetchTmdbRelations(
  TmdbClient tmdb,
  CollectionScrapeMetaRow meta,
) async {
  final TmdbSubjectKind? kind = tmdbKindFromDetailUrl(meta.detailUrl);

  if (kind == TmdbSubjectKind.tv || kind == null) {
    final TmdbTvDetail? detail = await tmdb.fetchTvDetail(meta.subjectId);
    if (detail != null) {
      return <_PendingRelation>[
        for (final TmdbSeasonRef season in detail.seasons)
          _PendingRelation(
            type: season.seasonNumber == 0
                ? CollectionRelationType.sideStory
                : CollectionRelationType.other,
            source: ScrapeSource.tmdb,
            subjectId: season.seasonId,
            title: season.name,
            coverUrl: season.posterPath == null
                ? null
                : '${TmdbClient.posterBase}${season.posterPath}',
          ),
      ];
    }
    if (kind == TmdbSubjectKind.tv) return const <_PendingRelation>[];
  }

  final TmdbMovieCollectionRef? ref =
      await tmdb.fetchMovieCollectionRef(meta.subjectId);
  if (ref == null) return const <_PendingRelation>[];
  final List<TmdbCollectionPart> parts =
      await tmdb.fetchCollectionParts(ref.collectionId);

  final List<_PendingRelation> pending = <_PendingRelation>[];
  for (final TmdbCollectionPart part in parts) {
    if (part.movieId == meta.subjectId) continue; // 排除自身。
    CollectionRelationType type = CollectionRelationType.other;
    final String? selfDate = meta.airDate;
    final String? partDate = part.releaseDate;
    if (selfDate != null && partDate != null) {
      final int cmp = partDate.compareTo(selfDate);
      if (cmp < 0) type = CollectionRelationType.prequel;
      if (cmp > 0) type = CollectionRelationType.sequel;
    }
    pending.add(_PendingRelation(
      type: type,
      source: ScrapeSource.tmdb,
      subjectId: part.movieId,
      title: part.title,
      coverUrl: part.posterPath == null
          ? null
          : '${TmdbClient.posterBase}${part.posterPath}',
    ));
  }
  return pending;
}
