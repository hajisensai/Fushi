/// 书 / 漫画「获取各卷封面与横幅」的编排：匹配系列 → 逐卷选图（清晰度优先）→
/// 下载 → 写入刮削层（[BookArtStore]）→ 结果摘要。
///
/// 源的优先级（所有者拍板「高清优先」）：
/// 1. 追踪映射里已有的 MangaBaka 链接（`manual` / `id` / `suggestion` 直接采用，不再搜索；
///    `auto` 当强候选，结论与它不一致时降为待确认）——刮削不另存一份系列真相；
/// 2. MangaBaka：对全部搜索候选打分（book_art_matcher），过标题 / 种类 / 作者初筛的最多
///    3 个拉 ja 卷封面列表做卷号覆盖率校验；
/// 3. Bangumi：系列条目先排，单行本关联给每卷封面；MangaBaka 拒绝 / 出错 / 某卷缺图
///    或那张不够清晰时用。
///
/// 每卷取面积最大的那张，且要比本地内嵌封面大 1.2 倍、比刮削层里已有的同系列那张大
/// 才写（不降清晰度）；横幅只来自 MangaBaka，本次没拿到时同系列沿用旧横幅。
/// MangaBaka 判待确认时整组待确认（不让 Bangumi 自动采用接管）；Bangumi 补卷要求种类
/// 与 MangaBaka 系列一致。用户钉死的系列记进刮削层，之后重刮沿用；单本移除的贴错封面
/// 记为否决，重刮不再选。
/// 失败不吞：每一项降级（MangaBaka 网络错 / 限流、单卷下载失败、本地更清晰、没有可信
/// 匹配）都进结果摘要。
///
/// 只做本地 `epub_books`（format 为 epub / pdf / manga）；在线漫画与字幕书不做。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/metadata/book_art/bangumi_tankobon.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:fushi_engine/media/metadata/books/book_search_query.dart'
    show BookSearchGranularity, bookSearchQueries, bookSearchSeriesTitle;
import 'package:fushi_engine/media/metadata/image_download.dart'
    show looksLikeImageBytes;
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_client.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/models/content_language.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/metadata/bangumi_api_client.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart'
    show kBookScraperUserAgent;
import 'package:fushi/src/media/sources/book_cover_file_resolver.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一本书的处理结果。
enum BookArtBookOutcome {
  /// 写入了卷封面。
  written,

  /// 本地内嵌封面更清晰（或有封面但量不出尺寸，证明不了更清晰），保留本地。
  localSharper,

  /// 刮削层里已有的同系列那张不比候选差，保留已有的（不重下、不降清晰度）。
  unchanged,

  /// 匹配到了系列，但两个源都没有这一卷。
  noCandidate,

  /// 认不出卷号（不按合集序号兜底）。
  noVolume,

  /// 系列没有可信匹配 / 待确认，没写。
  unmatched,

  /// 下载失败 / 不是图片。
  failed,
}

/// 一本书的计划 / 结果。
class BookArtBookPlan {
  const BookArtBookPlan({
    required this.bookKey,
    required this.title,
    required this.outcome,
    this.volume,
    this.option,
    this.error,
    this.fromOriginalEdition = false,
  });

  final String bookKey;
  final String title;
  final num? volume;
  final BookArtBookOutcome outcome;

  /// 选中的图（written 或 dryRun 时的计划）。
  final BookArtImageOption? option;
  final String? error;

  /// [option] 是原版（日文版）卷封面：非日文版的系列选了「用 MangaBaka 封面」、
  /// 本语言又没有这一卷时才会出现。
  final bool fromOriginalEdition;

  BookArtBookPlan copyWith({BookArtBookOutcome? outcome, String? error}) =>
      BookArtBookPlan(
        bookKey: bookKey,
        title: title,
        volume: volume,
        option: option,
        outcome: outcome ?? this.outcome,
        error: error ?? this.error,
        fromOriginalEdition: fromOriginalEdition,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'bookKey': bookKey,
    'title': title,
    'volume': ?volume,
    'outcome': outcome.name,
    if (option != null) ...<String, Object?>{
      'coverSource': option!.source.wire,
      'coverUrl': option!.url,
      'coverWidth': ?option!.width,
      'coverHeight': ?option!.height,
      if (fromOriginalEdition) 'coverFromOriginalEdition': true,
    },
    'error': ?error,
  };
}

/// 待确认时给用户挑的候选。
class BookArtSeriesOption {
  const BookArtSeriesOption({
    required this.source,
    required this.id,
    required this.title,
    required this.coverage,
    this.url,
    this.reason,
  });

  final BookArtSource source;
  final String id;
  final String title;
  final double coverage;
  final String? url;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.wire,
    'id': id,
    'title': title,
    'coverage': coverage,
    'url': ?url,
  };
}

/// 一个本地系列的计划 / 结果。
class BookArtSeriesPlan {
  const BookArtSeriesPlan({
    required this.seriesKey,
    required this.seriesTitle,
    required this.decision,
    required this.books,
    this.source,
    this.seriesId,
    this.matchedTitle,
    this.seriesUrl,
    this.banner,
    this.reason,
    this.options = const <BookArtSeriesOption>[],
    this.errors = const <String>[],
    this.edition,
    this.originalEditionVolumes = 0,
    this.originalEditionCovers = false,
  });

  /// `parseBookSeriesKey(...).key`。
  final String seriesKey;
  final String seriesTitle;
  final BookArtDecision decision;
  final BookArtSource? source;
  final String? seriesId;
  final String? matchedTitle;
  final String? seriesUrl;
  final BookArtImageOption? banner;
  final String? reason;
  final List<BookArtSeriesOption> options;
  final List<String> errors;
  final List<BookArtBookPlan> books;

  /// 非日文版系列的版本语言（主语言子标签，如 `zh`）；日文版 / 未知为 null。
  final String? edition;

  /// 本版本语言在 MangaBaka 上没有、但原版（日文版）有卷封面的卷数。>0 时结果面板
  /// 让用户在「保留书里的封面」与「用 MangaBaka 封面」之间选（BUG-5287）。
  final int originalEditionVolumes;

  /// 这个系列当前用的是「用 MangaBaka 封面」（本次请求或之前记下的选择）。
  final bool originalEditionCovers;

  /// 封面或横幅有任何一项来自 MangaBaka（结果面板要显示署名）。
  bool get usesMangaBaka =>
      banner?.source == BookArtSource.mangabaka ||
      books.any(
        (BookArtBookPlan b) =>
            b.outcome == BookArtBookOutcome.written &&
            b.option?.source == BookArtSource.mangabaka,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'seriesKey': seriesKey,
    'seriesTitle': seriesTitle,
    'decision': decision.name,
    'source': ?source?.wire,
    'seriesId': ?seriesId,
    'matchedTitle': ?matchedTitle,
    'seriesUrl': ?seriesUrl,
    if (banner != null)
      'banner': <String, Object?>{
        'source': banner!.source.wire,
        'url': banner!.url,
        'width': ?banner!.width,
        'height': ?banner!.height,
      },
    'reason': ?reason,
    if (options.isNotEmpty)
      'options': <Map<String, Object?>>[
        for (final BookArtSeriesOption o in options) o.toJson(),
      ],
    if (errors.isNotEmpty) 'errors': errors,
    'edition': ?edition,
    if (originalEditionVolumes > 0)
      'originalEditionVolumes': originalEditionVolumes,
    if (originalEditionCovers) 'originalEditionCovers': true,
    'books': <Map<String, Object?>>[
      for (final BookArtBookPlan b in books) b.toJson(),
    ],
  };
}

