/// DLsite（同人 / 商业作品商店）元数据协议层。
///
/// DLsite **没有官方公开 API**，这里用的是站点前端自己在调的三个 JSON 端点（2026-10 实测）：
///
/// - `/<站>/api/=/product.json?workno=<编号>&locale=<区域>`：作品全量数据（标题、社团、
///   作品类型、发售日、年龄分级、标签、创作者、封面）。查无此作返回 `[]`（HTTP 200）。
/// - `/<站>/product/info/ajax?product_id=<编号>`：评分 / 评价数 / 下载数（product.json 不带）。
/// - `/suggest/?term=<关键词>&site=adult-jp`：按名搜作品，返回 `{work: [...]}`。
///
/// 端点是非官方的、随时可能改：解析一律容错（字段缺失 / 类型不对 → 该字段为空，不崩），
/// 但**整体结构不对**（不是数组 / 不是对象）抛 [DlsiteException]，不吞成「查无此作」。
///
/// 本文件只做协议与解析；各媒体域（galgame / 书 / 有声书 / 漫画）把 [DlsiteWork] 映射成
/// 自己的元数据草稿，平台无关，app 与无头服务端共用。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:fushi_engine/utils/net/app_http.dart';

/// DLsite 请求失败（网络 / 非 2xx / 响应结构不对）。查无此作**不是**异常，返回 null。
class DlsiteException implements Exception {
  const DlsiteException(this.message, {this.statusCode});

  /// 技术描述（英文，UI 层套 i18n 外壳）。
  final String message;

  /// 非 2xx 时的 HTTP 状态码。
  final int? statusCode;

  @override
  String toString() {
    final String suffix = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'DlsiteException: $message$suffix';
  }
}

/// 作品编号前缀 → 所属分站。分站决定 API 路径（`/maniax/` / `/pro/` / `/books/`）。
enum DlsiteSite {
  /// 同人（RJ / RE）。全年龄的 `home`、女性向 `girls` 等同人分站的作品在 `maniax` 路径下也能查到。
  maniax('maniax'),

  /// 商业游戏 / 商业作品（VJ）。
  pro('pro'),

  /// 电子书 / 商业漫画（BJ）。
  books('books');

  const DlsiteSite(this.pathSegment);

  /// API 路径段。
  final String pathSegment;
}

/// 规范化后的 DLsite 作品编号（大写前缀 + 6 或 8 位数字，如 `RJ01014447`）。
class DlsiteWorkId {
  const DlsiteWorkId._(this.value, this.site);

  /// 规范化编号字符串。
  final String value;

  /// 所属分站。
  final DlsiteSite site;

  /// 作品页外链（详情页「打开源站」）。
  String get pageUrl =>
      'https://www.dlsite.com/${site.pathSegment}/work/=/product_id/$value.html';

  static const Map<String, DlsiteSite> _sites = <String, DlsiteSite>{
    'RJ': DlsiteSite.maniax,
    'RE': DlsiteSite.maniax,
    'VJ': DlsiteSite.pro,
    'BJ': DlsiteSite.books,
  };

  /// 整串严格解析：只认「前缀 + 6/8 位数字」本身（容忍首尾空白与小写），其余返回 null。
  static DlsiteWorkId? tryParse(String raw) {
    final RegExpMatch? m = _exact.firstMatch(raw.trim());
    if (m == null) return null;
    return _build(m.group(1)!, m.group(2)!);
  }

  /// 从一段任意文本（文件夹名 / 文件名 / 标题）里找第一个作品编号。DLsite 的下载包
  /// 基本都以编号命名（`RJ01014447`、`[RJ299717] 标题`），导入时据此直接按编号取数据。
  ///
  /// 编号两侧不能紧挨字母数字：`XRJ123456` / `RJ1234567`（7 位）都不算。
  static DlsiteWorkId? findIn(String text) {
    final RegExpMatch? m = _embedded.firstMatch(text);
    if (m == null) return null;
    return _build(m.group(1)!, m.group(2)!);
  }

  static DlsiteWorkId? _build(String prefix, String digits) {
    final String upper = prefix.toUpperCase();
    final DlsiteSite? site = _sites[upper];
    if (site == null) return null;
    return DlsiteWorkId._('$upper$digits', site);
  }

