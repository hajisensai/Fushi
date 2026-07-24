/// 视频海报刮削**编排层**（流水线第 ⑥ 层 / 收尾棒）。
///
/// 把前面各层（sidecar 识别 → 文件名解析 → 归一化 → 匹配 → 打分 → 下载）串成
/// 可被 UI 直接调用的单本 / 批量流水线，并落地封面文件 + `updateCover` +
/// `cover_meta.json` 元数据 + 用户纠错别名缓存。
///
/// 数据流：`VideoBookRow`（本地视频，远端/流媒体天然不入）→ 本地视频文件路径 →
/// [FilenameParser.candidatesForPath]（目录候选出 title/season、文件候选出 episode，
/// 合并互补）→ 匹配源（离线库 → Bangumi → TMDB，逐层兜底至 high）→
/// [MatchScorer.best] 打分 → high 自动落封面 / medium 进人工确认 / low 保留抽帧。
///
/// 本文件**只 import 引擎层，不修改它们**；引擎层各文件见同目录。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:hibiki/src/media/video/scraper/alias_cache.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/filename_parser.dart';
import 'package:hibiki/src/media/video/scraper/match_scorer.dart';
import 'package:hibiki/src/media/video/scraper/offline_db_downloader.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/poster_downloader.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/sidecar_scanner.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show videoCoverFileName;
import 'package:hibiki_core/hibiki_core.dart' show VideoBookRow;
import 'package:path/path.dart' as p;

/// slim 缓存落盘文件名（与原始库同目录）。
const String kOfflineSlimFileName = 'anime-offline-database.slim.json';

// ─────────────────────────── 单本流水线结果 ───────────────────────────

/// 单本刮削结果（sealed：调用方 switch 穷尽处理）。
sealed class ScrapeOutcome {
  const ScrapeOutcome();
}

/// 已落封面（high 自动应用 / sidecar 直取 / 别名缓存命中）。
class ScrapeApplied extends ScrapeOutcome {
  const ScrapeApplied({
    required this.coverPath,
    required this.origin,
    this.decision,
  });

  /// 落地的封面绝对路径（已 `updateCover`）。
  final String coverPath;

  /// 封面来源（[CoverOrigin.scraped] 或 [CoverOrigin.sidecar]）。
  final CoverOrigin origin;

  /// 在线匹配所得的决策（sidecar 直取时为 null）。
  final MatchDecision? decision;
}

/// 中置信度：候选列表进人工确认队列（不落盘）。
class ScrapeNeedsConfirm extends ScrapeOutcome {
  const ScrapeNeedsConfirm(this.candidates);

  /// 按综合分降序的候选决策（至少一条）。
  final List<MatchDecision> candidates;
}

/// 低置信 / 无候选：保留抽帧封面，不落盘。
class ScrapeNoMatch extends ScrapeOutcome {
  const ScrapeNoMatch();
}

/// 文件名/目录名解析不出标题：无法刮削，跳过。
class ScrapeSkippedNoTitle extends ScrapeOutcome {
  const ScrapeSkippedNoTitle();
}

/// 批量时因封面来源受保护（manual/sidecar/已刮削）而跳过。
class ScrapeSkippedProtected extends ScrapeOutcome {
  const ScrapeSkippedProtected(this.origin);

  final CoverOrigin origin;
}

/// 不参与刮削（远端/流媒体书、无本地路径）。
class ScrapeNotEligible extends ScrapeOutcome {
  const ScrapeNotEligible(this.reason);

  final String reason;
}

/// 网络/写盘等失败（单本失败不中断整批）。
class ScrapeFailed extends ScrapeOutcome {
  const ScrapeFailed(this.error);

  final Object error;
}

// ─────────────────────────── 批量进度 ───────────────────────────

/// 批量刮削逐本进度事件。
class BatchScrapeProgress {
  const BatchScrapeProgress({
    required this.index,
    required this.total,
    required this.book,
    required this.outcome,
  });

  /// 当前处理到第几本（0 基）。
  final int index;

  /// 本批总数。
  final int total;

  /// 当前视频书。
  final VideoBookRow book;

  /// 本本结果。
  final ScrapeOutcome outcome;
}

// ─────────────────────────── 编排服务 ───────────────────────────

