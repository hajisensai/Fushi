/// 集级刮削服务（TODO-2491 数据层）：给定已绑定刮削源的合集，把**每一集**的
/// 集名/简介/放送日期（和 TMDB 剧照）落到条目级 `video_scrape_meta`（主键
/// bookUid，一集一行，v65 起带 `episode_number`）。
///
/// 对齐方式：成员文件名经 [parseVideoFilename]（G10 单规则引擎）解出集号，与源
/// 分集列表（TMDB `/tv/{id}/season/{n}`；Bangumi `/v0/episodes?type=0`）按集号
/// 对齐；解不出集号或源无该集 → 跳过并计数（[EpisodeScrapeOutcome.unmatched]）。
/// TMDB 的季号取合集成员解析季号的众数，无季默认 1；Bangumi 无季概念（多季是
/// 独立 subject），直接按正篇集号对齐。
///
/// 剧照（仅 TMDB 提供）落为该集封面：走 [CoverDownloader] 的既有
/// `video_covers/<uid>.jpg` 约定 + `cover_meta.json` 标记
/// [CoverOrigin.autoScraped]；封面来源是用户亲选（[CoverOrigin.isUserChosen]）
/// 时**绝不覆盖**，计入 [EpisodeScrapeOutcome.stillsSkippedUserCover]。刻意不
/// 另存剧照文件/路径列：剧照就是集封面，另存会造第二真相并被
/// `gcOrphanCovers`（保留集 = `video_books.cover_path`）当孤儿回收。
///
/// 本服务**永不改条目标题**——改名是独立的用户确认动作（`episode_rename.dart`，
/// 对齐 BUG-1310 的用户拍板：自动刮削路径不改名）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_downloader.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 一次集级刮削的结果摘要。
class EpisodeScrapeOutcome {
  const EpisodeScrapeOutcome({
    required this.updated,
    required this.unmatched,
    required this.stillsApplied,
    required this.stillsSkippedUserCover,
    required this.errors,
  });

  /// 写入 `video_scrape_meta` 的集数。
  final int updated;

  /// 未匹配集数（文件名解不出集号 / 源分集列表无该集号）。
  final int unmatched;

  /// 剧照成功落为集封面的数量。
  final int stillsApplied;

  /// 因用户亲选封面而跳过剧照的数量（[CoverOrigin.isUserChosen] 防线）。
  final int stillsSkippedUserCover;

  /// 错误集合（key = 源名或 `still_E<集号>`）。源级失败时资料零写入；剧照级
  /// 失败只影响该集封面，资料照常写入。
  final Map<String, String> errors;
}

/// 单集的源侧资料（对齐后待落库）。
class _SourceEpisode {
  const _SourceEpisode({
    required this.episodeNumber,
    this.title,
    this.summary,
    this.airDate,
    this.stillPath,
  });

  final int episodeNumber;
  final String? title;
  final String? summary;
  final String? airDate;

  /// TMDB 剧照相对路径；Bangumi 恒 null。
  final String? stillPath;
}

/// 集级刮削服务。构造注入网络客户端与封面设施（测试注入 mock / 临时目录）。
class EpisodeScrapeService {
  EpisodeScrapeService({
    required HibikiDatabase db,
    BangumiClient? bangumiClient,
    TmdbClient? tmdbClient,
    CoverDownloader? coverDownloader,
    CoverMetaStore? coverMetaStore,
    Directory? coversDirectory,
  })  : _db = db,
        _bangumi = bangumiClient,
        _tmdb = tmdbClient,
        _coverDownloader = coverDownloader,
        _coverMetaStore = coverMetaStore,
        _coversDirectory = coversDirectory;

  final HibikiDatabase _db;
  final BangumiClient? _bangumi;
  final TmdbClient? _tmdb;

  /// 三者 null 时跳过剧照（只写文字资料）：调用方不关心封面就不必搭封面设施。
  final CoverDownloader? _coverDownloader;
  final CoverMetaStore? _coverMetaStore;
  final Directory? _coversDirectory;