  static final RegExp _exact = RegExp(
    r'^(RJ|RE|VJ|BJ)(\d{8}|\d{6})$',
    caseSensitive: false,
  );
  static final RegExp _embedded = RegExp(
    r'(?<![A-Za-z0-9])(RJ|RE|VJ|BJ)(\d{8}|\d{6})(?![0-9])',
    caseSensitive: false,
  );

  @override
  bool operator ==(Object other) =>
      other is DlsiteWorkId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// 年龄分级（`age_category`：1 全年龄 / 2 R-15 / 3 成人向）。
enum DlsiteAgeCategory {
  general,
  r15,
  adult;

  /// 未知值返回 null（不猜）。
  static DlsiteAgeCategory? fromCode(Object? code) {
    final int? n = _asInt(code);
    return switch (n) {
      1 => DlsiteAgeCategory.general,
      2 => DlsiteAgeCategory.r15,
      3 => DlsiteAgeCategory.adult,
      _ => null,
    };
  }

  /// 是否应标 NSFW（R-15 不算，只有成人向算）。
  bool get isAdult => this == DlsiteAgeCategory.adult;
}

/// 作品类型大类：各媒体域据此决定「这条候选归不归我」。
enum DlsiteWorkCategory {
  /// 音声 / ASMR / 音乐（`SOU` / `MUS`）——对应有声书。
  voice,

  /// 游戏（`ACN` `ADV` `RPG` `SLN` `DNV` …）——对应 galgame 库。
  game,

  /// 漫画 / 剧画 / 条漫 / CG 集（`MNG` `SCM` `WBT` `ICG`）。
  manga,

  /// 小说（`NRE`）。
  novel,

  /// 视频 / 工具 / 素材等，不接入任何库。
  other;

  /// 按 DLsite 作品类型代码归类；未知代码归 [other]。
  static DlsiteWorkCategory fromWorkType(String? code) {
    final String c = (code ?? '').trim().toUpperCase();
    if (_voice.contains(c)) return DlsiteWorkCategory.voice;
    if (_game.contains(c)) return DlsiteWorkCategory.game;
    if (_manga.contains(c)) return DlsiteWorkCategory.manga;
    if (_novel.contains(c)) return DlsiteWorkCategory.novel;
    return DlsiteWorkCategory.other;
  }

  static const Set<String> _voice = <String>{'SOU', 'MUS'};
  static const Set<String> _game = <String>{
    'ACN', 'QIZ', 'ADV', 'RPG', 'TBL', 'DNV', 'SLN', 'TYP', 'STG', 'PZL', //
    'ETC',
  };
  static const Set<String> _manga = <String>{'MNG', 'SCM', 'WBT', 'ICG'};
  static const Set<String> _novel = <String>{'NRE'};
}

/// 一部作品的完整元数据（product.json 一条 + 可选的评分）。
class DlsiteWork {
  const DlsiteWork({
    required this.id,
    required this.title,
    this.titleKana,
    this.seriesName,
    this.circle,
    this.workType,
    this.workTypeLabel,
    this.releaseDate,
    this.ageCategory,
    this.genres = const <String>[],
    this.voiceActors = const <String>[],
    this.authors = const <String>[],
    this.scenarioWriters = const <String>[],
    this.illustrators = const <String>[],
    this.musicians = const <String>[],
    this.description,
    this.coverUrl,
    this.rating,
  });

  final DlsiteWorkId id;
  final String title;

  /// 标题读音（片假名）。
  final String? titleKana;

  /// 系列名（`title_name`，缺省回退 `series_name`）。
  final String? seriesName;

  /// 社团 / 品牌（`maker_name`）。
  final String? circle;

  /// 作品类型代码（`SOU` / `ADV` …）。
  final String? workType;

  /// 作品类型展示名（随请求 locale）。
  final String? workTypeLabel;

  final DateTime? releaseDate;
  final DlsiteAgeCategory? ageCategory;

  /// 标签（随请求 locale 翻译）。
  final List<String> genres;

  /// 声优（`voice_by`）。
  final List<String> voiceActors;

  /// 作者（`created_by`）。
  final List<String> authors;

  /// 剧本（`scenario_by`）。
  final List<String> scenarioWriters;