/// 海报刮削编排服务（构造注入全部协作者，便于测试用假实现）。
class PosterScraperService {
  PosterScraperService({
    required VideoBookRepository repository,
    required CoverMetaStore coverMetaStore,
    required AliasCache aliasCache,
    required BangumiClient bangumiClient,
    required PosterDownloader posterDownloader,
    TmdbClient? tmdbClient,
    OfflineIndex? offlineIndex,
    bool enableSidecar = true,
    Directory? coversDirectory,
  })  : _repo = repository,
        _coverMeta = coverMetaStore,
        _aliasCache = aliasCache,
        _bangumi = bangumiClient,
        _downloader = posterDownloader,
        _tmdb = tmdbClient,
        _offline = offlineIndex,
        _enableSidecar = enableSidecar,
        _coversDirectory = coversDirectory;

  final VideoBookRepository _repo;
  final CoverMetaStore _coverMeta;
  final AliasCache _aliasCache;
  final BangumiClient _bangumi;
  final PosterDownloader _downloader;
  final TmdbClient? _tmdb;
  final OfflineIndex? _offline;
  final bool _enableSidecar;
  final Directory? _coversDirectory;

  /// 是否已装载离线库（供 UI 决定是否显示「离线」来源徽标 / 下载入口）。
  bool get hasOfflineIndex => _offline != null;

  /// 是否配置了 TMDB（有 key）。
  bool get hasTmdb => _tmdb != null;

  // ── 公开：单本流水线 ────────────────────────────────────────────

  /// 单本刮削。见类注释的数据流；[applyHighConfidence]=false 时即便 high 也只返回
  /// [ScrapeNeedsConfirm]（供「预览不落盘」场景）。
  Future<ScrapeOutcome> scrapeOne(
    VideoBookRow book, {
    bool applyHighConfidence = true,
    Map<String, MatchDecision?>? decisionCache,
  }) async {
    final String path = book.videoPath;
    if (path.isEmpty || _isRemotePath(path)) {
      return const ScrapeNotEligible('remote-or-empty-path');
    }

    // ① sidecar 本地资产（poster.jpg / <base>-poster.jpg）：命中直取，零网络。
    if (_enableSidecar) {
      final SidecarResult sidecar = await SidecarScanner.scan(path);
      final File? poster = sidecar.posterFile;
      if (poster != null) {
        final String coverPath = await _copyLocalPoster(poster, book.bookUid);
        await _repo.updateCover(book.bookUid, coverPath);
        await _coverMeta.set(
          book.bookUid,
          const CoverMeta(origin: CoverOrigin.sidecar),
        );
        return ScrapeApplied(
          coverPath: coverPath,
          origin: CoverOrigin.sidecar,
        );
      }
    }

    // ② 文件名/目录名解析（目录候选出 title/season、文件候选出 episode）。
    final ParsedMediaName? parsed = _mergedParse(path);
    if (parsed == null || parsed.title.isEmpty) {
      return const ScrapeSkippedNoTitle();
    }
    final String cacheKey = parsed.title;

    // ③ 批量目录级去重缓存命中（同目录成员共享标题，避免重复搜索）。
    if (decisionCache != null && decisionCache.containsKey(cacheKey)) {
      return _applyResolved(
        book,
        parsed,
        decisionCache[cacheKey],
        applyHighConfidence: applyHighConfidence,
      );
    }

    // ④ 用户纠错别名缓存命中：重搜该源按 entryId 过滤取回海报（实现简单，复用既有
    //    search，不新增按 id 的端点）。命中即视为 high 强制应用。
    final (ScrapeSource, String)? alias = await _aliasCache.get(cacheKey);
    if (alias != null) {
      final ScrapeCandidate? aliasCandidate =
          await _resolveAliasCandidate(parsed, alias.$1, alias.$2);
      if (aliasCandidate != null) {
        final MatchDecision aliasDecision = MatchScorer.score(
          parsed: parsed,
          candidate: aliasCandidate,
        );
        decisionCache?[cacheKey] = aliasDecision;
        if (applyHighConfidence) {
          final String coverPath = await _applyCandidate(
            bookUid: book.bookUid,
            candidate: aliasCandidate,
          );
          return ScrapeApplied(
            coverPath: coverPath,
            origin: CoverOrigin.scraped,
            decision: aliasDecision,
          );
        }
        return ScrapeNeedsConfirm(<MatchDecision>[aliasDecision]);
      }
    }

    // ⑤ 逐源匹配（离线 → Bangumi → TMDB），停在首个 high。
    final MatchDecision? best = await _resolveBestDecision(parsed);
    decisionCache?[cacheKey] = best;
    return _applyResolved(
      book,
      parsed,
      best,
      applyHighConfidence: applyHighConfidence,
    );
  }

