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
import 'package:hibiki/src/media/video/scraper/anilist_client.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/jikan_client.dart';
import 'package:hibiki/src/media/video/scraper/collection_member_policy.dart'
    show multiMemberCollectionIdByVideoUid;
import 'package:hibiki/src/media/video/scraper/cover_meta_store.dart';
import 'package:hibiki/src/media/video/scraper/filename_parser.dart';
import 'package:hibiki/src/media/video/scraper/match_scorer.dart';
import 'package:hibiki/src/media/video/scraper/offline_db_downloader.dart';
import 'package:hibiki/src/media/video/scraper/offline_index.dart';
import 'package:hibiki/src/media/video/scraper/cover_downloader.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/media/video/scraper/sidecar_scanner.dart';
import 'package:hibiki/src/media/video/scraper/title_normalizer.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki/src/media/media_cover_service.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_storage.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/media/video/video_cover_extractor.dart'
    show videoCoverFileName;
import 'package:hibiki_core/hibiki_core.dart'
    show MediaCollectionRow, MediaImageKind, VideoBookRow;
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

  /// 封面来源（[CoverOrigin.autoScraped] 或 [CoverOrigin.sidecar]）。
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
/// 一次标题解析的匹配结果，[CoverScraperService] 的目录级缓存单元。
///
/// [uniqueExactTitle] = [decision] 的候选（标题或任一别名）归一化后与解析标题
/// **完全相等**，且本次实际查询过的候选里**只有它一个**这样的条目。综合分
/// [MatchConfidence.high] 只说明「分够了」（[MatchScorer] 允许标题相似度 0.70 +
/// 年份吻合就上 0.85 线），不等于「标题就是这一部」——无人值守整库重刮要覆盖
/// 已有封面时，判据必须是这个而不是分数。
class _ResolvedMatch {
  const _ResolvedMatch(this.decision, {required this.uniqueExactTitle});

  static const _ResolvedMatch none =
      _ResolvedMatch(null, uniqueExactTitle: false);

  final MatchDecision? decision;
  final bool uniqueExactTitle;
}

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
class CoverScraperService {
  CoverScraperService({
    required VideoBookRepository repository,
    required CoverMetaStore coverMetaStore,
    required AliasCache aliasCache,
    required BangumiClient bangumiClient,
    required CoverDownloader coverDownloader,
    TmdbClient? tmdbClient,
    AniListClient? aniListClient,
    JikanClient? jikanClient,
    OfflineIndex? offlineIndex,
    bool enableSidecar = true,
    SidecarGeneratedArtifactChecker? generatedSidecarArtifactChecker,
    Directory? coversDirectory,
    Directory? collectionCoversDirectory,
    Directory? imagesDirectory,
  })  : _collectionCoversDirectory = collectionCoversDirectory,
        _imagesDirectory = imagesDirectory,
        _repo = repository,
        _coverMeta = coverMetaStore,
        _aliasCache = aliasCache,
        _bangumi = bangumiClient,
        _downloader = coverDownloader,
        _tmdb = tmdbClient,
        _anilist = aniListClient,
        _jikan = jikanClient,
        _offline = offlineIndex,
        _enableSidecar = enableSidecar,
        _generatedSidecarArtifactChecker = generatedSidecarArtifactChecker,
        _coversDirectory = coversDirectory;

  final VideoBookRepository _repo;
  final CoverMetaStore _coverMeta;
  final AliasCache _aliasCache;
  final BangumiClient _bangumi;
  final CoverDownloader _downloader;
  final TmdbClient? _tmdb;

  /// AniList / Jikan：零 key 门槛的动画补充源。null = 未注入（测试或显式禁用）。
  final AniListClient? _anilist;
  final JikanClient? _jikan;
  final OfflineIndex? _offline;
  final bool _enableSidecar;
  final SidecarGeneratedArtifactChecker? _generatedSidecarArtifactChecker;
  final Directory? _coversDirectory;

  /// 合集自有封面目录（测试注入临时目录；null = 取生产
  /// [VideoStorage.collectionCoversDir]）。
  final Directory? _collectionCoversDirectory;

  /// 单视频附加图目录（测试注入临时目录；null = 取生产 [VideoStorage.imagesDir]）。
  final Directory? _imagesDirectory;

  /// 条目详情缓存 / 失败记忆，key = `<source>:<entryId>`。见 [_persistMetadata]。
  final Map<String, ScrapeMetadata> _metadataCache = <String, ScrapeMetadata>{};
  final Set<String> _metadataFailed = <String>{};

  /// 本实例内已尝试过「子篇海报改投合集封面」的 collectionId（成功或失败都记）。
  /// 26 集番只该发一次海报下载，也不该整季逐集重试同一个打不通的 CDN。
  final Set<int> _collectionCoverAttempted = <int>{};

  /// 是否已装载离线库（供 UI 决定是否显示「离线」来源徽标 / 下载入口）。
  bool get hasOfflineIndex => _offline != null;

  /// 是否配置了 TMDB（有 key）。
  bool get hasTmdb => _tmdb != null;