  /// 插画（`illust_by`）。
  final List<String> illustrators;

  /// 音乐（`music_by`）。
  final List<String> musicians;

  /// 简介（`intro_s`，纯文本）。
  final String? description;

  /// 主图绝对 URL（https）。
  final String? coverUrl;

  /// 评分；只在调用方要求时另抓 ajax 端点，null = 没抓或没有。
  final DlsiteRating? rating;

  DlsiteWorkCategory get category => DlsiteWorkCategory.fromWorkType(workType);

  /// 「作者」视角的人名：作者 > 剧本 > 社团。书架只有一个作者位时用它。
  List<String> get primaryCreators {
    if (authors.isNotEmpty) return authors;
    if (scenarioWriters.isNotEmpty) return scenarioWriters;
    final String? c = circle;
    return c == null ? const <String>[] : <String>[c];
  }

  DlsiteWork withRating(DlsiteRating? value) => DlsiteWork(
    id: id,
    title: title,
    titleKana: titleKana,
    seriesName: seriesName,
    circle: circle,
    workType: workType,
    workTypeLabel: workTypeLabel,
    releaseDate: releaseDate,
    ageCategory: ageCategory,
    genres: genres,
    voiceActors: voiceActors,
    authors: authors,
    scenarioWriters: scenarioWriters,
    illustrators: illustrators,
    musicians: musicians,
    description: description,
    coverUrl: coverUrl,
    rating: value,
  );
}

/// 评分（ajax 端点）。
class DlsiteRating {
  const DlsiteRating({this.average, this.count, this.downloads});

  /// 平均分，满分 5（`rate_average_2dp`）。
  final double? average;

  /// 评分人数。
  final int? count;

  /// 销量（下载数）。
  final int? downloads;

  /// 归一到 0-10（与 galgame 评分列同口径）。
  double? get scoreOutOfTen => average == null ? null : average! * 2;
}

/// 搜索候选（suggest 端点，只有轻量字段）。
class DlsiteSearchCandidate {
  const DlsiteSearchCandidate({
    required this.id,
    required this.title,
    this.circle,
    this.workType,
    this.ageCategory,
    this.description,
  });

  final DlsiteWorkId id;
  final String title;
  final String? circle;
  final String? workType;
  final DlsiteAgeCategory? ageCategory;
  final String? description;

  DlsiteWorkCategory get category => DlsiteWorkCategory.fromWorkType(workType);