  // ── 公开：批量流水线 ────────────────────────────────────────────

  /// 批量刮削：**只处理封面来源为 autoFrame（或无记录）的本地书**；manual/sidecar/
  /// 已刮削一律跳过（[rescrapeScraped]=true 时才重刮已刮削的）。逐本 yield 进度；
  /// 单本网络异常记 [ScrapeFailed] 继续，不中断整批。同目录成员共享解析结果缓存，
  /// 避免重复搜索。
  Stream<BatchScrapeProgress> scrapeLibrary(
    List<VideoBookRow> books, {
    bool rescrapeScraped = false,
  }) async* {
    final Map<String, MatchDecision?> decisionCache =
        <String, MatchDecision?>{};
    for (int i = 0; i < books.length; i++) {
      final VideoBookRow book = books[i];
      ScrapeOutcome outcome;
      try {
        if (_isRemotePath(book.videoPath) || book.videoPath.isEmpty) {
          outcome = const ScrapeNotEligible('remote-or-empty-path');
        } else {
          final CoverMeta? meta = await _coverMeta.get(book.bookUid);
          final CoverOrigin origin = meta?.origin ?? CoverOrigin.autoFrame;
          final bool protectedOrigin = origin == CoverOrigin.manual ||
              origin == CoverOrigin.sidecar ||
              (origin == CoverOrigin.scraped && !rescrapeScraped);
          if (protectedOrigin) {
            outcome = ScrapeSkippedProtected(origin);
          } else {
            outcome = await scrapeOne(
              book,
              decisionCache: decisionCache,
            );
          }
        }
      } catch (e) {
        outcome = ScrapeFailed(e);
      }
      yield BatchScrapeProgress(
        index: i,
        total: books.length,
        book: book,
        outcome: outcome,
      );
    }
  }

  // ── 公开：手动匹配（UI 弹窗用）─────────────────────────────────

  /// 按 [source] 搜索关键词返回候选（供弹窗数据源分段切换）。离线源为纯内存查询、
  /// 无网络；Bangumi/TMDB 走对应 client（未配置 TMDB 时返回空列表）。
  Future<List<ScrapeCandidate>> searchCandidates({
    required ScrapeSource source,
    required String keyword,
    int? year,
  }) async {
    if (keyword.trim().isEmpty) return const <ScrapeCandidate>[];
    switch (source) {
      case ScrapeSource.offlineDb:
        return _offline?.search(keyword) ?? const <ScrapeCandidate>[];
      case ScrapeSource.bangumi:
        return _bangumi.search(keyword);
      case ScrapeSource.tmdb:
        return _tmdb?.search(keyword, year: year) ?? const <ScrapeCandidate>[];
      case ScrapeSource.manualUrl:
        return const <ScrapeCandidate>[];
    }
  }

  /// 用户在弹窗里点「使用」某候选：下载海报落封面 + `updateCover` + 记 scraped 元数据 +
  /// 记别名缓存（[aliasKey] 非空时）。[bookUids] 多于一个 = 同时应用到整个合集（每个
  /// 成员各落一份封面文件，海报只下载一次后复制分发）。
  Future<void> applyCandidateToBooks({
    required List<String> bookUids,
    required ScrapeCandidate candidate,
    String? aliasKey,
  }) async {
    if (bookUids.isEmpty) return;
    final String firstCover = await _applyCandidate(
      bookUid: bookUids.first,
      candidate: candidate,
    );
    if (bookUids.length > 1) {
      final Directory covers = await _coversDir();
      final CoverMeta meta = CoverMeta(
        origin: CoverOrigin.scraped,
        source: candidate.source,
        entryId: candidate.entryId,
      );
      for (final String uid in bookUids.skip(1)) {
        final String dest = p.join(covers.path, videoCoverFileName(uid));
        await File(firstCover).copy(dest);
        await _repo.updateCover(uid, dest);
        await _coverMeta.set(uid, meta);
      }
    }
    if (aliasKey != null && aliasKey.trim().isNotEmpty) {
      await _aliasCache.put(aliasKey, candidate.source, candidate.entryId);
    }
  }