  /// 对合集 [collectionId] 的全部视频成员做集级刮削。
  ///
  /// 前置：合集必须已有刮削绑定（`collection_scrape_meta` 有行），否则抛
  /// [StateError]。源级网络失败记入 [EpisodeScrapeOutcome.errors] 且资料零写入
  /// （不吞也不抛，调用方决定展示方式）。
  Future<EpisodeScrapeOutcome> scrapeCollectionEpisodes(
      int collectionId) async {
    final CollectionScrapeMetaRow? meta =
        await _db.getCollectionScrapeMeta(collectionId);
    if (meta == null) {
      throw StateError(
        'collection $collectionId has no scrape binding; scrape it first',
      );
    }

    // 成员 → (book, 文件名解析)。非 video 成员（书/游戏混编合集）不参与。
    final List<MediaCollectionItemRow> items =
        await _db.getCollectionItems(collectionId);
    final List<({VideoBookRow book, VideoNameInfo parsed})> members =
        <({VideoBookRow book, VideoNameInfo parsed})>[];
    for (final MediaCollectionItemRow item in items) {
      if (item.mediaType != 'video') continue;
      final VideoBookRow? book = await _db.getVideoBookByBookUid(item.entryKey);
      if (book == null) continue;
      members.add((
        book: book,
        parsed: parseVideoFilename(p.basename(book.videoPath)),
      ));
    }

    // 源分集列表。
    final Map<String, String> errors = <String, String>{};
    final Map<int, _SourceEpisode> byNumber = <int, _SourceEpisode>{};
    if (meta.source == ScrapeSource.bangumi.name) {
      final BangumiClient? bangumi = _bangumi;
      if (bangumi == null) {
        errors[meta.source] = 'Bangumi client unavailable';
      } else {
        try {
          for (final BangumiEpisodeInfo e
              in await bangumi.fetchSubjectEpisodes(meta.subjectId)) {
            byNumber.putIfAbsent(
              e.episodeNumber,
              () => _SourceEpisode(
                episodeNumber: e.episodeNumber,
                title: e.title,
                summary: e.summary,
                airDate: e.airDate,
              ),
            );
          }
        } on ScrapeNetworkException catch (e) {
          errors[meta.source] = e.toString();
        }
      }
    } else if (meta.source == ScrapeSource.tmdb.name) {
      final TmdbClient? tmdb = _tmdb;
      if (tmdb == null) {
        errors[meta.source] = 'TMDB client unavailable (no API key)';
      } else if (tmdbKindFromDetailUrl(meta.detailUrl) ==
          TmdbSubjectKind.movie) {
        errors[meta.source] = 'movie subject has no episodes';
      } else {
        try {
          for (final TmdbEpisodeInfo e in await tmdb.fetchSeasonEpisodes(
            meta.subjectId,
            _dominantSeason(members),
          )) {
            byNumber.putIfAbsent(
              e.episodeNumber,
              () => _SourceEpisode(
                episodeNumber: e.episodeNumber,
                title: e.title,
                summary: e.summary,
                airDate: e.airDate,
                stillPath: e.stillPath,
              ),
            );
          }
        } on ScrapeNetworkException catch (e) {
          errors[meta.source] = e.toString();
        }
      }
    } else {
      errors[meta.source] = 'source has no episodes endpoint';
    }

    if (errors.isNotEmpty) {
      return EpisodeScrapeOutcome(
        updated: 0,
        unmatched: 0,
        stillsApplied: 0,
        stillsSkippedUserCover: 0,
        errors: errors,
      );
    }

    // 对齐 + 落库。重复集号（v1/v2 双版本文件）各写各的、资料相同——重复不算
    // 未匹配；未匹配 = 解不出集号或源无该集（缺集/特典超范围）。
    int updated = 0;
    int unmatched = 0;
    int stillsApplied = 0;
    int stillsSkippedUserCover = 0;
    for (final ({VideoBookRow book, VideoNameInfo parsed}) member in members) {
      final int? episodeNumber = member.parsed.episode;
      final _SourceEpisode? source =
          episodeNumber == null ? null : byNumber[episodeNumber];
      if (source == null) {
        unmatched++;
        continue;
      }
      await _db.upsertVideoScrapeMeta(VideoScrapeMetaCompanion.insert(
        bookUid: member.book.bookUid,
        source: meta.source,
        subjectId: meta.subjectId,
        // 集名缺失时回退作品名：title 列非空约束，且带 episodeNumber 的行语义
        // 上仍是「这一集」，回退值只影响展示兜底。
        title: source.title ?? meta.title,
        summary: Value<String?>(source.summary),
        airDate: Value<String?>(source.airDate),
        episodeNumber: Value<int?>(source.episodeNumber),
        scrapedAt: DateTime.now(),
      ));
      updated++;

      // 剧照 → 集封面（TMDB only；封面设施未注入则跳过）。
      final CoverDownloader? downloader = _coverDownloader;
      final CoverMetaStore? metaStore = _coverMetaStore;
      final String? stillPath = source.stillPath;
      if (downloader == null || metaStore == null || stillPath == null) {
        continue;
      }
      final CoverMeta? coverMeta = await metaStore.get(member.book.bookUid);
      if (coverMeta != null && coverMeta.origin.isUserChosen) {
        stillsSkippedUserCover++;
        continue;
      }
      try {
        final String coverPath = await downloader.downloadCover(
          url: '${TmdbClient.posterBase}$stillPath',
          bookUid: member.book.bookUid,
          coversDirectory: _coversDirectory ?? await VideoStorage.coversDir(),
        );
        await _db.updateVideoBookCover(member.book.bookUid, coverPath);
        await metaStore.set(
          member.book.bookUid,
          CoverMeta(
            origin: CoverOrigin.autoScraped,
            source: ScrapeSource.tmdb,
            entryId: meta.subjectId,
          ),
        );
        stillsApplied++;
      } on ScrapeNetworkException catch (e) {
        // 剧照失败只影响该集封面，资料已写入；逐集记错不打断批次。
        errors['still_E${source.episodeNumber}'] = e.toString();
      }
    }

    return EpisodeScrapeOutcome(
      updated: updated,
      unmatched: unmatched,
      stillsApplied: stillsApplied,
      stillsSkippedUserCover: stillsSkippedUserCover,
      errors: errors,
    );
  }

  /// 合集成员解析季号的众数；全员无季 → 1（单季剧集文件名普遍不带季号）。
  static int _dominantSeason(
    List<({VideoBookRow book, VideoNameInfo parsed})> members,
  ) {
    final Map<int, int> counts = <int, int>{};
    for (final ({VideoBookRow book, VideoNameInfo parsed}) m in members) {
      final int? season = m.parsed.season;
      if (season != null) {
        counts[season] = (counts[season] ?? 0) + 1;
      }
    }
    int best = 1;
    int bestCount = 0;
    for (final MapEntry<int, int> entry in counts.entries) {
      if (entry.value > bestCount) {
        best = entry.key;
        bestCount = entry.value;
      }
    }
    return best;
  }
}