  // ── 公开：单本流水线 ────────────────────────────────────────────

  /// 单本刮削。见类注释的数据流；[applyHighConfidence]=false 时即便 high 也只返回
  /// [ScrapeNeedsConfirm]（供「预览不落盘」场景）。
  ///
  /// [requireUniqueExactTitle]=true 时自动落盘的判据从「综合分 high」收紧成
  /// 「唯一归一化精确标题」（见 [_ResolvedMatch]），近似命中一律降级成
  /// [ScrapeNeedsConfirm] 留给人工确认。默认 false：既有自动刮削只覆盖抽帧封面，
  /// 判据不变。
  Future<ScrapeOutcome> scrapeOne(
    VideoBookRow book, {
    bool applyHighConfidence = true,
    bool requireUniqueExactTitle = false,
    Map<String, _ResolvedMatch>? decisionCache,
  }) async {
    final String path = book.videoPath;
    if (path.isEmpty || _isRemotePath(path)) {
      return const ScrapeNotEligible('remote-or-empty-path');
    }

    // ① sidecar 本地资产（poster.jpg / <base>-poster.jpg）：命中直取，零网络。
    if (_enableSidecar) {
      final SidecarResult sidecar = await SidecarScanner.scan(
        path,
        generatedArtifactChecker: _generatedSidecarArtifactChecker,
      );
      final File? poster = sidecar.posterFile;
      if (poster != null && !sidecar.posterIsUnmodifiedGeneratedArtifact) {
        final String coverPath = await _copySidecarCover(poster, book.bookUid);
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
        decisionCache[cacheKey]!,
        applyHighConfidence: applyHighConfidence,
        requireUniqueExactTitle: requireUniqueExactTitle,
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
        // 别名是「这个标题上次判成了哪个条目」的记忆（用户弹窗确认写的、自动
        // high 应用也写），指向的是一个**已确定的条目身份**而不是一次新猜测，
        // 因此按唯一精确处理：重刮时把上次的判定原样恢复回去。
        decisionCache?[cacheKey] =
            _ResolvedMatch(aliasDecision, uniqueExactTitle: true);
        if (applyHighConfidence) {
          // 本次落盘是**程序**做的决定（别名只是记忆），标 autoScraped；用户在
          // 弹窗里亲手选的那条路走 [applyCandidateToBooks]，标 userScraped。
          final String coverPath = await _applyCandidate(
            bookUid: book.bookUid,
            candidate: aliasCandidate,
            origin: CoverOrigin.autoScraped,
          );
          return ScrapeApplied(
            coverPath: coverPath,
            origin: CoverOrigin.autoScraped,
            decision: aliasDecision,
          );
        }
        return ScrapeNeedsConfirm(<MatchDecision>[aliasDecision]);
      }
    }

    // ⑤ 逐源匹配（离线 → Bangumi → TMDB），停在首个 high。
    final _ResolvedMatch resolved = await _resolveBestDecision(parsed);
    decisionCache?[cacheKey] = resolved;
    return _applyResolved(
      book,
      parsed,
      resolved,
      applyHighConfidence: applyHighConfidence,
      requireUniqueExactTitle: requireUniqueExactTitle,
    );
  }

  // ── 公开：批量流水线 ────────────────────────────────────────────