  /// 对某路径推导批量/别名缓存 key（= 目录+文件合并解析后的主标题，可空）。UI 弹窗
  /// 预填搜索框、记别名时共用，保证 key 与批量流水线一致。
  String? parsedTitleForPath(String videoPath) =>
      _mergedParse(videoPath)?.title;

  /// 对候选跑打分得置信度徽标（弹窗每条候选调用）。
  MatchDecision scoreCandidate({
    required ParsedMediaName parsed,
    required ScrapeCandidate candidate,
  }) =>
      MatchScorer.score(parsed: parsed, candidate: candidate);

  /// 解析某路径为 [ParsedMediaName]（弹窗打分需要 parsed；无标题返回 null）。
  ParsedMediaName? parseForPath(String videoPath) => _mergedParse(videoPath);

  // ── 离线库装载辅助 ─────────────────────────────────────────────

  /// 装载离线别名库：有 slim 缓存读 slim；只有原始 JSON 则 compute 解析后写 slim；
  /// 都没有返回 null。任意读/解析失败均降级为 null（不抛）。
  static Future<OfflineIndex?> loadOfflineIndex(Directory dir) async {
    final File slim = File(p.join(dir.path, kOfflineSlimFileName));
    final File raw = File(p.join(dir.path, OfflineDbDownloader.fileName));
    try {
      if (await slim.exists()) {
        try {
          final List<OfflineAnimeRecord> records =
              OfflineIndex.decodeSlim(await slim.readAsString());
          return OfflineIndex(records);
        } on FormatException {
          // slim 版本/结构不符：落到原始 JSON 重建。
        }
      }
      if (await raw.exists()) {
        final List<OfflineAnimeRecord> records = await compute(
          OfflineIndex.parseDatabaseJson,
          await raw.readAsString(),
        );
        await _writeSlim(slim, OfflineIndex.encodeSlim(records));
        return OfflineIndex(records);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static Future<void> _writeSlim(File slim, String content) async {
    final File tmp = File('${slim.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    if (await slim.exists()) await slim.delete();
    await tmp.rename(slim.path);
  }

  // ── 内部实现 ───────────────────────────────────────────────────

  /// 把已解析出的最佳决策落地为结果（high 应用 / medium 待确认 / 其余保留抽帧）。
  Future<ScrapeOutcome> _applyResolved(
    VideoBookRow book,
    ParsedMediaName parsed,
    MatchDecision? decision, {
    required bool applyHighConfidence,
  }) async {
    if (decision == null) return const ScrapeNoMatch();
    switch (decision.confidence) {
      case MatchConfidence.high:
        if (!applyHighConfidence) {
          return ScrapeNeedsConfirm(<MatchDecision>[decision]);
        }
        final String coverPath = await _applyCandidate(
          bookUid: book.bookUid,
          candidate: decision.candidate,
          aliasKey: parsed.title,
        );
        return ScrapeApplied(
          coverPath: coverPath,
          origin: CoverOrigin.scraped,
          decision: decision,
        );
      case MatchConfidence.medium:
        return ScrapeNeedsConfirm(<MatchDecision>[decision]);
      case MatchConfidence.low:
        return const ScrapeNoMatch();
    }
  }

  /// 逐源匹配：离线库（有则先）→ Bangumi → TMDB（非 null 或电影提示时）。逐层取
  /// [MatchScorer.best]，命中 high 立即返回；否则保留全程最高分决策。
  Future<MatchDecision?> _resolveBestDecision(ParsedMediaName parsed) async {
    MatchDecision? best;

    MatchDecision? consider(List<ScrapeCandidate> candidates) {
      final MatchDecision? d =
          MatchScorer.best(parsed: parsed, candidates: candidates);
      if (d == null) return best;
      if (best == null || _isBetter(d, best!)) best = d;
      return best;
    }

    // 离线库（纯内存，无网络，优先）。
    if (_offline != null) {
      consider(_offline.search(parsed.title));
      if (best?.confidence == MatchConfidence.high) return best;
    }

    // Bangumi 主源。
    consider(await _bangumi.search(parsed.title));
    if (best?.confidence == MatchConfidence.high) return best;

    // TMDB 补充源（有 key，或有电影提示时优先补 TMDB）。
    if (_tmdb != null) {
      consider(await _tmdb.search(parsed.title, year: parsed.year));
    }
    return best;
  }

  /// 别名命中：重搜对应源，按 entryId 过滤取回具体候选（含海报 URL）；无则 null。
  Future<ScrapeCandidate?> _resolveAliasCandidate(
    ParsedMediaName parsed,
    ScrapeSource source,
    String entryId,
  ) async {
    final List<ScrapeCandidate> candidates =
        await searchCandidates(source: source, keyword: parsed.title);
    for (final ScrapeCandidate c in candidates) {
      if (c.entryId == entryId) return c;
    }
    return null;
  }

  /// 下载并落地单本封面：下载 → `updateCover` → 记 scraped 元数据。[aliasKey] 非空时
  /// 顺便记一条别名缓存（自动 high 应用也记住决策，下次重刮同目录直接命中）。返回封面路径。
  Future<String> _applyCandidate({
    required String bookUid,
    required ScrapeCandidate candidate,
    String? aliasKey,
  }) async {
    final String coverPath = await _downloader.downloadPoster(
      url: candidate.posterUrl,
      bookUid: bookUid,
      coversDirectory: _coversDirectory,
    );
    await _repo.updateCover(bookUid, coverPath);
    await _coverMeta.set(
      bookUid,
      CoverMeta(
        origin: CoverOrigin.scraped,
        source: candidate.source,
        entryId: candidate.entryId,
      ),
    );
    if (aliasKey != null && aliasKey.trim().isNotEmpty) {
      await _aliasCache.put(aliasKey, candidate.source, candidate.entryId);
    }
    return coverPath;
  }

  /// 把本地 sidecar 海报文件复制为封面（`.tmp`+rename 到 covers 目录，文件名走
  /// [videoCoverFileName] 约定，与下载/抽帧同目录同命名）。返回封面绝对路径。
  Future<String> _copyLocalPoster(File poster, String bookUid) async {
    final Directory covers = await _coversDir();
    await covers.create(recursive: true);
    final String finalPath = p.join(covers.path, videoCoverFileName(bookUid));
    final File tmp = File('$finalPath.tmp');
    if (await tmp.exists()) await tmp.delete();
    await poster.copy(tmp.path);
    final File finalFile = File(finalPath);
    if (await finalFile.exists()) await finalFile.delete();
    await tmp.rename(finalPath);
    return finalPath;
  }

  Future<Directory> _coversDir() async =>
      _coversDirectory ?? await VideoStorage.coversDir();

  /// 目录候选 + 文件候选合并：各字段取首个非空（[FilenameParser.candidatesForPath]
  /// 目录候选在前，故 title/season 取自目录、episode 补自文件）。全无标题返回 null。
  ParsedMediaName? _mergedParse(String videoPath) {
    final List<ParsedMediaName> candidates =
        FilenameParser.candidatesForPath(videoPath);
    if (candidates.isEmpty) return null;
    String title = '';
    String? secondaryTitle;
    int? episode;
    int? season;
    int? year;
    String? releaseGroup;
    String? resolution;
    bool isMovieHint = false;
    for (final ParsedMediaName c in candidates) {
      if (title.isEmpty && c.title.isNotEmpty) title = c.title;
      secondaryTitle ??= c.secondaryTitle;
      episode ??= c.episode;
      season ??= c.season;
      year ??= c.year;
      releaseGroup ??= c.releaseGroup;
      resolution ??= c.resolution;
      if (c.isMovieHint) isMovieHint = true;
    }
    if (title.isEmpty) return null;
    return ParsedMediaName(
      title: title,
      secondaryTitle: secondaryTitle,
      episode: episode,
      season: season,
      year: year,
      releaseGroup: releaseGroup,
      resolution: resolution,
      isMovieHint: isMovieHint,
    );
  }

  /// 综合分比较：契约 [MatchDecision] 不带总分，用置信度分级 + 标题分近似比较。
  static bool _isBetter(MatchDecision a, MatchDecision b) {
    final int ca = _confidenceRank(a.confidence);
    final int cb = _confidenceRank(b.confidence);
    if (ca != cb) return ca > cb;
    return a.titleScore > b.titleScore;
  }

  static int _confidenceRank(MatchConfidence c) {
    switch (c) {
      case MatchConfidence.high:
        return 2;
      case MatchConfidence.medium:
        return 1;
      case MatchConfidence.low:
        return 0;
    }
  }

  /// 流媒体/远端书判据：videoPath 为 http/https（与 VideoBooks 表注释一致）。
  static bool _isRemotePath(String path) =>
      path.startsWith('http://') || path.startsWith('https://');
}
