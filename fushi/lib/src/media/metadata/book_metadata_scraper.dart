/// 书籍 / 漫画封面刮削服务（跨媒体统一刮削 P1b）。
///
/// 书族（EPUB / 漫画 / PDF）此前**没有**任何联网封面刮削（只能内嵌封面或手动选图），
/// 本服务复用书籍与 galgame 共用的传输层 [BangumiApiClient]
/// （`filter.type = [1]` 书籍），把「搜书 → 拿封面」这条能力补给书族。动画元数据
/// 刮削不使用 Bangumi。
///
/// 三个源（[BookScrapeSource]）：Bangumi（中文书 / 轻小说 / 漫画条目最全，免 API key）、
/// DLsite（同人 / 商业的音声 ASMR、漫画、小说；有声书最常见的来源）与 MangaBaka（漫画 /
/// 轻小说系列，原图分辨率高、带每卷封面；数据 CC BY-NC-SA 4.0，展示处必须署名）。接口按候选中间
/// 表示 [BookScrapeCandidate] 设计，再接 Google Books / OpenLibrary 只需加一个映射器，
/// 传输/落地/UI 不变。
library;

import 'dart:convert';

import 'package:fushi/src/media/metadata/bangumi_api_client.dart';
import 'package:fushi/src/media/metadata/bangumi_cover_url.dart';
import 'package:fushi_engine/media/metadata/book_art/bangumi_tankobon.dart'
    show seriesFirst;
import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart'
    show pickMangaBakaVolumeImages;
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_client.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:fushi_engine/utils/net/app_user_agent.dart';
import 'package:http/http.dart' as http;

/// 书刮削对外报的 UA（通用产品名，不带任何用户信息）。
final String kBookScraperUserAgent = fushiUserAgent('book-scraper');

/// 书族封面刮削源。
enum BookScrapeSource {
  bangumi('Bangumi'),
  dlsite('DLsite'),
  mangabaka('MangaBaka');

  const BookScrapeSource(this.label);

  /// 品牌名（不进 i18n）。
  final String label;
}

/// 书族库页（书 / 漫画 / 有声书）接 DLsite 时只要这三类作品；游戏归 galgame 库。
const Set<DlsiteWorkCategory> kBookDlsiteCategories = <DlsiteWorkCategory>{
  DlsiteWorkCategory.voice,
  DlsiteWorkCategory.manga,
  DlsiteWorkCategory.novel,
};

/// 书籍刮削领域异常（网络失败 / 非 2xx / JSON 异常）。绝不吞异常，交上层给用户可见提示。
class BookScrapeException implements Exception {
  const BookScrapeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'BookScrapeException: $message'
      : 'BookScrapeException($statusCode): $message';
}

/// 一条可用的书籍刮削候选（搜索层输出）。缺封面的条目对「刮封面」无用，映射时跳过。
class BookScrapeCandidate {
  const BookScrapeCandidate({
    required this.subjectId,
    required this.title,
    required this.coverUrl,
    this.source = BookScrapeSource.bangumi,
    this.originalTitle,
    this.author,
    this.year,
    this.summary,
    this.isAdult = false,
    this.pageUrl,
  });

  /// 源内条目 id：Bangumi subject id（字符串化）/ DLsite 作品编号。
  final String subjectId;

  /// 候选来自哪个源。
  final BookScrapeSource source;

  /// 展示用主标题（优先中文名）。
  final String title;

  /// 封面原图 URL（下载层负责落地）。
  final String coverUrl;

  /// 原名（与主标题不同才留）。
  final String? originalTitle;

  /// 作者（搜索端点通常不返回，多为 null；详情端点或未来源可补）。
  final String? author;

  /// 出版年份（`date` 取前 4 位），解析不出为 null。
  final int? year;

  /// 简介摘要（搜索端点提供时）。
  final String? summary;

  /// 源侧明确标成人向（DLsite 年龄分级 / MangaBaka erotica、pornographic）。
  final bool isAdult;

  /// 源给的条目页（MangaBaka `canonical_url`）；null 时按 id 推。
  final String? pageUrl;

  /// 条目详情页 URL（「查看条目」用）。
  String get detailUrl => switch (source) {
    BookScrapeSource.bangumi => 'https://bgm.tv/subject/$subjectId',
    BookScrapeSource.dlsite =>
      DlsiteWorkId.tryParse(subjectId)?.pageUrl ??
          'https://www.dlsite.com/maniax/work/=/product_id/$subjectId.html',
    BookScrapeSource.mangabaka =>
      pageUrl ?? 'https://mangabaka.org/manga/$subjectId',
  };
}