  /// 主图 URL：suggest 不带图，但主图路径由编号确定（与 product.json 的 `image_main.url`
  /// 同规则：编号向上取整到千的目录）。RJ / VJ / BJ 适用，旧 RE 返回 null。
  String? get guessedCoverUrl => dlsiteGuessCoverUrl(id);
}

/// 按编号推主图 URL：`<目录>/<前缀><编号向上取整到千>/<编号>_img_main.jpg`，同人 `RJ` 的
/// 目录是 `doujin`、商业 `VJ` 是 `professional`、电子书 `BJ` 是 `books`（2026-10 对照
/// product.json 的 `image_main.url` 实测）。旧 `RE` 规则未核实，返回 null 交给详情抓取。
String? dlsiteGuessCoverUrl(DlsiteWorkId id) {
  final String prefix = id.value.substring(0, 2);
  final String? dir = switch (prefix) {
    'RJ' => 'doujin',
    'VJ' => 'professional',
    'BJ' => 'books',
    _ => null,
  };
  if (dir == null) return null;
  final String digits = id.value.substring(2);
  final int n = int.parse(digits);
  final int bucket = ((n + 999) ~/ 1000) * 1000;
  final String bucketDigits = bucket.toString().padLeft(digits.length, '0');
  return 'https://img.dlsite.jp/modpub/images2/work/$dir/'
      '$prefix$bucketDigits/${id.value}_img_main.jpg';
}

/// 解析 product.json 响应体。查无此作（`[]`）返回 null；结构不对抛 [DlsiteException]。
DlsiteWork? parseDlsiteProductJson(String body, DlsiteWorkId requested) {
  final Object? decoded = _decode(body);
  if (decoded is! List) {
    throw const DlsiteException('product.json: expected a JSON array');
  }
  for (final Object? item in decoded) {
    if (item is! Map) continue;
    final Map<String, Object?> m = item.cast<String, Object?>();
    final String? workno = _str(m['workno']);
    // 端点理论上只回请求的那一条；按编号核对，防止回错条目被当成本作。
    if (workno != null && workno.toUpperCase() != requested.value) continue;
    final String? title = _str(m['work_name']);
    if (title == null) continue;
    final Map<String, Object?> creators = m['creaters'] is Map
        ? (m['creaters']! as Map).cast<String, Object?>()
        : const <String, Object?>{};
    return DlsiteWork(
      id: requested,
      title: title,
      titleKana: _str(m['work_name_kana']),
      seriesName: _str(m['title_name']) ?? _str(m['series_name']),
      circle: _str(m['maker_name']),
      workType: _str(m['work_type']),
      workTypeLabel: _str(m['work_type_string']),
      releaseDate: _date(m['regist_date']),
      ageCategory: DlsiteAgeCategory.fromCode(m['age_category']),
      genres: _names(m['genres']),
      voiceActors: _names(creators['voice_by']),
      // 同人作者在 creaters.created_by；商业书 / 漫画（BJ）的作者在独立的 author 数组。
      authors: _names(creators['created_by']).isNotEmpty
          ? _names(creators['created_by'])
          : _authorNames(m['author']),
      scenarioWriters: _names(creators['scenario_by']),
      illustrators: _names(creators['illust_by']),
      musicians: _names(creators['music_by']),
      description: _str(m['intro_s']),
      coverUrl: _absoluteUrl(
        m['image_main'] is Map ? (m['image_main']! as Map)['url'] : null,
      ),
    );
  }
  return null;
}

/// 解析 ajax 评分端点（`{<编号>: {...}}`）。没有该编号返回 null。
DlsiteRating? parseDlsiteRatingJson(String body, DlsiteWorkId id) {
  final Object? decoded = _decode(body);
  if (decoded is! Map) {
    // 查无此作时端点回 `[]`。
    if (decoded is List) return null;
    throw const DlsiteException('product info: expected a JSON object');
  }
  final Object? entry = decoded[id.value];
  if (entry is! Map) return null;
  final double? average =
      _double(entry['rate_average_2dp']) ?? _double(entry['rate_average']);
  final int? count = _asInt(entry['rate_count']);
  final int? downloads = _asInt(entry['dl_count']);
  if (average == null && count == null && downloads == null) return null;
  return DlsiteRating(average: average, count: count, downloads: downloads);
}

/// 解析 suggest 端点。
List<DlsiteSearchCandidate> parseDlsiteSuggestJson(String body) {
  final Object? decoded = _decode(body);
  if (decoded is! Map) {
    throw const DlsiteException('suggest: expected a JSON object');
  }
  final Object? works = decoded['work'];
  if (works == null) return const <DlsiteSearchCandidate>[];
  if (works is! List) {
    throw const DlsiteException('suggest: "work" is not an array');
  }
  final List<DlsiteSearchCandidate> out = <DlsiteSearchCandidate>[];
  final Set<String> seen = <String>{};
  for (final Object? item in works) {
    if (item is! Map) continue;
    final DlsiteWorkId? id = DlsiteWorkId.tryParse(_str(item['workno']) ?? '');
    final String? title = _str(item['work_name']);
    if (id == null || title == null || !seen.add(id.value)) continue;
    out.add(
      DlsiteSearchCandidate(
        id: id,
        title: title,
        circle: _str(item['maker_name']),
        workType: _str(item['work_type']),
        ageCategory: DlsiteAgeCategory.fromCode(item['age_category']),
        description: _str(item['intro_s']),
      ),
    );
  }
  return out;
}

/// suggest 默认检索面：同人（含全年龄）+ 商业游戏。
const List<String> kDlsiteSuggestSitesDefault = <String>['adult-jp'];

/// 书族（书 / 漫画 / 有声书）的检索面：再加上全年龄商业漫画 / 电子书。
const List<String> kDlsiteSuggestSitesBooks = <String>['adult-jp', 'comic'];

/// 同 host 两次请求开始之间的最小间隔（非官方端点，节制一点）。
const Duration kDlsiteMinRequestInterval = Duration(milliseconds: 700);

/// 单次请求的整体超时。
const Duration kDlsiteRequestTimeout = Duration(seconds: 20);

/// DLsite HTTP 客户端。[client] 可注入（测试传 MockClient）；默认走应用代理出口。
class DlsiteClient {
  DlsiteClient({
    http.Client? client,
    this.locale = 'ja_JP',
    this.baseUrl = 'https://www.dlsite.com',
    this.minRequestInterval = kDlsiteMinRequestInterval,
    this.requestTimeout = kDlsiteRequestTimeout,
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// 请求区域（`ja_JP` / `zh_CN` / `zh_TW` / `en_US` / `ko_KR`）：影响标签与类型名的语言，
  /// 作品标题始终是原文。
  final String locale;

  final String baseUrl;
  final Duration minRequestInterval;
  final Duration requestTimeout;

  /// 所有实例共用的「最近一个已占下的请求开始时刻」（同一站点，节奏跨实例）。
  ///
  /// 只存时刻不存 Future：完成态 Future 记住创建 zone，
  /// fake-async 测试里会挂死——所以**不能**用一条静态的 Future 队列尾巴去跨实例
  /// 排队。跨实例的串行靠 [_reserveSlot] 在同一个同步段里「先占坑、再等」。
  static DateTime? _lastRequestStart;

  static const Map<String, String> _headers = <String, String>{
    'Accept': 'application/json',
    'User-Agent': 'fushi/dlsite-metadata (https://github.com/hajisensai/fushi)',
  };

  /// 按编号抓作品；[withRating] 为 true 时多打一次评分端点（失败不影响主数据）。
  /// 查无此作返回 null。
  Future<DlsiteWork?> fetchWork(
    DlsiteWorkId id, {
    bool withRating = false,
  }) async {
    final Uri uri =
        Uri.parse('$baseUrl/${id.site.pathSegment}/api/=/product.json').replace(
          queryParameters: <String, String>{
            'workno': id.value,
            'locale': locale,
          },
        );
    final DlsiteWork? work = parseDlsiteProductJson(await _get(uri), id);
    if (work == null || !withRating) return work;
    return work.withRating(await fetchRating(id));
  }

  /// 抓评分 / 销量。查无此作返回 null。
  Future<DlsiteRating?> fetchRating(DlsiteWorkId id) async {
    final Uri uri = Uri.parse(
      '$baseUrl/${id.site.pathSegment}/product/info/ajax',
    ).replace(queryParameters: <String, String>{'product_id': id.value});
    return parseDlsiteRatingJson(await _get(uri), id);
  }

  /// 按名搜作品。[categories] 非空时只留这些大类（如 galgame 只要 [DlsiteWorkCategory.game]）。
  /// 输入本身就是作品编号时直接返回该编号的候选（标题取详情）。
  ///
  /// [sites] 是 suggest 的检索面，按序查、按编号去重：`adult-jp` 覆盖同人（含全年龄）与
  /// 商业游戏，但**不含**全年龄商业漫画 / 电子书（BJ），那些只在 `comic` 下（2026-10 实测）。
  Future<List<DlsiteSearchCandidate>> search(
    String query, {
    Set<DlsiteWorkCategory> categories = const <DlsiteWorkCategory>{},
    List<String> sites = kDlsiteSuggestSitesDefault,
    int limit = 20,
  }) async {
    final String term = query.trim();
    if (term.isEmpty) return const <DlsiteSearchCandidate>[];
    final DlsiteWorkId? direct = DlsiteWorkId.tryParse(term);
    if (direct != null) {
      final DlsiteWork? work = await fetchWork(direct);
      if (work == null) return const <DlsiteSearchCandidate>[];
      final DlsiteSearchCandidate c = DlsiteSearchCandidate(
        id: work.id,
        title: work.title,
        circle: work.circle,
        workType: work.workType,
        ageCategory: work.ageCategory,
        description: work.description,
      );
      return _keep(c, categories) ? <DlsiteSearchCandidate>[c] : const [];
    }
    final List<DlsiteSearchCandidate> out = <DlsiteSearchCandidate>[];
    final Set<DlsiteWorkId> seen = <DlsiteWorkId>{};
    for (final String site in sites) {
      final Uri uri = Uri.parse('$baseUrl/suggest/').replace(
        queryParameters: <String, String>{
          'term': term,
          'site': site,
          'time': '${DateTime.now().millisecondsSinceEpoch}',
        },
      );
      for (final DlsiteSearchCandidate c in parseDlsiteSuggestJson(
        await _get(uri),
      )) {
        if (_keep(c, categories) && seen.add(c.id)) out.add(c);
      }
    }
    return out.take(limit).toList(growable: false);
  }

  static bool _keep(
    DlsiteSearchCandidate c,
    Set<DlsiteWorkCategory> categories,
  ) => categories.isEmpty || categories.contains(c.category);

  Future<String> _get(Uri uri) async {
    await _reserveSlot();
    final http.Response res;
    try {
      res = await _client.get(uri, headers: _headers).timeout(requestTimeout);
    } on TimeoutException {
      throw DlsiteException('request timed out: ${uri.path}');
    } on http.ClientException catch (e) {
      throw DlsiteException('network error: ${e.message}');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DlsiteException(
        'unexpected status for ${uri.path}',
        statusCode: res.statusCode,
      );
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  /// 排到下一个允许发请求的时刻再返回；并发调用（含**不同实例**）按到达顺序
  /// 依次顺延 [minRequestInterval]。
  ///
  /// **先占坑、再等**：读 [_lastRequestStart]、算出自己的开始时刻、写回，三步在
  /// 同一个同步段里完成（Dart 单线程，无 await 即不可打断），第二个并发调用看到
  /// 的已是第一个占掉的那一格，自己顺延一格。旧实现是「读 last → 睡 → 写 last」，
  /// 排队尾巴又是实例字段：两个实例并发时同时读到同一个 last、睡到同一时刻、一起
  /// 发出，700ms 间隔形同虚设。
  Future<void> _reserveSlot() async {
    // 不限速的实例（测试注入 zero）既不等也不占坑：它不该被别的实例的节奏拖住，
    // 也不该把共享时刻改回「现在」、让限速实例的预约失效。
    if (minRequestInterval <= Duration.zero) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastRequestStart;
    final DateTime start =
        (last == null || now.difference(last) >= minRequestInterval)
        ? now
        : last.add(minRequestInterval);
    _lastRequestStart = start;
    final Duration wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// 测试用：清空跨实例共享的节奏状态，避免用例之间互相顺延。
  @visibleForTesting
  static void resetRateLimitForTesting() => _lastRequestStart = null;

  /// 释放默认 HTTP client（注入的 client 由调用方管理）。
  void close() {
    if (_ownsClient) _client.close();
  }
}

Object? _decode(String body) {
  try {
    return jsonDecode(body.trim());
  } on FormatException catch (e) {
    throw DlsiteException('malformed JSON: ${e.message}');
  }
}

String? _str(Object? v) {
  if (v is! String) return null;
  final String t = v.trim();
  return t.isEmpty ? null : t;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _double(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

/// `2023-01-16 00:00:00` → 本地日期（只取年月日，时区无意义）。
DateTime? _date(Object? v) {
  final String? s = _str(v);
  if (s == null || s.length < 10) return null;
  final DateTime? d = DateTime.tryParse(s.substring(0, 10));
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// 商业书 `author: [{author_name: …}, …]`。
List<String> _authorNames(Object? v) {
  if (v is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? e in v) {
    final String? name = e is Map ? _str(e['author_name']) : null;
    if (name != null && !out.contains(name)) out.add(name);
  }
  return out;
}

List<String> _names(Object? v) {
  if (v is! List) return const <String>[];
  final List<String> out = <String>[];
  for (final Object? e in v) {
    final String? name = e is Map ? _str(e['name']) : _str(e);
    if (name != null && !out.contains(name)) out.add(name);
  }
  return out;
}

/// `//img.dlsite.jp/...` → `https://img.dlsite.jp/...`；已是绝对 URL 原样返回。
String? _absoluteUrl(Object? v) {
  final String? s = _str(v);
  if (s == null) return null;
  if (s.startsWith('//')) return 'https:$s';
  if (s.startsWith('http://') || s.startsWith('https://')) return s;
  return null;
}