/// 一次运行的结果。`dryRun` 与真写返回同一种结构。
class BookArtRunResult {
  const BookArtRunResult({
    required this.dryRun,
    required this.series,
    required this.snapshots,
    this.mangaBakaRateLimited = false,
  });

  final bool dryRun;
  final List<BookArtSeriesPlan> series;

  /// 真写时每本被改动的书的旧刮削层（撤销用）；dryRun 为空。
  final List<BookArtSnapshot> snapshots;

  /// 本次运行中 MangaBaka 被限流停用（已转 Bangumi）。
  final bool mangaBakaRateLimited;

  int count(BookArtBookOutcome outcome) => series.fold<int>(
    0,
    (int n, BookArtSeriesPlan s) =>
        n + s.books.where((BookArtBookPlan b) => b.outcome == outcome).length,
  );

  bool get usesMangaBaka =>
      series.any((BookArtSeriesPlan s) => s.usesMangaBaka);

  Map<String, Object?> toJson() => <String, Object?>{
    'dryRun': dryRun,
    'mangaBakaRateLimited': mangaBakaRateLimited,
    'usesMangaBaka': usesMangaBaka,
    'counts': <String, int>{
      for (final BookArtBookOutcome o in BookArtBookOutcome.values)
        o.name: count(o),
    },
    'series': <Map<String, Object?>>[
      for (final BookArtSeriesPlan s in series) s.toJson(),
    ],
  };
}

/// 用户在待确认面板 / ops 里钉死的系列（跳过搜索与判定）。
class BookArtSeriesPin {
  const BookArtSeriesPin({required this.source, required this.id});

  final BookArtSource source;
  final String id;
}

/// 结果面板里对单个系列的重跑请求：钉死系列（[pins]）或改「用 MangaBaka 封面」
/// 的选择（[originalEditionCovers]），键都是 [BookArtSeriesPlan.seriesKey]。都为空
/// = 整个合集正常跑一遍。
class BookArtRerun {
  const BookArtRerun({
    this.pins = const <String, BookArtSeriesPin>{},
    this.originalEditionCovers = const <String, bool>{},
  });

  final Map<String, BookArtSeriesPin> pins;
  final Map<String, bool> originalEditionCovers;

  bool get isEmpty => pins.isEmpty && originalEditionCovers.isEmpty;

  /// 这次重跑包含系列 [seriesKey]。
  bool covers(String seriesKey) =>
      pins.containsKey(seriesKey) ||
      originalEditionCovers.containsKey(seriesKey);
}

/// 合集 [collectionId] 里本地书成员的 bookKey（按成员顺序、去重）。
Future<List<String>> collectionMemberBookKeys(
  FushiDatabase db,
  int collectionId,
) async => epubMemberBookKeys(db, await db.getCollectionItems(collectionId));

/// 合集成员行 [rows] 里本地书的 bookKey（按成员顺序、去重）。成员行 entryKey 是
/// 书行 uid（v83；旧行是 bookKey），刮削层按 bookKey 记，经
/// [FushiDatabase.resolveEpubBookKeysForMembers] 换算；不在本机库的成员跳过。
Future<List<String>> epubMemberBookKeys(
  FushiDatabase db,
  Iterable<MediaCollectionItemRow> rows,
) async {
  final List<String> entryKeys = <String>[
    for (final MediaCollectionItemRow r in rows)
      if (r.mediaType == 'epub') r.entryKey,
  ];
  if (entryKeys.isEmpty) return const <String>[];
  final Map<String, String> bookKeyOf = await db.resolveEpubBookKeysForMembers(
    entryKeys,
  );
  return <String>{
    for (final String k in entryKeys)
      if (bookKeyOf[k] case final String bookKey) bookKey,
  }.toList();
}