  /// 批量刮削：逐本按封面来源决定能不能覆盖，yield 进度；单本网络异常记
  /// [ScrapeFailed] 继续，不中断整批。同目录成员共享解析结果缓存，避免重复搜索。
  ///
  /// **覆盖决策只在这一层做**（[CoverOriginBatchPolicy.batchOverwritePolicy]
  /// 是唯一判据来源，
  /// 所有入口——后台自动刮、页头「全部刮削」——都过这里）：
  ///
  /// | 封面来源 | 许可 | [rescrapeScraped]=false | =true |
  /// |---|---|---|---|
  /// | autoFrame / 无记录 | free | 覆盖（综合分 high） | 覆盖（综合分 high） |
  /// | autoScraped | rescrapeOnly | 跳过 | 覆盖（综合分 high） |
  /// | scraped（存量、来源未知） | legacyStrict | 跳过 | 只有**唯一归一化精确标题**才覆盖 |
  /// | manual / userScraped / sidecar | never | 跳过 | **跳过**（开关管不到用户手选） |
  ///
  /// [rescrapeScraped] 只解锁「要不要覆盖**自动**刮来的旧结果」，它**不是**
  /// 「覆盖一切」——用户亲手选定的封面（[CoverOrigin.userScraped]，见
  /// [applyCandidateToBooks]）在任何开关下都不会被动（BUG-1325）。
  ///
  /// 合集子篇（成员数 ≥2 的合集成员，判据 [multiMemberCollectionIdByVideoUid]）
  /// 在本层**一律不落成员封面**、任何开关都解不开——但那张作品海报**不被丢弃**，
  /// 而是改落到它所属合集的自有封面（[_promoteCollectionCover] →
  /// `MediaCollections.coverPath`）。用户 2026-08-02 的口径是「作品海报只归合集
  /// 封面」，不是「作品海报消失」：只闸不改投会让多集合集卡从显示海报退化成显示
  /// 首集抽帧。子篇成员封面保持抽帧缩略图或集级剧照（EpisodeScrapeService），两
  /// 者都没有就保持无封面。用户在弹窗亲手匹配（[applyCandidateToBooks]）不经此闸。
  Stream<BatchScrapeProgress> scrapeLibrary(
    List<VideoBookRow> books, {
    bool rescrapeScraped = false,
  }) async* {
    final Map<String, _ResolvedMatch> decisionCache =
        <String, _ResolvedMatch>{};
    // 子篇归属每批取一次（全量单查询，消 N+1）；含 sidecar 在内的整条 scrapeOne
    // 封面流水线对子篇都不放行——目录级 poster.jpg 刷满整季与在线海报同症
    // （Kodi/Jellyfin 生态单集图约定是 -thumb 而非 -poster，此处整体跳过实际不
    // 损失单集 sidecar）。
    final Map<String, int> memberCollectionIds =
        await _repo.multiMemberCollectionIds();
    for (int i = 0; i < books.length; i++) {
      final VideoBookRow book = books[i];
      ScrapeOutcome outcome;
      try {
        if (_isRemotePath(book.videoPath) || book.videoPath.isEmpty) {
          outcome = const ScrapeNotEligible('remote-or-empty-path');
        } else {
          final CoverMeta? meta = await _coverMeta.get(book.bookUid);
          final CoverOrigin origin = meta?.origin ?? CoverOrigin.autoFrame;
          final CoverOverwritePolicy policy = origin.batchOverwritePolicy;
          final int? memberCollectionId = memberCollectionIds[book.bookUid];
          final bool allowed = memberCollectionId == null &&
              switch (policy) {
                CoverOverwritePolicy.free => true,
                CoverOverwritePolicy.rescrapeOnly ||
                CoverOverwritePolicy.legacyStrict =>
                  rescrapeScraped,
                CoverOverwritePolicy.never => false,
              };
          if (!allowed) {
            outcome = ScrapeSkippedProtected(origin);
            // 封面受保护 ≠ 条目资料也不要。手动设过封面、或目录里有 poster.jpg
            // 的库（整理过的库很常见）此前会被整本跳过、永远刮不到简介/评分；
            // 这里补一次**只刮资料不碰封面**的匹配。outcome 仍报
            // ScrapeSkippedProtected（说的是封面），既有语义不变。
            final MatchDecision? decision =
                await _scrapeMetadataOnly(book, decisionCache);
            // 子篇：同一次匹配得到的作品海报改投合集自有封面（不重下、不碰成员）。
            if (memberCollectionId != null && decision != null) {
              await _promoteCollectionCover(
                memberCollectionId,
                decision.candidate,
              );
            }
          } else {
            outcome = await scrapeOne(
              book,
              requireUniqueExactTitle:
                  policy == CoverOverwritePolicy.legacyStrict,
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

  /// 只刮**条目资料**、绝不碰封面：给封面来源受保护（manual / sidecar / 已刮）的
  /// 书、以及合集子篇补资料用。走与封面刮削同一套解析 + 匹配 + 打分，但只在 high
  /// 置信度落资料——medium 在封面侧要人工确认，资料侧同理不能自作主张（配错条目
  /// = 一整篇别人的简介，比配错封面更难被一眼发现）。
  ///
  /// 返回本次采信的 high 决策（无匹配 / 置信度不足返回 null），供调用方复用同一
  /// 次匹配的海报改投合集封面——不返回就得为同一本再解析+搜索一遍。
  Future<MatchDecision?> _scrapeMetadataOnly(
    VideoBookRow book,
    Map<String, _ResolvedMatch> decisionCache,
  ) async {
    final ParsedMediaName? parsed = _mergedParse(book.videoPath);
    if (parsed == null || parsed.title.isEmpty) return null;
    final String cacheKey = parsed.title;

    final _ResolvedMatch resolved;
    if (decisionCache.containsKey(cacheKey)) {
      resolved = decisionCache[cacheKey]!;
    } else {
      resolved = await _resolveBestDecision(parsed);
      decisionCache[cacheKey] = resolved;
    }
    final MatchDecision? decision = resolved.decision;
    if (decision == null || decision.confidence != MatchConfidence.high) {
      return null;
    }
    await _persistMetadata(
      bookUids: <String>[book.bookUid],
      candidate: decision.candidate,
    );
    return decision;
  }

  /// 子篇的作品海报改投**所属合集的自有封面**（用户 2026-08-02：作品海报只归合集
  /// 封面）。整条流水线里唯一会因为「这本是子篇」而发生的写入，且只写合集那一行。
  ///
  /// 三条不变量：
  /// * **不覆盖已有合集封面**——用户手动刮过的合集（`applyCollectionScrape`）或
  ///   上一集已改投过的，自动路径一律让路；
  /// * **一合集一次**（[_collectionCoverAttempted]）——26 集番不该发 26 次海报下
  ///   载；失败也记，避免整季逐集重试同一个打不通的 CDN；
  /// * **失败不升级**——本轮 outcome 已是 `ScrapeSkippedProtected`（说的是成员封
  ///   面），合集封面下载失败不该把它翻成 `ScrapeFailed` 误导 UI，只记日志。
  Future<void> _promoteCollectionCover(
    int collectionId,
    ScrapeCandidate candidate,
  ) async {
    if (candidate.posterUrl.isEmpty) return;
    if (!_collectionCoverAttempted.add(collectionId)) return;
    try {
      final MediaCollectionRow? row =
          await _repo.getMediaCollectionById(collectionId);
      if (row == null) return;
      final String? existing = row.coverPath;
      if (existing != null && existing.isNotEmpty) return;
      final String coverPath = await downloadCollectionCover(
        collectionId: collectionId,
        candidate: candidate,
      );
      await _repo.updateMediaCollectionCoverPath(collectionId, coverPath);
    } catch (e, stack) {
      ErrorLogService.instance
          .log('CoverScraperService.promoteCollectionCover', e, stack);
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
      case ScrapeSource.anilist:
        return _anilist?.search(keyword, year: year) ??
            const <ScrapeCandidate>[];
      case ScrapeSource.jikan:
        return _jikan?.search(keyword, year: year) ?? const <ScrapeCandidate>[];
      case ScrapeSource.manualUrl:
        return const <ScrapeCandidate>[];
    }
  }

  /// 本次构建**真正可用**的搜索源（按查询代价升序：本地内存 → 各在线源）。
  ///
  /// 未注入的 client（TMDB 无 key、测试没给假实现）不在列——这样调用方不必再写
  /// 「这个源配了吗」的分支，「可用性」只在这一个地方判定。
  List<ScrapeSource> get availableSearchSources => <ScrapeSource>[
        if (_offline != null) ScrapeSource.offlineDb,
        ScrapeSource.bangumi,
        if (_tmdb != null) ScrapeSource.tmdb,
        if (_anilist != null) ScrapeSource.anilist,
        if (_jikan != null) ScrapeSource.jikan,
      ];

  /// **并发查全部可用源并合并**（手动匹配弹窗用）。
  ///
  /// 与 [_resolveBestDecision]（自动刮削）的分工是有意的、不是重复实现：
  /// - 自动刮削按代价**逐层兜底**，命中 high 立即停 —— 批量刮 500 本时不能每本都
  ///   发 4 个请求；
  /// - 手动匹配是用户已经盯着屏幕在等，要的是**一次看全**，所以并发全查。
  ///
  /// 失败策略：**部分源失败只降级不报错**（其余源的结果照常展示，失败明细留在
  /// [AggregatedSearchResult.failures] 供取证）；只有**全部源都失败**才算「搜不了」，
  /// 由 UI 出可见失败态。这保住了 BUG-1176 的「搜不到 ≠ 搜不了」分界。
  Future<AggregatedSearchResult> searchAllSources({
    required String keyword,
    int? year,
  }) async {
    final List<ScrapeSource> sources = availableSearchSources;
    final Map<ScrapeSource, Object> failures = <ScrapeSource, Object>{};

    final List<List<ScrapeCandidate>> perSource =
        await Future.wait(sources.map((ScrapeSource source) async {
      try {
        return await searchCandidates(
          source: source,
          keyword: keyword,
          year: year,
        );
      } catch (e) {
        failures[source] = e;
        return const <ScrapeCandidate>[];
      }
    }));

    // 合并去重：**只在同源内按 entryId 去重**。跨源刻意不去重——Bangumi 的中文条目
    // 与 AniList 的日文条目是同一部作品的不同表示（标题语言、评分体系、海报都不同），
    // 合并会丢掉用户正想要的那一个。用户看到「同一部片的几种版本」是特性不是 bug。
    final List<ScrapeCandidate> merged = <ScrapeCandidate>[];
    final Set<String> seen = <String>{};
    for (final List<ScrapeCandidate> batch in perSource) {
      for (final ScrapeCandidate candidate in batch) {
        final String key = '${candidate.source.name}/${candidate.entryId}';
        if (!seen.add(key)) continue;
        merged.add(candidate);
      }
    }

    return AggregatedSearchResult(
      candidates: merged,
      failures: failures,
      queriedSources: sources,
    );
  }

  /// 添加/修改 Bangumi 映射：按 subject id 直取条目映射为候选（用户贴 ID/URL
  /// 改绑）。404/无海报 → null；网络失败抛 [ScrapeNetworkException] 由弹窗降级。
  Future<ScrapeCandidate?> fetchBangumiCandidateById(String subjectId) =>
      _bangumi.fetchSubjectCandidate(subjectId);

  /// 用户在弹窗里点「使用」某候选：下载海报落封面 + `updateCover` +
  /// 记 [CoverOrigin.userScraped] 元数据 + 记别名缓存（[aliasKey] 非空时）。
  /// [bookUids] 多于一个 = 同时应用到整个合集（每个成员各落一份封面文件，海报只
  /// 下载一次后复制分发）。
  ///
  /// 这是**唯一**由用户亲手拍板的在线封面落地路径，所以标 [CoverOrigin.userScraped]
  /// 而不是 [CoverOrigin.autoScraped]——批量刮削据此永不覆盖它（BUG-1325）。
  Future<void> applyCandidateToBooks({
    required List<String> bookUids,
    required ScrapeCandidate candidate,
    String? aliasKey,
  }) async {
    if (bookUids.isEmpty) return;
    final String firstCover = await _applyCandidate(
      bookUid: bookUids.first,
      candidate: candidate,
      origin: CoverOrigin.userScraped,
    );
    if (bookUids.length > 1) {
      final Directory covers = await _coversDir();
      final CoverMeta meta = CoverMeta(
        origin: CoverOrigin.userScraped,
        source: candidate.source,
        entryId: candidate.entryId,
      );
      for (final String uid in bookUids.skip(1)) {
        final String dest = p.join(covers.path, videoCoverFileName(uid));
        // 统一收口：原子拷贝 + 双键驱逐（BUG-1118）。首成员已由
        // _applyCandidate → downloadCover 落盘时经同一收口驱逐。
        await MediaCoverService.applyCoverFile(
          source: File(firstCover),
          destPath: dest,
        );
        await _repo.updateCover(uid, dest);
        await _coverMeta.set(uid, meta);
      }
    }
    // 条目资料对整个合集是同一份（同一 subject），只拉一次详情、写给每个成员。
    await _persistMetadata(bookUids: bookUids, candidate: candidate);
    if (aliasKey != null && aliasKey.trim().isNotEmpty) {
      await _aliasCache.put(aliasKey, candidate.source, candidate.entryId);
    }
  }

  /// 只把候选的海报下载成**合集自有**封面文件，返回绝对路径（BUG-1211）。
  ///
  /// 与 [applyCandidateToBooks] 的关键区别：**一个成员都不碰**——不写任何
  /// `VideoBooks.cover_path`、不写 `cover_meta.json`、不写 `video_scrape_meta`、
  /// 不写别名缓存。「给合集换封面」就该只改合集自己那张图；把封面/条目资料刷进每一集
  /// 是用户明确否决的语义。
  ///
  /// 落点 `<video_covers>/collections/<collectionId>.jpg`（见
  /// [VideoStorage.collectionCoversDirName] 对撞名与历史 GC 的说明）。下载走与成员
  /// 封面同一个 [CoverDownloader]：同样的 2xx + 图片魔数校验、同样的原子
  /// `.tmp`+rename 落盘与双键解码缓存驱逐（BUG-1118），换封面失败绝不留半张图。
  ///
  /// DB 写入由调用方负责（`updateMediaCollectionCoverPath`）：本层不持有
  /// [HibikiDatabase]，也不该为一列写入把整个数据库拖进刮削服务的依赖面。
  Future<String> downloadCollectionCover({
    required int collectionId,
    required ScrapeCandidate candidate,
  }) async {
    final Directory covers =
        _collectionCoversDirectory ?? await VideoStorage.collectionCoversDir();
    return _downloader.downloadCover(
      url: candidate.posterUrl,
      bookUid: '$collectionId',
      coversDirectory: covers,
    );
  }

  /// 拉条目详情并落 `video_scrape_meta`（「抄 Bangumi」）。
  ///
  /// Bangumi 源走 [BangumiClient.fetchSubject] 取全量资料（简介/评分/放送/标签/
  /// infobox）；离线库 / TMDB 源没有对应详情端点，退化为**由候选自身**拼一份最小
  /// 资料（标题/年份/话数/详情页/评分文本），保证「刮过就有行」这条不变量成立——
  /// 否则自动刮削每次扫描都会把这些书当成未刮过而反复重刮。
  ///
  /// 详情请求失败**不**回滚封面：封面已经落地是既成事实，资料是可重建缓存。此时
  /// 不写行，下次扫描会重试（进程内 attempted 集合兜住无限重试，见
  /// `VideoScrapeAutoService`）。
  ///
  /// 同一 subject 的详情在本 service 生命周期内只拉一次（[_metadataCache]）：一部
  /// 26 集番的 26 个成员共享同一条目，缓存把 26 次详情请求压成 1 次；失败也记
  /// （[_metadataFailed]），避免整季逐集重试同一个打不通的端点。
  Future<void> _persistMetadata({
    required List<String> bookUids,
    required ScrapeCandidate candidate,
  }) async {
    if (bookUids.isEmpty) return;
    final String key = '${candidate.source.name}:${candidate.entryId}';
    if (_metadataFailed.contains(key)) return;

    ScrapeMetadata? meta = _metadataCache[key];
    if (meta == null) {
      if (candidate.source == ScrapeSource.bangumi) {
        try {
          meta = await _bangumi.fetchSubject(candidate.entryId);
        } on ScrapeNetworkException {
          // 详情端点不可达/条目已删：本轮不落资料行，留待下次扫描重试。
          _metadataFailed.add(key);
          return;
        }
      } else {
        meta = _metadataFromCandidate(candidate);
      }
      _metadataCache[key] = meta;
    }
    for (final String uid in bookUids) {
      await _repo.saveScrapeMetadata(uid, meta);
    }
  }

  /// 非 Bangumi 源的降级资料：只用候选里已有的字段，不编造缺失内容。
  ///
  /// TMDB 的简介 / 评分随搜索响应一起回来（见 `tmdb_client.dart`），所以这条降级路
  /// **不再**是「只有标题和年份」的空壳——那些字段以前是有的，只是没人接。
  static ScrapeMetadata _metadataFromCandidate(ScrapeCandidate candidate) {
    return ScrapeMetadata(
      source: candidate.source,
      subjectId: candidate.entryId,
      title: candidate.title,
      originalTitle: candidate.aliases.isEmpty ? null : candidate.aliases.first,
      summary: candidate.summary,
      airDate: candidate.year == null ? null : '${candidate.year}',
      rating: candidate.rating,
      ratingCount: candidate.ratingCount,
      episodeCount: candidate.episodeCount,
      detailUrl: candidate.detailUrl,
    );
  }

  /// 合集刮削：一次拿齐封面 + 横版背景 + 条目资料（BUG-1310）。
  ///
  /// 取代原先只下海报的 [downloadCollectionCover]。三样产物一并返回给调用方落库，
  /// 本层仍不碰 [HibikiDatabase]（见类顶注）。
  ///
  /// **只写合集自己**：刻意不调 [applyCandidateToBooks]——那条路会逐成员写
  /// cover_path / cover_meta / video_scrape_meta，正是用户否决的「改合集封面却刷了
  /// 每一集」（BUG-1211）。合集的资料属于合集这一个容器。
  ///
  /// 失败语义分两级：
  /// * 海报下载失败 → 抛（没有封面这次刮削就是失败的，与旧行为一致）；
  /// * 背景下载失败 → **咽掉并留 null**。背景是锦上添花，不能让一张可有可无的图
  ///   把已经成功的封面 + 资料整体拖失败；hero 自会回落到海报 + 模糊垫底。
  /// * 资料详情端点失败 → 由候选降级拼一份（[_metadataFromCandidate]），保证
  ///   「刮过就有行」，不至于每次进详情页都当成没刮过。
  Future<CollectionScrapeResult> applyCandidateToCollection({
    required int collectionId,
    required ScrapeCandidate candidate,
  }) async {
    final Directory covers =
        _collectionCoversDirectory ?? await VideoStorage.collectionCoversDir();
    final String coverPath = await _downloader.downloadCover(
      url: candidate.posterUrl,
      bookUid: '$collectionId',
      coversDirectory: covers,
    );

    final List<ScrapedMediaImage> images = await _downloadImages(
      candidate: candidate,
      directory: covers,
      filePrefix: '$collectionId',
    );

    ScrapeMetadata metadata;
    if (candidate.source == ScrapeSource.bangumi) {
      try {
        metadata = await _bangumi.fetchSubject(candidate.entryId);
      } on ScrapeNetworkException {
        metadata = _metadataFromCandidate(candidate);
      }
    } else {
      metadata = _metadataFromCandidate(candidate);
    }

    return CollectionScrapeResult(
      coverPath: coverPath,
      images: images,
      metadata: metadata,
    );
  }

  /// 下载附加图组（v68，Jellyfin 图组对齐；合集与散装电影共用）。
  ///
  /// TMDB 源走 `/images` 端点拿完整图组（多张无字 backdrop + 带字横图 + logo）；
  /// 其余源退化为候选自带的单张 backdropUrl（AniList banner）。失败语义延续
  /// BUG-1310 的分级：附加图是锦上添花，**任何一张失败都不升级为整体失败**——
  /// 咽掉留日志，hero 自会回落到海报 + 模糊垫底。
  ///
  /// 文件名 = `<filePrefix>_backdrop<n>.jpg` / `<filePrefix>_titlecard.jpg` /
  /// `<filePrefix>_logo.png`（logo 是透明底 PNG，扩展名如实），与海报不同名、
  /// 各自独立可重下。v64 遗留的 `<id>_backdrop.jpg`（无序号）只存在于迁移数据里，
  /// 新刮削不再产生。
  Future<List<ScrapedMediaImage>> _downloadImages({
    required ScrapeCandidate candidate,
    required Directory directory,
    required String filePrefix,
  }) async {
    // 1) 汇集远程 URL 图组。
    TmdbImageSet set = const TmdbImageSet();
    if (candidate.source == ScrapeSource.tmdb && _tmdb != null) {
      try {
        set = await _tmdb.fetchImageSet(
          entryId: candidate.entryId,
          isTv: candidate.type != ScrapeEntryType.movie,
        );
      } on ScrapeNetworkException catch (e, stack) {
        ErrorLogService.instance
            .log('CoverScraperService.collectionImageSet', e, stack);
      }
    }
    if (set.backdropUrls.isEmpty && candidate.backdropUrl != null) {
      // 非 TMDB 源（AniList banner）或 /images 拉挂了：候选自带的单张背景兜底，
      // 与 v64 行为等价。
      set = TmdbImageSet(
        backdropUrls: <String>[candidate.backdropUrl!],
        titleCardUrl: set.titleCardUrl,
        logoUrl: set.logoUrl,
      );
    }
    if (set.isEmpty) return const <ScrapedMediaImage>[];

    // 2) 逐张落盘（单张失败跳过该张，不拖垮其余）。
    final List<ScrapedMediaImage> images = <ScrapedMediaImage>[];
    Future<void> fetch({
      required MediaImageKind kind,
      required int position,
      required String url,
      required String fileName,
    }) async {
      try {
        final String path = await _downloader.downloadImageFile(
          url: url,
          fileName: fileName,
          directory: directory,
        );
        images.add(ScrapedMediaImage(
          kind: kind,
          position: position,
          path: path,
          sourceUrl: url,
        ));
      } catch (e, stack) {
        ErrorLogService.instance.log(
            'CoverScraperService.collectionImage.${kind.dbValue}', e, stack);
      }
    }

    for (int i = 0; i < set.backdropUrls.length; i++) {
      await fetch(
        kind: MediaImageKind.backdrop,
        position: i,
        url: set.backdropUrls[i],
        fileName: '${filePrefix}_backdrop$i.jpg',
      );
    }
    if (set.titleCardUrl != null) {
      await fetch(
        kind: MediaImageKind.titleCard,
        position: 0,
        url: set.titleCardUrl!,
        fileName: '${filePrefix}_titlecard.jpg',
      );
    }
    if (set.logoUrl != null) {
      await fetch(
        kind: MediaImageKind.logo,
        position: 0,
        url: set.logoUrl!,
        fileName: '${filePrefix}_logo.png',
      );
    }
    return images;
  }

  /// 散装电影的附加图组落地 + 落库（v68）。
  ///
  /// 只在 **movie 型候选**时调用（见 [_applyCandidate]）：剧集（tv 型）的横版图
  /// 属于合集容器（[applyCandidateToCollection]），逐集各存一份是 N 倍冗余，且
  /// UI 没有消费单集 backdrop 的槽位。文件落 `video_covers/images/`（GC 免疫子
  /// 目录），行走 `media_images.bookUid` 归属。图组失败不升级为整体失败。
  Future<void> _applyBookImages({
    required String bookUid,
    required ScrapeCandidate candidate,
  }) async {
    final Directory dir = _imagesDirectory ?? await VideoStorage.imagesDir();
    final List<ScrapedMediaImage> images = await _downloadImages(
      candidate: candidate,
      directory: dir,
      filePrefix: p.basenameWithoutExtension(videoCoverFileName(bookUid)),
    );
    if (images.isEmpty) return;
    await _repo.replaceMediaImages(bookUid, images);
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
    _ResolvedMatch resolved, {
    required bool applyHighConfidence,
    required bool requireUniqueExactTitle,
  }) async {
    final MatchDecision? decision = resolved.decision;
    if (decision == null) return const ScrapeNoMatch();
    switch (decision.confidence) {
      case MatchConfidence.high:
        if (!applyHighConfidence) {
          return ScrapeNeedsConfirm(<MatchDecision>[decision]);
        }
        // 无人值守整库重刮：high 只说明综合分够（标题相似度 0.70 + 年份吻合即达
        // 0.85 线），不足以覆盖一张已经存在的封面。近似命中降级成待确认，交给
        // 单卡「在线匹配封面」由用户亲自拍板。
        if (requireUniqueExactTitle && !resolved.uniqueExactTitle) {
          return ScrapeNeedsConfirm(<MatchDecision>[decision]);
        }
        final String coverPath = await _applyCandidate(
          bookUid: book.bookUid,
          candidate: decision.candidate,
          aliasKey: parsed.title,
          origin: CoverOrigin.autoScraped,
        );
        return ScrapeApplied(
          coverPath: coverPath,
          origin: CoverOrigin.autoScraped,
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
  Future<_ResolvedMatch> _resolveBestDecision(ParsedMediaName parsed) async {
    final String normalizedQuery = TitleNormalizer.normalize(parsed.title);
    // 归一化精确命中的**条目身份**集合（source/entryId 去重：同一条目在同一次
    // 搜索里重复出现不算歧义）。只统计本轮真正查过的源——命中 high 提前返回时
    // 后面的源根本没查，也就谈不上「那里还有一个同名条目」。
    final Set<String> exactEntryKeys = <String>{};
    MatchDecision? best;

    MatchDecision? consider(List<ScrapeCandidate> candidates) {
      if (normalizedQuery.isNotEmpty) {
        for (final ScrapeCandidate candidate in candidates) {
          if (_isExactTitle(normalizedQuery, candidate)) {
            exactEntryKeys.add('${candidate.source.name}/${candidate.entryId}');
          }
        }
      }
      final MatchDecision? d =
          MatchScorer.best(parsed: parsed, candidates: candidates);
      if (d == null) return best;
      if (best == null || _isBetter(d, best!)) best = d;
      return best;
    }

    _ResolvedMatch finish() {
      final MatchDecision? decision = best;
      if (decision == null) return _ResolvedMatch.none;
      final bool unique = exactEntryKeys.length == 1 &&
          _isExactTitle(normalizedQuery, decision.candidate);
      return _ResolvedMatch(decision, uniqueExactTitle: unique);
    }

    // 离线库（纯内存，无网络，优先）。
    if (_offline != null) {
      consider(_offline.search(parsed.title));
      if (best?.confidence == MatchConfidence.high) return finish();
    }

    // Bangumi 主源。
    consider(await _bangumi.search(parsed.title));
    if (best?.confidence == MatchConfidence.high) return finish();

    // TMDB 补充源（有 key，或有电影提示时优先补 TMDB）。
    if (_tmdb != null) {
      consider(await _tmdb.search(parsed.title, year: parsed.year));
      if (best?.confidence == MatchConfidence.high) return finish();
    }

    // AniList / Jikan 补充源（零 key，动画向）。仍然逐层兜底而非并发全查：批量刮削
    // 可能是 500 本起步，每本都并发 5 个请求会把 Bangumi/Jikan 的限流直接打爆，而
    // 绝大多数条目在前两层就已命中 high。手动匹配弹窗要的是「一次看全」，那条路走
    // [searchAllSources] 并发——两种代价模型服务两种场景，是有意的分工。
    if (_anilist != null) {
      consider(await _anilist.search(parsed.title, year: parsed.year));
      if (best?.confidence == MatchConfidence.high) return finish();
    }
    if (_jikan != null) {
      consider(await _jikan.search(parsed.title, year: parsed.year));
    }
    return finish();
  }

  /// 候选的标题或任一别名归一化后与 [normalizedQuery] 完全相等。
  static bool _isExactTitle(String normalizedQuery, ScrapeCandidate candidate) {
    if (normalizedQuery.isEmpty) return false;
    if (TitleNormalizer.normalize(candidate.title) == normalizedQuery) {
      return true;
    }
    for (final String alias in candidate.aliases) {
      if (TitleNormalizer.normalize(alias) == normalizedQuery) return true;
    }
    return false;
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

  /// 下载并落地单本封面：下载 → `updateCover` → 记 [origin] 元数据。[aliasKey] 非空时
  /// 顺便记一条别名缓存（自动 high 应用也记住决策，下次重刮同目录直接命中）。返回封面路径。
  ///
  /// [origin] 必须如实反映**这次落盘是谁做的决定**：程序自动匹配传
  /// [CoverOrigin.autoScraped]，用户在弹窗里点「使用」传 [CoverOrigin.userScraped]。
  /// 两者曾经共用一个 `scraped` 标记，正是「全部刮削冲掉手动纠正」的根因
  /// （BUG-1325），所以这里是必填参数、不给默认值。
  Future<String> _applyCandidate({
    required String bookUid,
    required ScrapeCandidate candidate,
    required CoverOrigin origin,
    String? aliasKey,
  }) async {
    final String coverPath = await _downloader.downloadCover(
      url: candidate.posterUrl,
      bookUid: bookUid,
      coversDirectory: _coversDirectory,
    );
    await _repo.updateCover(bookUid, coverPath);
    await _coverMeta.set(
      bookUid,
      CoverMeta(
        origin: origin,
        source: candidate.source,
        entryId: candidate.entryId,
      ),
    );
    await _persistMetadata(
      bookUids: <String>[bookUid],
      candidate: candidate,
    );
    // v68：电影候选顺带拉附加图组（backdrop/logo/titleCard，横版续播卡用）。
    // tv 型跳过——那些图属于合集容器，见 [_applyBookImages]。
    if (candidate.type == ScrapeEntryType.movie) {
      await _applyBookImages(bookUid: bookUid, candidate: candidate);
    }
    if (aliasKey != null && aliasKey.trim().isNotEmpty) {
      await _aliasCache.put(aliasKey, candidate.source, candidate.entryId);
    }
    return coverPath;
  }

  /// 把本地 sidecar 海报文件复制为封面（统一收口 [MediaCoverService.applyCoverFile]：
  /// `.tmp`+rename 原子落到 covers 目录 + 双键驱逐（BUG-1118），文件名走
  /// [videoCoverFileName] 约定，与下载/抽帧同目录同命名）。返回封面绝对路径。
  Future<String> _copySidecarCover(File poster, String bookUid) async {
    final Directory covers = await _coversDir();
    await covers.create(recursive: true);
    final String finalPath = p.join(covers.path, videoCoverFileName(bookUid));
    await MediaCoverService.applyCoverFile(source: poster, destPath: finalPath);
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