/// 书籍封面刮削客户端。构造注入 [http.Client]（默认自建），测试用 mock client。
class BookMetadataScraper {
  BookMetadataScraper({
    http.Client? client,
    DlsiteClient? dlsiteClient,
    MangaBakaClient? mangaBakaClient,
  }) : _api = BangumiApiClient(
         client: client,
         userAgent: kBookScraperUserAgent,
       ),
       _dlsite = dlsiteClient ?? DlsiteClient(client: client),
       _ownsDlsite = dlsiteClient == null,
       _mangaBaka =
           mangaBakaClient ??
           MangaBakaClient(client: client, userAgent: kBookScraperUserAgent),
       _ownsMangaBaka = mangaBakaClient == null;

  final BangumiApiClient _api;
  final DlsiteClient _dlsite;
  final bool _ownsDlsite;
  final MangaBakaClient _mangaBaka;
  final bool _ownsMangaBaka;

  /// 按 [keyword] 搜书籍条目，返回带封面的候选（最多 [limit] 条）。
  ///
  /// 网络失败 / 非 2xx（404 = 搜不到，返回空表而非异常）→ 抛 [BookScrapeException]。
  Future<List<BookScrapeCandidate>> search(
    String keyword, {
    int limit = 10,
  }) async {
    final String trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return const <BookScrapeCandidate>[];
    }
    final BangumiRawResponse response;
    try {
      response = await _api.searchSubjects(
        trimmed,
        subjectType: kBangumiSubjectTypeBook,
        limit: limit,
      );
    } on BangumiTransportException catch (e) {
      throw BookScrapeException('Bangumi book search ${e.message}');
    }
    if (response.statusCode == 404) {
      return const <BookScrapeCandidate>[]; // 无命中时 Bangumi 偶尔回 404。
    }
    if (!response.isOk) {
      throw BookScrapeException(
        'Bangumi book search HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return parseBookSearchResponse(response.body);
  }

  /// 按 Bangumi subject id 直取条目并映射为候选（添加/修改 Bangumi 映射：用户在
  /// 弹窗贴 ID/URL 直连，不走关键词搜索）。
  ///
  /// 404（条目不存在/被删）或条目无封面 → null；其余非 2xx / 网络失败 → 抛
  /// [BookScrapeException]。
  Future<BookScrapeCandidate?> fetchById(String subjectId) async {
    final BangumiRawResponse response;
    try {
      response = await _api.fetchSubject(subjectId);
    } on BangumiTransportException catch (e) {
      throw BookScrapeException('Bangumi book subject ${e.message}');
    }
    if (response.statusCode == 404) return null;
    if (!response.isOk) {
      throw BookScrapeException(
        'Bangumi book subject HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return parseBookSubjectResponse(response.body);
  }

  /// 搜 DLsite 的音声 / 漫画 / 小说作品（输入是作品编号时直取该作）。
  ///
  /// suggest 端点不带图：RJ / VJ / BJ 按编号规则推主图 URL，其余（旧 RE）逐条补抓详情拿
  /// 封面；补抓不到封面的条目对「刮封面」无用，跳过。失败抛 [BookScrapeException]。
  Future<List<BookScrapeCandidate>> searchDlsite(
    String keyword, {
    int limit = 10,
  }) async {
    final List<DlsiteSearchCandidate> found;
    try {
      found = await _dlsite.search(
        keyword,
        categories: kBookDlsiteCategories,
        sites: kDlsiteSuggestSitesBooks,
        limit: limit,
      );
    } on DlsiteException catch (e) {
      throw BookScrapeException(
        'DLsite search ${e.message}',
        statusCode: e.statusCode,
      );
    }
    final List<BookScrapeCandidate> out = <BookScrapeCandidate>[];
    for (final DlsiteSearchCandidate c in found) {
      final String? guessed = c.guessedCoverUrl;
      if (guessed != null) {
        out.add(
          BookScrapeCandidate(
            subjectId: c.id.value,
            title: c.title,
            coverUrl: guessed,
            source: BookScrapeSource.dlsite,
            author: c.circle,
            summary: c.description,
            isAdult: c.ageCategory?.isAdult ?? false,
          ),
        );
        continue;
      }
      final BookScrapeCandidate? detailed = await fetchDlsiteById(c.id.value);
      if (detailed != null) out.add(detailed);
    }
    return out;
  }

  /// 按 DLsite 作品编号直取。编号非法 / 查无此作 / 无封面 → null；网络失败抛
  /// [BookScrapeException]。
  Future<BookScrapeCandidate?> fetchDlsiteById(String workId) async {
    final DlsiteWorkId? id = DlsiteWorkId.tryParse(workId);
    if (id == null) return null;
    final DlsiteWork? work;
    try {
      work = await _dlsite.fetchWork(id);
    } on DlsiteException catch (e) {
      throw BookScrapeException(
        'DLsite work ${e.message}',
        statusCode: e.statusCode,
      );
    }
    return work == null ? null : mapDlsiteWork(work);
  }

  /// 搜 MangaBaka 系列（漫画 / 轻小说）。候选封面是系列主封面原图；每卷封面见
  /// [fetchMangaBakaVolumeCovers]。失败抛 [BookScrapeException]。
  Future<List<BookScrapeCandidate>> searchMangaBaka(
    String keyword, {
    int limit = 10,
  }) async {
    final List<MangaBakaSeries> found;
    try {
      found = await _mangaBaka.searchSeries(keyword, limit: limit);
    } on MangaBakaException catch (e) {
      throw BookScrapeException(
        'MangaBaka search ${e.message}',
        statusCode: e.statusCode,
      );
    }
    return <BookScrapeCandidate>[
      for (final MangaBakaSeries s in found) ?mapMangaBakaSeries(s),
    ];
  }

  /// 按 MangaBaka 系列 id 直取（`merged` 的跟到存活系列）。不存在 / 无封面 → null。
  Future<BookScrapeCandidate?> fetchMangaBakaById(String id) async {
    final int? seriesId = int.tryParse(id.trim());
    if (seriesId == null) return null;
    try {
      MangaBakaSeries? series = await _mangaBaka.fetchSeries(seriesId);
      for (int hop = 0; hop < 3 && series != null && series.isMerged; hop++) {
        series = await _mangaBaka.fetchSeries(series.mergedWith!);
      }
      return series == null ? null : mapMangaBakaSeries(series);
    } on MangaBakaException catch (e) {
      throw BookScrapeException(
        'MangaBaka series ${e.message}',
        statusCode: e.statusCode,
      );
    }
  }

  /// MangaBaka 系列 [seriesId] 的日文版每卷封面（每卷一张：常规版、安全分级优先，再比
  /// 面积），按卷号升序。失败抛 [BookScrapeException]。
  Future<List<BookVolumeCover>> fetchMangaBakaVolumeCovers(
    String seriesId,
  ) async {
    final int? id = int.tryParse(seriesId.trim());
    if (id == null) return const <BookVolumeCover>[];
    final List<MangaBakaImage> images;
    try {
      images = await _mangaBaka.fetchSeriesImages(
        id,
        type: 'volume',
        language: 'ja',
      );
    } on MangaBakaException catch (e) {
      throw BookScrapeException(
        'MangaBaka images ${e.message}',
        statusCode: e.statusCode,
      );
    }
    final List<BookVolumeCover> out = <BookVolumeCover>[
      for (final MapEntry<num, MangaBakaImage> e in pickMangaBakaVolumeImages(
        images,
      ).entries)
        BookVolumeCover(
          volume: e.key,
          label: e.value.index,
          url: e.value.raw.url,
          width: e.value.raw.width,
          height: e.value.raw.height,
          thumbnailUrl: e.value.thumbnailUrl,
        ),
    ];
    out.sort(
      (BookVolumeCover a, BookVolumeCover b) => a.volume.compareTo(b.volume),
    );
    return out;
  }

  /// 关闭内部 client（若为默认自建）。
  void close() {
    _api.close();
    if (_ownsDlsite) _dlsite.close();
    if (_ownsMangaBaka) _mangaBaka.close();
  }
}

/// 一卷封面（MangaBaka 每卷封面网格用）。
class BookVolumeCover {
  const BookVolumeCover({
    required this.volume,
    required this.label,
    required this.url,
    this.width,
    this.height,
    this.thumbnailUrl,
  });

  final num volume;

  /// 源站缩略图（网格预览用）；没有时预览退回 [url]。
  final String? thumbnailUrl;

  /// 源站原样的卷序（`"28.5"`）。
  final String label;
  final String url;
  final int? width;
  final int? height;
}

/// 把 MangaBaka 系列映射为书族候选；没有主封面返回 null。
BookScrapeCandidate? mapMangaBakaSeries(MangaBakaSeries series) {
  final String? cover = series.cover?.url;
  if (cover == null) return null;
  final List<String> creators = <String>[
    ...series.authors,
    for (final String a in series.artists)
      if (!series.authors.contains(a)) a,
  ];
  return BookScrapeCandidate(
    subjectId: '${series.id}',
    title: series.displayTitle,
    coverUrl: cover,
    source: BookScrapeSource.mangabaka,
    originalTitle: series.title != series.displayTitle ? series.title : null,
    author: creators.isEmpty ? null : creators.join(', '),
    isAdult: series.isAdult,
    pageUrl: series.canonicalUrl,
  );
}

/// 用户贴的 MangaBaka 系列页 URL（`mangabaka.org/manga/<id>/…`）或纯数字 → 系列 id；
/// 其余 null。
String? parseMangaBakaSeriesId(String input) {
  final String trimmed = input.trim();
  if (RegExp(r'^\d+$').hasMatch(trimmed)) return trimmed;
  final Uri? uri = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'https://$trimmed',
  );
  if (uri == null) return null;
  final String host = uri.host.toLowerCase().replaceFirst('www.', '');
  if (host != 'mangabaka.org' && host != 'mangabaka.dev') return null;
  for (final String segment in uri.pathSegments) {
    if (RegExp(r'^\d+$').hasMatch(segment)) return segment;
  }
  return null;
}

/// 把 DLsite 作品映射为书族候选；无封面返回 null。作者位取作者 > 剧本 > 社团。
BookScrapeCandidate? mapDlsiteWork(DlsiteWork work) {
  final String? cover = work.coverUrl;
  if (cover == null) return null;
  final List<String> creators = work.primaryCreators;
  return BookScrapeCandidate(
    subjectId: work.id.value,
    title: work.title,
    coverUrl: cover,
    source: BookScrapeSource.dlsite,
    author: creators.isEmpty ? null : creators.join(', '),
    year: work.releaseDate?.year,
    summary: work.description,
    isAdult: work.ageCategory?.isAdult ?? false,
  );
}

/// 纯函数：把 Bangumi `/v0/subjects/{id}` **详情**响应体解析为单个候选（id 直连
/// 改绑映射路径用）。详情响应的 images/name/name_cn/date/summary 字段形态与搜索
/// 条目一致，直接复用 [mapBookSubject]；无封面/无标题 → null；JSON 解码失败 →
/// 抛 [BookScrapeException]。
BookScrapeCandidate? parseBookSubjectResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw BookScrapeException('Bangumi book subject JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) return null;
  return mapBookSubject(decoded);
}

/// 纯函数：把 Bangumi `/v0/search/subjects`（书籍）响应体解析为候选列表。
///
/// 抽为顶层纯函数便于单测。结构异常 / 无 data 数组当作**空结果**（搜不到是正常情况），
/// 只有 JSON 解码失败才抛 [BookScrapeException]。
List<BookScrapeCandidate> parseBookSearchResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (e) {
    throw BookScrapeException('Bangumi book JSON decode failed: $e');
  }
  if (decoded is! Map<String, Object?>) {
    return const <BookScrapeCandidate>[];
  }
  final Object? data = decoded['data'];
  if (data is! List<Object?>) {
    return const <BookScrapeCandidate>[];
  }
  final List<BookScrapeCandidate> out = <BookScrapeCandidate>[];
  // 系列条目（`series: true`）排前：否则搜「涼宮ハルヒ」会先给单卷条目，选它只拿到
  // 一卷的封面（行为变化：候选顺序与旧版不同，组内仍保持源站顺序）。
  for (final Object? item in seriesFirst<Object?>(
    data,
    (Object? i) => i is Map && i['series'] == true,
  )) {
    if (item is! Map<String, Object?>) continue;
    final BookScrapeCandidate? candidate = mapBookSubject(item);
    if (candidate != null) out.add(candidate);
  }
  return out;
}

/// 把单个 Bangumi 书籍 subject 映射为候选；缺封面返回 null。
BookScrapeCandidate? mapBookSubject(Map<String, Object?> subject) {
  final String? coverUrl = bangumiOriginalCoverUrl(subject);
  if (coverUrl == null) return null; // 无封面的条目对「刮封面」无用，跳过。

  final String? nameCn = _nonEmptyString(subject['name_cn']);
  final String? name = _nonEmptyString(subject['name']);
  final String? title = nameCn ?? name;
  if (title == null) return null;
  final String? originalTitle = (name != null && name != title) ? name : null;

  final String? id = _nonEmptyString(subject['id']?.toString());
  if (id == null) return null; // 没 id 无法定位条目详情页。

  return BookScrapeCandidate(
    subjectId: id,
    title: title,
    coverUrl: coverUrl,
    originalTitle: originalTitle,
    year: _yearFromDate(_nonEmptyString(subject['date'])),
    summary: _nonEmptyString(subject['summary']),
  );
}

/// 从 `YYYY-MM-DD` 取年份，非法返回 null。
int? _yearFromDate(String? date) {
  if (date == null || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}

/// 取非空去空白字符串，空/非 String 返回 null。
String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