/// 编排服务。注入 [client] 时不负责关闭它（测试用 MockClient 路由三个 host）。
class BookArtScrapeService {
  BookArtScrapeService({
    required this.database,
    required this.store,
    http.Client? client,
    MangaBakaClient? mangaBaka,
    DateTime Function() now = DateTime.now,
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null,
       _now = now {
    _mangaBaka =
        mangaBaka ??
        MangaBakaClient(client: _client, userAgent: kBookScraperUserAgent);
    _bangumi = BangumiApiClient(
      client: _client,
      userAgent: kBookScraperUserAgent,
    );
  }

  final FushiDatabase database;
  final BookArtStore store;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  late final MangaBakaClient _mangaBaka;
  late final BangumiApiClient _bangumi;

  /// 一次运行内的缓存。
  final Map<String, List<MangaBakaSeries>> _searchCache =
      <String, List<MangaBakaSeries>>{};
  final Map<int, List<MangaBakaImage>> _allVolumeCache =
      <int, List<MangaBakaImage>>{};
  final Map<int, List<MangaBakaImage>> _volumeCache =
      <int, List<MangaBakaImage>>{};

  /// 下载并发上限（图片 CDN 不算 API 配额，但不并发轰炸）。
  static const int downloadConcurrency = 3;

  /// 合集 [collectionId] 里的本地书（`epub` 成员）的 bookKey。
  Future<List<String>> collectionBookKeys(int collectionId) =>
      collectionMemberBookKeys(database, collectionId);

  /// 处理 [bookKeys]：按系列键分组，逐组匹配、选图；[dryRun] 不下载不写。
  /// [pins] 以系列键为键，钉死某组的系列（跳过搜索与判定）；[onlyPinnedGroups] 时只跑
  /// 被钉死的组（待确认面板选了候选后重跑那一组）。没给 pin 的组沿用刮削层里记下的
  /// 用户钉死系列（[BookArtRecord.pinned]），其余只写自动采用档。
  /// [recordUndo] 为 false 时不做撤销快照（界面路径不提供撤销，不留备份文件）。
  Future<BookArtRunResult> run(
    List<String> bookKeys, {
    bool dryRun = false,
    Map<String, BookArtSeriesPin> pins = const <String, BookArtSeriesPin>{},
    Map<String, bool> originalEditionCovers = const <String, bool>{},
    bool onlyPinnedGroups = false,
    bool recordUndo = true,
  }) async {
    final Map<String, List<EpubBookRow>> groups = <String, List<EpubBookRow>>{};
    final Map<String, String> groupTitles = <String, String>{};
    // 同名、不同语言的版本（日文版与台版《化物語》）分成各自的组（BUG-5287，与书籍
    // 归组 BUG-5286 同一判据）：同一系列名带两种以上已知语言时，组键加上语言。
    final List<({EpubBookRow row, BookSeriesKey? series, String base})> found =
        <({EpubBookRow row, BookSeriesKey? series, String base})>[];
    final Map<String, Set<String>> languagesByBase = <String, Set<String>>{};
    for (final String key in bookKeys.toSet()) {
      final EpubBookRow? row = await database.getEpubBook(key);
      if (row == null) continue;
      final BookSeriesKey? series = parseBookSeriesKey(row.title);
      final String base = series?.key ?? row.title;
      found.add((row: row, series: series, base: base));
      final String language = contentLanguageKey(row.language);
      if (language.isNotEmpty) {
        languagesByBase.putIfAbsent(base, () => <String>{}).add(language);
      }
    }
    for (final (:EpubBookRow row, :BookSeriesKey? series, :String base)
        in found) {
      final bool split = (languagesByBase[base]?.length ?? 0) > 1;
      final String groupKey = split
          ? '$base|lang:${contentLanguageKey(row.language)}'
          : base;
      groups.putIfAbsent(groupKey, () => <EpubBookRow>[]).add(row);
      groupTitles.putIfAbsent(groupKey, () => series?.seriesTitle ?? row.title);
    }
    final List<BookArtSeriesPlan> plans = <BookArtSeriesPlan>[];
    final List<BookArtSnapshot> snapshots = <BookArtSnapshot>[];
    for (final MapEntry<String, List<EpubBookRow>> g in groups.entries) {
      if (onlyPinnedGroups &&
          !pins.containsKey(g.key) &&
          !originalEditionCovers.containsKey(g.key)) {
        continue;
      }
      final BookArtSeriesPin? pin = pins[g.key] ?? _storedPin(g.value);
      final BookArtSeriesPlan plan = await _runGroup(
        groupKey: g.key,
        language: _groupLanguage(g.value),
        useOriginalEdition:
            originalEditionCovers[g.key] ?? _storedOriginalEdition(g.value),
        seriesTitle: groupTitles[g.key]!,
        rows: g.value,
        dryRun: dryRun,
        pin: pin,
        snapshots: recordUndo ? snapshots : null,
      );
      plans.add(plan);
    }
    // 换系列 / 换横幅后旧横幅已无人引用：本轮结束统一回收（进行中的别的运行持有的
    // 横幅由 holdBanner 保护）。
    if (!dryRun) await store.collectOrphanBanners();
    return BookArtRunResult(
      dryRun: dryRun,
      series: plans,
      snapshots: snapshots,
      mangaBakaRateLimited: _mangaBaka.isRateLimited,
    );
  }

  /// 一组书共同的主语言子标签（`ja` / `zh`）；不一致或都未知时为 `''`（按日文版处理，
  /// 与修复前相同）。
  static String _groupLanguage(List<EpubBookRow> rows) {
    final Set<String> languages = <String>{
      for (final EpubBookRow r in rows) contentLanguageKey(r.language),
    }..remove('');
    return languages.length == 1 ? languages.single : '';
  }

  /// 这组书之前记下的「用 MangaBaka 封面」选择（任何一本记着就算）。
  bool _storedOriginalEdition(List<EpubBookRow> rows) => rows.any(
    (EpubBookRow r) =>
        store.recordFor(r.bookKey)?.originalEditionCovers ?? false,
  );

  /// 刮削层里这组书记下的用户钉死系列：钉死过的记录都指向同一个系列时沿用它。
  BookArtSeriesPin? _storedPin(List<EpubBookRow> rows) {
    final Set<String> seen = <String>{};
    BookArtSeriesPin? pin;
    for (final EpubBookRow r in rows) {
      final BookArtRecord? record = store.recordFor(r.bookKey);
      if (record == null || !record.pinned || !record.hasSeries) continue;
      final BookArtSource? source = BookArtSource.tryParse(record.source);
      if (source == null) continue;
      if (seen.add('${record.source}:${record.seriesId}')) {
        pin = BookArtSeriesPin(source: source, id: record.seriesId);
      }
    }
    return seen.length == 1 ? pin : null;
  }

  Future<BookArtSeriesPlan> _runGroup({
    required String groupKey,
    required String language,
    required bool useOriginalEdition,
    required String seriesTitle,
    required List<EpubBookRow> rows,
    required bool dryRun,
    required BookArtSeriesPin? pin,
    required List<BookArtSnapshot>? snapshots,
  }) async {
    final List<String> errors = <String>[];
    // 这组书的版本语言：MangaBaka 的卷图与 Bangumi 的单行本都是按版本的，非日文版
    // 只能用同语言的封面，找不到就保留书里的封面（BUG-5287）。
    final String edition = language.isEmpty ? 'ja' : language;
    final bool japaneseEdition = edition == 'ja';
    // 用户按系列选「用 MangaBaka 封面」才回落原版（日文版）卷封面；只对非日文版有意义。
    final bool originalEdition = useOriginalEdition && !japaneseEdition;
    final ({Map<String, num> volumes, bool singleUnnumbered}) resolved =
        resolveLocalVolumes(<String, num?>{
          for (final EpubBookRow r in rows)
            r.bookKey: parseBookSeriesKey(r.title)?.volume,
        });
    final BookArtLocalSeries local = BookArtLocalSeries(
      // 判档与搜索用去掉打头标签 / 卷号的系列名（`[川原礫] ソードアート・オンライン`
      // → `ソードアート・オンライン`），与手动搜索弹窗同一份规则；结果里仍显示原名。
      seriesTitle: bookSearchSeriesTitle(seriesTitle),
      kind: _localKind(rows),
      volumes: resolved.volumes.values.toList(),
      author: rows
          .map((EpubBookRow r) => r.author)
          .firstWhere(
            (String? a) => a != null && a.trim().isNotEmpty,
            orElse: () => null,
          ),
      singleUnnumbered: resolved.singleUnnumbered,
    );
    // 用户钉过的贴错封面（单本移除时记下）：重刮不再选它们。
    final Map<String, Set<String>> rejected = <String, Set<String>>{
      for (final EpubBookRow r in rows)
        r.bookKey: <String>{...?store.recordFor(r.bookKey)?.rejectedCoverUrls},
    };

    // ── MangaBaka ──（钉死 Bangumi 时完全不跑：用户的选择优先于追踪链接）
    _MangaBakaMatch? mb;
    BookArtMatchResult? mbResult;
    bool fixedLink = false;
    if (pin == null || pin.source == BookArtSource.mangabaka) {
      try {
        BookArtSeriesPin? mbPin = pin;
        String? autoId;
        if (mbPin == null) {
          final _Link link = await _trackingLink(rows);
          autoId = link.autoId;
          final String? fixedId = link.fixedId;
          if (fixedId != null) {
            fixedLink = true;
            mbPin = BookArtSeriesPin(
              source: BookArtSource.mangabaka,
              id: fixedId,
            );
          }
        }
        if (mbPin != null) {
          mb = await _mangaBakaPinned(int.tryParse(mbPin.id));
          if (mb == null) {
            errors.add('MangaBaka: series ${mbPin.id} not found');
          }
        } else {
          (mb, mbResult) = await _mangaBakaSearch(local, linkedId: autoId);
        }
      } on MangaBakaException catch (e) {
        errors.add('MangaBaka: ${e.message}');
        ErrorLogService.instance.logDiagnostic('BookArtScrape.mangabaka', '$e');
      }
    }

    // ── Bangumi ──
    List<MangaBakaImage> editionImages =
        mb?.volumeImages ?? const <MangaBakaImage>[];
    if (mb != null && !japaneseEdition) {
      try {
        editionImages = await _allVolumeImages(mb.series.id);
      } on MangaBakaException catch (e) {
        editionImages = const <MangaBakaImage>[];
        errors.add('MangaBaka: ${e.message}');
      }
    }
    final Map<num, BookArtImageOption> mbVolumes = mb == null
        ? const <num, BookArtImageOption>{}
        : <num, BookArtImageOption>{
            for (final MapEntry<num, MangaBakaImage> e
                in pickMangaBakaVolumeImages(
                  editionImages,
                  language: edition,
                ).entries)
              e.key: mangaBakaOption(e.value),
          };
    BookArtImageOption? mbOptionFor(String bookKey, num volume) {
      final BookArtImageOption? o = _lookup(mbVolumes, volume);
      return o == null || rejected[bookKey]!.contains(o.url) ? null : o;
    }

    // 非日文版：原版（日文版）卷封面，只在本语言缺卷时作为可选回落。
    final Map<num, BookArtImageOption> originalVolumes =
        mb == null || japaneseEdition
        ? const <num, BookArtImageOption>{}
        : <num, BookArtImageOption>{
            for (final MapEntry<num, MangaBakaImage> e
                in pickMangaBakaVolumeImages(mb.volumeImages).entries)
              e.key: mangaBakaOption(e.value),
          };
    BookArtImageOption? originalOptionFor(String bookKey, num volume) {
      final BookArtImageOption? o = _lookup(originalVolumes, volume);
      return o == null || rejected[bookKey]!.contains(o.url) ? null : o;
    }

    // Bangumi 的单行本封面都是日文版：非日文版的组不用它补卷。
    final bool bangumiNeeded =
        japaneseEdition &&
        (mb == null ||
            resolved.volumes.entries.any(
              (MapEntry<String, num> e) =>
                  bookArtNeedsBangumiProbe(mbOptionFor(e.key, e.value)),
            ));
    // 钉死 Bangumi：直接取那个条目。钉死 MangaBaka 且查到了：与追踪映射里固定的链接
    // 同口径，Bangumi 只按 MangaBaka 的种类补缺卷（用户钉的系列不会被换掉）；钉的
    // MangaBaka 查不到时不搜 Bangumi（否则会自动换成用户没选的系列）。
    final BookArtSeriesPin? bangumiPin = pin?.source == BookArtSource.bangumi
        ? pin
        : null;
    _BangumiMatch? bgm;
    BookArtMatchResult? bgmResult;
    if ((bangumiNeeded && (pin == null || mb != null)) || bangumiPin != null) {
      try {
        if (bangumiPin != null) {
          bgm = await _bangumiPinned(bangumiPin.id, seriesTitle);
          if (bgm == null) {
            errors.add('Bangumi: subject ${bangumiPin.id} not found');
          }
        } else {
          (bgm, bgmResult) = await _bangumiSearch(
            local,
            assistKind: mb == null ? null : mangaBakaKind(mb.series.type),
          );
        }
      } on BangumiTransportException catch (e) {
        errors.add('Bangumi: ${e.message}');
      } on _BangumiHttpException catch (e) {
        errors.add('Bangumi: ${e.message}');
      }
    }

    // MangaBaka 有不止一个够格的候选（或与追踪链接不一致）：整组交给用户挑，不让
    // Bangumi 的自动采用悄悄接管——更清晰的那个选项必须让用户看得到。
    final bool mbUndecided =
        mb == null && mbResult?.decision == BookArtDecision.needsConfirm;
    if ((mb == null && bgm == null) || mbUndecided) {
      final BookArtMatchResult? confirm = mbUndecided
          ? mbResult
          : <BookArtMatchResult?>[mbResult, bgmResult].firstWhere(
              (BookArtMatchResult? r) =>
                  r?.decision == BookArtDecision.needsConfirm,
              orElse: () => null,
            );
      final BookArtMatchResult? shown = confirm ?? mbResult ?? bgmResult;
      return BookArtSeriesPlan(
        seriesKey: groupKey,
        seriesTitle: seriesTitle,
        decision: confirm != null
            ? BookArtDecision.needsConfirm
            : BookArtDecision.rejected,
        reason: shown?.reason,
        options: <BookArtSeriesOption>[
          ..._options(mbResult, BookArtSource.mangabaka),
          ..._options(bgmResult, BookArtSource.bangumi),
        ],
        errors: errors,
        books: <BookArtBookPlan>[
          for (final EpubBookRow r in rows)
            BookArtBookPlan(
              bookKey: r.bookKey,
              title: r.title,
              volume: resolved.volumes[r.bookKey],
              outcome: BookArtBookOutcome.unmatched,
            ),
        ],
      );
    }

    final BookArtSource source = mb != null
        ? BookArtSource.mangabaka
        : BookArtSource.bangumi;
    final String seriesId = mb != null
        ? '${mb.series.id}'
        : '${bgm!.subject.id}';
    final String matchedTitle = mb?.series.displayTitle ?? bgm!.subject.name;
    final String? seriesUrl =
        mb?.series.canonicalUrl ??
        (bgm == null ? null : 'https://bgm.tv/subject/${bgm.subject.id}');
    final double? score = mb?.score ?? bgm?.score;
    // 用户确认过的系列（钉死 / 追踪映射里固定的链接）：与旧记录不同就是换了系列。
    final bool authoritative = pin != null || fixedLink;
    final bool pinned = pin != null;

    // ── 逐卷选图 ──
    BookArtImageOption? banner;
    if (mb != null) {
      try {
        banner = pickMangaBakaBanner(
          await _mangaBaka.fetchSeriesImages(mb.series.id, type: 'banner'),
        );
      } on MangaBakaException catch (e) {
        errors.add('MangaBaka banner: ${e.message}');
      }
    }
    final Map<num, BookArtImageOption> bgmVolumes = <num, BookArtImageOption>{
      if (japaneseEdition)
        for (final BangumiTankobon t
            in bgm?.tankobons ?? const <BangumiTankobon>[])
          t.volume: BookArtImageOption(
            source: BookArtSource.bangumi,
            url: t.coverUrl,
          ),
    };
    final List<BookArtBookPlan> plans = <BookArtBookPlan>[];
    int originalEditionVolumes = 0;
    for (final EpubBookRow r in rows) {
      final num? volume = resolved.volumes[r.bookKey];
      if (volume == null) {
        plans.add(
          BookArtBookPlan(
            bookKey: r.bookKey,
            title: r.title,
            outcome: BookArtBookOutcome.noVolume,
          ),
        );
        continue;
      }
      final BookArtImageOption? mbOption = mbOptionFor(r.bookKey, volume);
      BookArtImageOption? bgmOption = _lookup(bgmVolumes, volume);
      if (bgmOption != null && rejected[r.bookKey]!.contains(bgmOption.url)) {
        bgmOption = null;
      }
      if (bgmOption != null && bookArtNeedsBangumiProbe(mbOption)) {
        final ({int width, int height})? dims = await _probeDimensions(
          bgmOption.url,
        );
        bgmOption = bgmOption.withSize(dims?.width, dims?.height);
      } else if (mbOption != null) {
        bgmOption = null; // MangaBaka 那张够清晰：不额外量 Bangumi。
      }
      final BookArtRecord? previous = store.recordFor(r.bookKey);
      final _Relation relation = _relation(
        previous,
        source: source,
        seriesId: seriesId,
        authoritative: authoritative,
      );
      // 本语言缺这一卷、原版有：记数给结果面板；用户选了「用 MangaBaka 封面」才用。
      final BookArtImageOption? original = mbOption == null && bgmOption == null
          ? originalOptionFor(r.bookKey, volume)
          : null;
      if (original != null) originalEditionVolumes++;
      final bool fromOriginal = original != null && originalEdition;
      // 已有那张与这次候选不是同一种来源（本语言 / 原版）时不按清晰度保留它：本语言
      // 的封面要换掉原版的，反过来也一样。
      final bool keptComparable =
          relation != _Relation.different &&
          (previous?.coverFromOriginalEdition ?? false) == fromOriginal;
      final ({int? area, bool unmeasured}) localCover = await _localCover(r);
      final BookArtVolumeChoice choice = fromOriginal
          // 用户明确选了原版封面：要的是那张图而不是更清晰的图，不比本地封面。
          ? chooseBookArtVolume(
              mangaBaka: original,
              keptArea: keptComparable ? _scrapedCoverArea(r.bookKey) : null,
            )
          : chooseBookArtVolume(
              mangaBaka: mbOption,
              bangumi: bgmOption,
              localArea: localCover.area,
              localUnmeasured: localCover.unmeasured,
              keptArea: keptComparable ? _scrapedCoverArea(r.bookKey) : null,
            );
      plans.add(
        BookArtBookPlan(
          bookKey: r.bookKey,
          title: r.title,
          volume: volume,
          fromOriginalEdition: fromOriginal,
          option: choice.option,
          outcome: switch (choice.outcome) {
            BookArtVolumeOutcome.write => BookArtBookOutcome.written,
            BookArtVolumeOutcome.localSharper =>
              BookArtBookOutcome.localSharper,
            BookArtVolumeOutcome.noCandidate => BookArtBookOutcome.noCandidate,
            BookArtVolumeOutcome.kept => BookArtBookOutcome.unchanged,
          },
        ),
      );
    }

    if (dryRun) {
      return BookArtSeriesPlan(
        seriesKey: groupKey,
        seriesTitle: seriesTitle,
        decision: BookArtDecision.accepted,
        source: source,
        seriesId: seriesId,
        matchedTitle: matchedTitle,
        seriesUrl: seriesUrl,
        banner: banner,
        errors: errors,
        books: plans,
        edition: japaneseEdition ? null : edition,
        originalEditionVolumes: originalEditionVolumes,
        originalEditionCovers: originalEdition,
      );
    }

    // ── 下载与写入 ──
    String? bannerKey;
    void Function()? releaseBanner;
    final Map<String, BookArtBookPlan> committed = <String, BookArtBookPlan>{};
    try {
      if (banner != null && mb != null) {
        final String key = '${BookArtSource.mangabaka.wire}_${mb.series.id}';
        // 记录要等卷封面下完才落盘：期间持有横幅，别处删除触发的回收不删它。
        releaseBanner = store.holdBanner(key);
        try {
          await store.writeBanner(key, await _download(banner.url));
          bannerKey = key;
        } on _DownloadException catch (e) {
          errors.add('banner: ${e.message}');
          banner = null;
        } on Exception catch (e) {
          // 解码失败（CoverImageInvalidException）/ 写盘失败：只丢横幅，不中断整组。
          errors.add('banner: $e');
          banner = null;
        }
      }
      final _GroupWrite ctx = _GroupWrite(
        source: source,
        seriesId: seriesId,
        matchedTitle: matchedTitle,
        seriesUrl: seriesUrl,
        score: score,
        authoritative: authoritative,
        pinned: pinned,
        bannerKey: bannerKey,
        banner: banner,
        rejected: rejected,
        snapshots: snapshots,
        originalEdition: originalEdition,
      );
      // 每本下完立刻写盘（并发 [downloadConcurrency]），不把整组图攒在内存里。
      await _pool<BookArtBookPlan>(plans, (BookArtBookPlan plan) async {
        committed[plan.bookKey] = await _commit(plan, ctx);
      });
    } finally {
      releaseBanner?.call();
    }
    return BookArtSeriesPlan(
      seriesKey: groupKey,
      seriesTitle: seriesTitle,
      decision: BookArtDecision.accepted,
      source: source,
      seriesId: seriesId,
      matchedTitle: matchedTitle,
      seriesUrl: seriesUrl,
      banner: banner,
      errors: errors,
      edition: japaneseEdition ? null : edition,
      originalEditionVolumes: originalEditionVolumes,
      originalEditionCovers: originalEdition,
      books: <BookArtBookPlan>[
        for (final BookArtBookPlan p in plans) committed[p.bookKey] ?? p,
      ],
    );
  }

  /// 旧记录与本次匹配的关系。
  _Relation _relation(
    BookArtRecord? previous, {
    required BookArtSource source,
    required String seriesId,
    required bool authoritative,
  }) {
    if (previous == null || !previous.hasSeries) return _Relation.none;
    if (previous.source == source.wire && previous.seriesId == seriesId) {
      return _Relation.same;
    }
    // 同一个源换了 id、或用户确认了别的系列：旧图不属于这个系列。跨源的自动匹配
    // （MangaBaka 被限流回落 Bangumi）认不出是不是同一部作品：保留旧图、比清晰度。
    if (authoritative || previous.source == source.wire) {
      return _Relation.different;
    }
    return _Relation.ambiguous;
  }

  /// 刮削层里已有的卷封面面积；没有 / 尺寸未知为 null。
  int? _scrapedCoverArea(String bookKey) {
    if (!store.hasCover(bookKey)) return null;
    final BookArtRecord? r = store.recordFor(bookKey);
    final int w = r?.coverWidth ?? 0;
    final int h = r?.coverHeight ?? 0;
    return w > 0 && h > 0 ? w * h : null;
  }

  /// 一本书的下载 + 写入（含快照）。只在需要改动时写；失败只影响这一本。
  Future<BookArtBookPlan> _commit(BookArtBookPlan plan, _GroupWrite ctx) async {
    final String bookKey = plan.bookKey;
    List<int>? bytes;
    if (plan.outcome == BookArtBookOutcome.written) {
      try {
        bytes = await _download(plan.option!.url);
      } on _DownloadException catch (e) {
        return plan.copyWith(
          outcome: BookArtBookOutcome.failed,
          error: e.message,
        );
      }
    }
    // 刮削期间书被删了：不再写（否则留下永远不会被清理的孤儿文件）。
    if (await database.getEpubBook(bookKey) == null) {
      return plan.outcome == BookArtBookOutcome.written
          ? plan.copyWith(
              outcome: BookArtBookOutcome.failed,
              error: 'book was removed',
            )
          : plan;
    }
    final BookArtRecord? previous = store.recordFor(bookKey);
    final _Relation relation = _relation(
      previous,
      source: ctx.source,
      seriesId: ctx.seriesId,
      authoritative: ctx.authoritative,
    );
    final bool hadCover = store.hasCover(bookKey);
    final bool writesCover = bytes != null;
    // 之前按原版取的卷封面，这次没再选它就删掉、露出书里的封面：改回「保留书里的
    // 封面」，或本语言有了这一卷但不如书里的清晰（本语言那张没写进来，旧的日文版
    // 封面不能接着盖在书上）。
    final bool dropOriginal =
        !plan.fromOriginalEdition &&
        (previous?.coverFromOriginalEdition ?? false);
    final bool removeCover =
        !writesCover &&
        hadCover &&
        (relation == _Relation.different || dropOriginal);
    final bool keepsOldCover = !writesCover && !removeCover && hadCover;
    final bool choiceChanges =
        (previous?.originalEditionCovers ?? false) != ctx.originalEdition;
    // 本次没拿到横幅（CDN 抖动 / 本系列没有）：同一系列沿用旧横幅，不抹掉引用。
    final bool keepOldBanner =
        ctx.bannerKey == null &&
        (relation == _Relation.same || relation == _Relation.ambiguous);
    final String? bannerKey =
        ctx.bannerKey ?? (keepOldBanner ? previous?.bannerKey : null);
    final bool pinChanges =
        ctx.pinned &&
        !(previous != null && previous.pinned && relation == _Relation.same);
    if (!writesCover &&
        !removeCover &&
        bannerKey == previous?.bannerKey &&
        !pinChanges &&
        !choiceChanges) {
      return plan;
    }
    final ({int width, int height})? dims = bytes == null
        ? null
        : bookArtImageDimensions(bytes);
    final BookArtSnapshot? snapshot = ctx.snapshots == null
        ? null
        : await store.snapshot(bookKey);
    try {
      await store.write(
        coverBytes: bytes,
        removeCover: removeCover,
        record: BookArtRecord(
          bookKey: bookKey,
          source: ctx.source.wire,
          seriesId: ctx.seriesId,
          seriesTitle: ctx.matchedTitle,
          seriesUrl: ctx.seriesUrl,
          volume: plan.volume,
          coverSource: writesCover
              ? plan.option!.source.wire
              : keepsOldCover
              ? previous?.coverSource
              : null,
          coverUrl: writesCover
              ? plan.option!.url
              : keepsOldCover
              ? previous?.coverUrl
              : null,
          coverWidth: writesCover
              ? dims?.width ?? plan.option!.width
              : keepsOldCover
              ? previous?.coverWidth
              : null,
          coverHeight: writesCover
              ? dims?.height ?? plan.option!.height
              : keepsOldCover
              ? previous?.coverHeight
              : null,
          bannerKey: bannerKey,
          bannerUrl: ctx.bannerKey != null
              ? ctx.banner?.url
              : keepOldBanner
              ? previous?.bannerUrl
              : null,
          bannerWidth: ctx.bannerKey != null
              ? ctx.banner?.width
              : keepOldBanner
              ? previous?.bannerWidth
              : null,
          bannerHeight: ctx.bannerKey != null
              ? ctx.banner?.height
              : keepOldBanner
              ? previous?.bannerHeight
              : null,
          matchScore: ctx.score,
          scrapedAt: _now().millisecondsSinceEpoch,
          pinned: ctx.pinned,
          rejectedCoverUrls: ctx.rejected[bookKey]!.toList(),
          originalEditionCovers: ctx.originalEdition,
          coverFromOriginalEdition: writesCover
              ? plan.fromOriginalEdition
              : keepsOldCover && (previous?.coverFromOriginalEdition ?? false),
        ),
      );
    } on Exception catch (e) {
      // 写盘被拒（CoverImageInvalidException 等）：这一卷算失败，旧刮削层未动。
      if (snapshot != null) await store.discardSnapshot(snapshot);
      return plan.copyWith(outcome: BookArtBookOutcome.failed, error: '$e');
    }
    if (snapshot != null) ctx.snapshots!.add(snapshot);
    return plan;
  }

  BookArtLocalKind _localKind(List<EpubBookRow> rows) {
    final Set<BookFormat> formats = <BookFormat>{
      for (final EpubBookRow r in rows) BookFormat.parseOrEpub(r.format),
    };
    if (formats.length != 1) return BookArtLocalKind.unknown;
    return switch (formats.single) {
      BookFormat.manga => BookArtLocalKind.manga,
      BookFormat.epub => BookArtLocalKind.text,
      BookFormat.pdf => BookArtLocalKind.unknown,
    };
  }

  /// 追踪映射里的 MangaBaka 链接：用户确认过的（manual / id / suggestion）直接用；
  /// `auto` 只当强候选。同组多本链接不一致时不当 fixed。
  Future<_Link> _trackingLink(List<EpubBookRow> rows) async {
    final MediaTrackingRepository repo = MediaTrackingRepository(database);
    final Set<String> fixed = <String>{};
    final Set<String> auto = <String>{};
    for (final EpubBookRow r in rows) {
      for (final MediaTrackingMappingRow m in await repo.bookMappings(
        r.bookKey,
      )) {
        if (m.provider != BookArtSource.mangabaka.wire) continue;
        if (m.linkSource == 'auto') {
          auto.add('${m.subjectId}');
        } else {
          fixed.add('${m.subjectId}');
        }
      }
    }
    return _Link(
      fixedId: fixed.length == 1 ? fixed.single : null,
      autoId: auto.length == 1 ? auto.single : null,
    );
  }

  Future<MangaBakaSeries?> _followMerged(MangaBakaSeries? series) async {
    MangaBakaSeries? current = series;
    for (int hop = 0; hop < 3 && current != null && current.isMerged; hop++) {
      current = await _mangaBaka.fetchSeries(current.mergedWith!);
    }
    return current;
  }

  Future<List<MangaBakaImage>> _volumeImages(int seriesId) async =>
      _volumeCache[seriesId] ??= await _mangaBaka.fetchSeriesImages(
        seriesId,
        type: 'volume',
        language: 'ja',
      );

  /// 系列 [seriesId] 全部语言的卷封面（非日文版的组按主语言子标签挑，MangaBaka 的
  /// 中文码有 `zh` / `zh-tw` 等多种写法，所以不按单个码请求）。只用于选图：匹配系列时
  /// 的卷号覆盖率校验仍按日文版（[_volumeImages]）。
  Future<List<MangaBakaImage>> _allVolumeImages(int seriesId) async =>
      _allVolumeCache[seriesId] ??= await _mangaBaka.fetchSeriesImages(
        seriesId,
        type: 'volume',
      );

  Future<_MangaBakaMatch?> _mangaBakaPinned(int? id) async {
    if (id == null) return null;
    final MangaBakaSeries? series = await _followMerged(
      await _mangaBaka.fetchSeries(id),
    );
    if (series == null) return null;
    return _MangaBakaMatch(
      series: series,
      volumeImages: await _volumeImages(series.id),
      score: 1,
    );
  }

  Future<(_MangaBakaMatch?, BookArtMatchResult?)> _mangaBakaSearch(
    BookArtLocalSeries local, {
    String? linkedId,
  }) async {
    final Map<String, MangaBakaSeries> byId = <String, MangaBakaSeries>{};
    for (final String q in _queries(local.seriesTitle)) {
      final List<MangaBakaSeries> found = _searchCache[q] ??= await _mangaBaka
          .searchSeries(q);
      for (final MangaBakaSeries s in found) {
        final MangaBakaSeries? live = s.isMerged ? await _followMerged(s) : s;
        if (live != null) byId.putIfAbsent('${live.id}', () => live);
      }
      // 这一个词没有可用结果才试下一个：MangaBaka 是模糊搜索，系列名几乎总有结果，
      // 「有结果」得是标题 / 种类 / 作者都说得过去的候选（判不过的候选决策时也会被
      // 拒），否则带副标题的系列永远走不到主标题那个词。
      if (byId.values.any(
        (MangaBakaSeries s) => assessBookArtCandidate(
          local,
          mangaBakaCandidate(s),
        ).worthVolumeCheck,
      )) {
        break;
      }
    }
    if (linkedId != null && !byId.containsKey(linkedId)) {
      final MangaBakaSeries? linked = await _followMerged(
        await _mangaBaka.fetchSeries(int.parse(linkedId)),
      );
      if (linked != null) byId['${linked.id}'] = linked;
    }
    final List<BookArtCandidate> candidates = <BookArtCandidate>[
      for (final MangaBakaSeries s in byId.values) mangaBakaCandidate(s),
    ];
    final List<BookArtCandidate> shortlist =
        candidates
            .where(
              (BookArtCandidate c) =>
                  assessBookArtCandidate(local, c).worthVolumeCheck,
            )
            .toList()
          ..sort(
            (BookArtCandidate a, BookArtCandidate b) => assessBookArtCandidate(
              local,
              b,
            ).tier.score.compareTo(assessBookArtCandidate(local, a).tier.score),
          );
    final Map<String, Set<num>> indexes = <String, Set<num>>{};
    for (final BookArtCandidate c in shortlist.take(3)) {
      final List<MangaBakaImage> images = await _volumeImages(int.parse(c.id));
      indexes[c.id] = pickMangaBakaVolumeImages(images).keys.toSet();
    }
    final BookArtMatchResult result = decideBookArtMatch(
      local: local,
      candidates: candidates,
      volumeIndexes: indexes,
      linkedId: linkedId,
    );
    if (result.decision != BookArtDecision.accepted) return (null, result);
    final BookArtScoredCandidate best = result.best!;
    final MangaBakaSeries series = byId[best.candidate.id]!;
    return (
      _MangaBakaMatch(
        series: series,
        volumeImages: await _volumeImages(series.id),
        score: best.score,
      ),
      result,
    );
  }

  @visibleForTesting
  static List<String> queriesFor(String seriesTitle) =>
      _queries(bookSearchSeriesTitle(seriesTitle));

  /// 搜索用的查询序列：与手动搜索弹窗同一份 [bookSearchQueries]（去打头标签 / 卷号 →
  /// 混写书名拆中日韩 / 拉丁部分 → 主标题，至多 4 个）。两个源在这里都按**系列**
  /// 粒度搜：MangaBaka 条目本就是系列，Bangumi 这里只认系列条目、各卷封面走它的
  /// 单行本关联（手动弹窗里 Bangumi 是按单卷搜的，粒度不同）。
  static List<String> _queries(String seriesTitle) =>
      bookSearchQueries(seriesTitle, granularity: BookSearchGranularity.series);

  /// Bangumi 匹配。[assistKind] 非 null = MangaBaka 已认定系列（种类为它），这里只补
  /// 缺的卷：候选种类必须与它**一致**（轻小说不补漫画版单行本封面）。
  Future<(_BangumiMatch?, BookArtMatchResult?)> _bangumiSearch(
    BookArtLocalSeries local, {
    BookArtCandidateKind? assistKind,
  }) async {
    // 与 MangaBaka 同一查询序列（[_queries]）：Bangumi 按关键词精确搜，双语书名的
    // 全名常常零结果；这个词没有说得过去的候选才往下试。
    final Map<String, BangumiBookSubject> byId = <String, BangumiBookSubject>{};
    bool answered = false;
    for (final String q in _queries(local.seriesTitle)) {
      final BangumiRawResponse response = await _bangumi.searchSubjects(
        q,
        subjectType: kBangumiSubjectTypeBook,
      );
      if (response.statusCode == 404) continue;
      if (!response.isOk) {
        throw _BangumiHttpException('search HTTP ${response.statusCode}');
      }
      answered = true;
      for (final BangumiBookSubject s in parseBangumiBookSearch(
        response.body,
      )) {
        byId.putIfAbsent('${s.id}', () => s);
      }
      if (byId.values.any(
        (BangumiBookSubject s) =>
            s.isSeries &&
            assessBookArtCandidate(local, s.toCandidate()).worthVolumeCheck,
      )) {
        break;
      }
    }
    // 每个查询都 404（搜索接口不可用）：与原来一样当作没有 Bangumi 结果。
    if (!answered) return (null, null);
    final List<BookArtCandidate> candidates = <BookArtCandidate>[
      for (final BangumiBookSubject s in byId.values) s.toCandidate(),
    ];
    final Map<String, Set<num>> indexes = <String, Set<num>>{};
    final Map<String, List<BangumiTankobon>> tankobons =
        <String, List<BangumiTankobon>>{};
    final List<BookArtCandidate> shortlist = candidates
        .where(
          (BookArtCandidate c) =>
              byId[c.id]!.isSeries &&
              assessBookArtCandidate(local, c).worthVolumeCheck,
        )
        .take(2)
        .toList();
    for (final BookArtCandidate c in shortlist) {
      final BangumiRawResponse rel = await _bangumi.fetchSubjectRelations(c.id);
      if (!rel.isOk) continue;
      final List<BangumiTankobon> vols = parseBangumiTankobons(
        rel.body,
        seriesName: byId[c.id]!.name,
      );
      tankobons[c.id] = vols;
      indexes[c.id] = <num>{for (final BangumiTankobon t in vols) t.volume};
    }
    final BookArtMatchResult result = decideBookArtMatch(
      local: local,
      candidates: candidates,
      volumeIndexes: indexes,
    );
    BookArtScoredCandidate? chosen;
    if (result.decision == BookArtDecision.accepted &&
        (assistKind == null || result.best!.candidate.kind == assistKind)) {
      chosen = result.best;
    } else if (assistKind != null) {
      // 只用来补 MangaBaka 缺的卷：系列已由 MangaBaka 认定，这里要求标题档能自动
      // 采用（有严格同名系列时同名衍生作不算）、种类与 MangaBaka 系列一致、不是成人
      // 向、作者不冲突（ranked 已排除）、至少覆盖一卷。
      for (final BookArtScoredCandidate s in result.ranked) {
        if (s.titleAutoOk &&
            !s.candidate.isAdult &&
            s.candidate.kind == assistKind &&
            s.coverage > 0) {
          chosen = s;
          break;
        }
      }
    }
    if (chosen == null) return (null, result);
    return (
      _BangumiMatch(
        subject: byId[chosen.candidate.id]!,
        tankobons: tankobons[chosen.candidate.id] ?? const <BangumiTankobon>[],
        score: chosen.score,
      ),
      result,
    );
  }

  Future<_BangumiMatch?> _bangumiPinned(String id, String seriesTitle) async {
    final BangumiRawResponse subject = await _bangumi.fetchSubject(id);
    if (subject.statusCode == 404) return null;
    if (!subject.isOk) {
      throw _BangumiHttpException('subject HTTP ${subject.statusCode}');
    }
    final BangumiBookSubject? parsed = parseBangumiBookSearch(
      '{"data":[${subject.body}]}',
    ).firstOrNull;
    if (parsed == null) return null;
    final BangumiRawResponse rel = await _bangumi.fetchSubjectRelations(id);
    if (!rel.isOk) {
      throw _BangumiHttpException('relations HTTP ${rel.statusCode}');
    }
    return _BangumiMatch(
      subject: parsed,
      tankobons: parseBangumiTankobons(rel.body, seriesName: parsed.name),
      score: 1,
    );
  }

  List<BookArtSeriesOption> _options(
    BookArtMatchResult? result,
    BookArtSource source,
  ) => <BookArtSeriesOption>[
    for (final BookArtScoredCandidate s
        in result?.ranked ?? const <BookArtScoredCandidate>[])
      BookArtSeriesOption(
        source: source,
        id: s.candidate.id,
        title: s.candidate.displayTitle,
        coverage: s.coverage,
        url: source == BookArtSource.bangumi
            ? 'https://bgm.tv/subject/${s.candidate.id}'
            : 'https://mangabaka.org/${s.candidate.id}',
        reason: result?.reason,
      ),
  ];

  BookArtImageOption? _lookup(Map<num, BookArtImageOption> map, num volume) {
    for (final MapEntry<num, BookArtImageOption> e in map.entries) {
      if (bookArtHasVolume(<num>[e.key], volume)) return e.value;
    }
    return null;
  }

  /// 本地内嵌封面：没有封面 → `(area: null, unmeasured: false)`；有封面但量不出
  /// 尺寸 → `unmeasured: true`（不能当成「没有封面」去覆盖它）。先读文件头，量不出
  /// 再读整个文件（上限 [kBookArtMaxImageBytes] 的 4 倍）。
  Future<({int? area, bool unmeasured})> _localCover(EpubBookRow row) async {
    // 与书架 / 制卡同一份封面解析（声明的封面优先，大小写不敏感回退）。
    final String? path = resolveBookCoverFilePath(
      extractDir: row.extractDir,
      coverPath: row.coverPath,
    );
    if (path == null) return (area: null, unmeasured: false);
    try {
      final File file = File(path);
      final RandomAccessFile raf = await file.open();
      ({int width, int height})? dims;
      try {
        dims = bookArtImageDimensions(await raf.read(256 * 1024));
      } finally {
        await raf.close();
      }
      if (dims == null && await file.length() <= kBookArtMaxImageBytes * 4) {
        dims = bookArtImageDimensions(await file.readAsBytes());
      }
      if (dims == null) return (area: null, unmeasured: true);
      return (area: dims.width * dims.height, unmeasured: false);
    } on FileSystemException catch (e) {
      ErrorLogService.instance.logDiagnostic('BookArtScrape.localCover', '$e');
      return (area: null, unmeasured: true);
    }
  }

  /// 用 Range 只拉文件头量尺寸（与探针同法）；失败为 null（按「尺寸未知」处理）。
  Future<({int width, int height})?> _probeDimensions(String url) async {
    try {
      final http.Response r = await _client
          .get(
            Uri.parse(url),
            headers: <String, String>{
              'User-Agent': kBookScraperUserAgent,
              'Range': 'bytes=0-131071',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 && r.statusCode != 206) return null;
      return bookArtImageDimensions(r.bodyBytes);
    } on Exception catch (e) {
      ErrorLogService.instance.logDiagnostic('BookArtScrape.probe', '$e');
      return null;
    }
  }

  Future<List<int>> _download(String url) async {
    final http.Response r;
    try {
      r = await _client
          .get(
            Uri.parse(url),
            headers: <String, String>{'User-Agent': kBookScraperUserAgent},
          )
          .timeout(const Duration(seconds: 100));
    } on Exception catch (e) {
      throw _DownloadException('request failed: $e');
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw _DownloadException('HTTP ${r.statusCode}');
    }
    final List<int> bytes = r.bodyBytes;
    if (bytes.length > kBookArtMaxImageBytes) {
      throw const _DownloadException('image too large');
    }
    if (!looksLikeImageBytes(bytes, null) ||
        bookArtImageDimensions(bytes) == null) {
      throw _DownloadException(
        'not a decodable image (${r.headers['content-type'] ?? 'unknown'})',
      );
    }
    return bytes;
  }

  Future<void> _pool<T>(
    Iterable<T> items,
    Future<void> Function(T item) task,
  ) async {
    final Iterator<T> it = items.iterator;
    Future<void> worker() async {
      while (it.moveNext()) {
        await task(it.current);
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < downloadConcurrency; i++) worker(),
    ]);
  }

  void close() {
    _mangaBaka.close();
    _bangumi.close();
    if (_ownsClient) _client.close();
  }
}

class _Link {
  const _Link({this.fixedId, this.autoId});
  final String? fixedId;
  final String? autoId;
}

class _MangaBakaMatch {
  const _MangaBakaMatch({
    required this.series,
    required this.volumeImages,
    required this.score,
  });
  final MangaBakaSeries series;
  final List<MangaBakaImage> volumeImages;
  final double score;
}

class _BangumiMatch {
  const _BangumiMatch({
    required this.subject,
    required this.tankobons,
    required this.score,
  });
  final BangumiBookSubject subject;
  final List<BangumiTankobon> tankobons;
  final double score;
}

/// 旧刮削记录与本次匹配系列的关系。
enum _Relation {
  /// 没有旧记录（或只是否决记录）。
  none,

  /// 同一个源、同一个系列。
  same,

  /// 跨源的自动匹配，认不出是不是同一部作品：保留旧图、比清晰度。
  ambiguous,

  /// 换了系列：旧图 / 旧横幅不属于它。
  different,
}

/// 一组写入共用的上下文。
class _GroupWrite {
  const _GroupWrite({
    required this.source,
    required this.seriesId,
    required this.matchedTitle,
    required this.seriesUrl,
    required this.score,
    required this.authoritative,
    required this.pinned,
    required this.bannerKey,
    required this.banner,
    required this.rejected,
    required this.snapshots,
    required this.originalEdition,
  });

  final BookArtSource source;
  final String seriesId;
  final String matchedTitle;
  final String? seriesUrl;
  final double? score;
  final bool authoritative;
  final bool pinned;
  final String? bannerKey;
  final BookArtImageOption? banner;
  final Map<String, Set<String>> rejected;
  final List<BookArtSnapshot>? snapshots;

  /// 系列当前的「用 MangaBaka 封面」选择（写进每本的记录）。
  final bool originalEdition;
}

class _BangumiHttpException implements Exception {
  const _BangumiHttpException(this.message);
  final String message;
}

class _DownloadException implements Exception {
  const _DownloadException(this.message);
  final String message;
}
