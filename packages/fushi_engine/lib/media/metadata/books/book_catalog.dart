/// 书目类元数据源（AniList 轻小说 / openBD / NDL Search / 楽天ブックス / iTunes 歌曲）的共用层：
/// 中间表示 [BookCatalogRecord]、领域异常 [BookCatalogException]、ISBN 工具与
/// 带按 host 节流的传输 [BookCatalogHttp]。
///
/// 只做协议与解析，平台无关（不 import flutter），app 的书族刮削服务把
/// [BookCatalogRecord] 映射成自己的候选；无头服务端将来也能直接复用。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:fushi_engine/epub/isbn.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

export 'package:fushi_engine/epub/isbn.dart' show normalizeIsbn13;

/// 书目源请求失败（网络 / 超时 / 非 2xx / 响应结构不对）。查无此书**不是**异常。
class BookCatalogException implements Exception {
  const BookCatalogException(this.message, {this.statusCode});

  /// 技术描述（英文，UI 层套 i18n 外壳）。
  final String message;

  /// 非 2xx 时的 HTTP 状态码。
  final int? statusCode;

  @override
  String toString() {
    final String suffix = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'BookCatalogException: $message$suffix';
  }
}

/// 书目源返回的一本书（各源解析器的共同输出）。
/// 书目条目的形态（AniList `format`）：弹窗据此写明候选是轻小说还是漫画。
enum BookCatalogFormat { novel, manga, manhwa, manhua, oneShot }

class BookCatalogRecord {
  const BookCatalogRecord({
    required this.id,
    required this.title,
    this.originalTitle,
    this.author,
    this.publisher,
    this.series,
    this.volume,
    this.isbn,
    this.year,
    this.date,
    this.tags = const <String>[],
    this.summary,
    this.coverUrl,
    this.coverHeaders,
    this.bannerUrl,
    this.pageUrl,
    this.isAdult = false,
    this.format,
  });

  /// 源内 id：AniList media id / ISBN-13（openBD、NDL、楽天）/ iTunes trackId 或 collectionId。
  final String id;
  final String title;

  /// 另一种写法的标题（AniList 的罗马字等），与 [title] 相同时为 null。
  final String? originalTitle;

  /// 作者（多人以 `, ` 连接）。
  final String? author;
  final String? publisher;

  /// 丛书 / 系列名（文库レーベル等）。
  final String? series;

  /// 卷号原文（「1」「第2期」…）。
  final String? volume;

  /// 规范化 ISBN-13。
  final String? isbn;
  final int? year;

  /// 发行日期原文（`YYYY-MM-DD`，可只到年或年月）；源没给为 null（落库退回 [year]）。
  final String? date;

  /// 类型 / 标签名（iTunes `primaryGenreName`）；源没给为空表。
  final List<String> tags;
  final String? summary;

  /// 封面图 URL；null = 源没有封面。
  final String? coverUrl;

  /// 取封面时必须带的请求头（NDL 缩略图要求 Referer），null = 不需要。
  final Map<String, String>? coverHeaders;

  /// 横幅 / 背景图（AniList `bannerImage`）。
  final String? bannerUrl;

  /// 源站详情页。
  final String? pageUrl;
  final bool isAdult;

  /// 形态（轻小说 / 漫画 / 韩漫 / 国漫 / 短篇）；源不区分时为 null。
  final BookCatalogFormat? format;
}

// ---------------------------------------------------------------------------
// ISBN
// ---------------------------------------------------------------------------

/// 在任意文本（「ISBN 978-4-301-00195-9」、URL、`urn:isbn:` 等）里找第一个合法 ISBN，
/// 返回 ISBN-13；找不到返回 null。规范化口径统一走 [normalizeIsbn13]。
String? findIsbnIn(String text) {
  for (final RegExpMatch m in RegExp(
    r'(97[89][\d\-\s]{10,16}|\d[\d\-\s]{8,12}[\dXx])',
  ).allMatches(text)) {
    final String? isbn = normalizeIsbn13(m.group(0)!.trim());
    if (isbn != null) return isbn;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 传输
// ---------------------------------------------------------------------------

/// 各书目源 host 的最小请求间隔（两次请求**开始**之间）。
///
/// - AniList：文档写 90 req/min，2026-11 实测响应头 `X-RateLimit-Limit: 30`（降级限额），
///   取 2 s 一次，按降级额度也不会撞 429。
/// - NDL Search：按同时连接数限流（实测并发撞 429），1 s 一次且串行。
/// - 楽天：官方限额 1 req/s / applicationId。
/// - openBD：无公开限额，节制一点。
/// - iTunes Search API：Apple 写的是约 20 次 / 分钟，取 3 s 一次。
const Map<String, Duration> kBookCatalogMinIntervals = <String, Duration>{
  'graphql.anilist.co': Duration(seconds: 2),
  'ndlsearch.ndl.go.jp': Duration(seconds: 1),
  'openapi.rakuten.co.jp': Duration(milliseconds: 1100),
  'api.openbd.jp': Duration(milliseconds: 500),
  'itunes.apple.com': Duration(seconds: 3),
};

/// 单次请求的整体超时。
const Duration kBookCatalogRequestTimeout = Duration(seconds: 20);

/// 通用 UA：只标明客户端，不带任何用户信息。
const String kBookCatalogUserAgent =
    'fushi/book-metadata (https://github.com/hajisensai/fushi)';

/// 书目源共用的 HTTP 层：走应用代理出口、按 host 节流（跨实例共享节奏）、统一超时
/// 与错误折叠成 [BookCatalogException]。
class BookCatalogHttp {
  /// [throttle] 为 false 时不节流（测试注入 MockClient 用）。
  BookCatalogHttp({
    http.Client? client,
    this.throttle = true,
    this.requestTimeout = kBookCatalogRequestTimeout,
  }) : _client = client ?? createAppHttpIoClient(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final bool throttle;
  final Duration requestTimeout;

  /// 每个 host 最近一个已占下的请求开始时刻（跨实例）。只存时刻不存 Future，
  /// 理由同 `DlsiteClient._lastRequestStart`。
  static final Map<String, DateTime> _lastStart = <String, DateTime>{};

  static const Map<String, String> _baseHeaders = <String, String>{
    'User-Agent': kBookCatalogUserAgent,
  };

  /// GET，返回 [BookCatalogResponse]（非 2xx 也返回，由调用方决定 404 等怎么解释）。
  Future<BookCatalogResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) => _send(
    uri,
    () => _client.get(
      uri,
      headers: <String, String>{..._baseHeaders, ...headers},
    ),
  );

  /// POST JSON。
  Future<BookCatalogResponse> postJson(Uri uri, Object? body) => _send(
    uri,
    () => _client.post(
      uri,
      headers: <String, String>{
        ..._baseHeaders,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode(body),
    ),
  );

  Future<BookCatalogResponse> _send(
    Uri uri,
    Future<http.Response> Function() request,
  ) async {
    await _reserveSlot(uri.host);
    final http.Response res;
    try {
      res = await request().timeout(requestTimeout);
    } on TimeoutException {
      throw BookCatalogException('request timed out: ${uri.host}${uri.path}');
    } on http.ClientException catch (e) {
      throw BookCatalogException('network error: ${e.message}');
    }
    return BookCatalogResponse(
      res.statusCode,
      utf8.decode(res.bodyBytes, allowMalformed: true),
    );
  }

  /// 「先占坑、再等」：读、算、写同一个同步段里完成，并发调用依次顺延。
  Future<void> _reserveSlot(String host) async {
    if (!throttle) return;
    final Duration interval = kBookCatalogMinIntervals[host] ?? Duration.zero;
    if (interval <= Duration.zero) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastStart[host];
    final DateTime start = (last == null || now.difference(last) >= interval)
        ? now
        : last.add(interval);
    _lastStart[host] = start;
    final Duration wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// 测试用：清空跨实例共享的节奏状态。
  @visibleForTesting
  static void resetRateLimitForTesting() => _lastStart.clear();

  /// 释放默认 client（注入的 client 由调用方管理）。
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// 一次书目源响应（状态码 + UTF-8 正文）。
class BookCatalogResponse {
  const BookCatalogResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

// ---------------------------------------------------------------------------
// 解析小工具（各源共用）
// ---------------------------------------------------------------------------

/// 非空去空白字符串，空 / 非 String 返回 null。
String? catalogString(Object? value) {
  if (value is! String) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 从「2014年04月」「20181012」「2026-12-09」「2024.2」里取 4 位年份。
int? catalogYear(String? raw) {
  if (raw == null) return null;
  final RegExpMatch? m = RegExp(r'(1[5-9]|20)\d{2}').firstMatch(raw);
  return m == null ? null : int.tryParse(m.group(0)!);
}

/// 典拠形人名（「村上, 春樹, 1949-」「日向, 夏」）→ 显示形（「村上春樹」「日向夏」）：
/// 去掉生卒年段，日文名直接相连，拉丁字母名按「名 姓」以空格相连。
String? catalogPersonName(String? raw) {
  final String? s = catalogString(raw);
  if (s == null) return null;
  if (!s.contains(',')) return s;
  final List<String> parts = <String>[
    for (final String p in s.split(','))
      if (p.trim().isNotEmpty &&
          !RegExp(r'^\d{3,4}\s*-\s*(\d{3,4})?$').hasMatch(p.trim()))
        p.trim(),
  ];
  if (parts.isEmpty) return null;
  final bool latin = RegExp(r'^[\x00-\x7F]+$').hasMatch(parts.join());
  return latin ? parts.reversed.join(' ') : parts.join();
}

/// 去掉 HTML 标签（AniList 简介里的 `<br>` / `<i>`），折叠多余空行。
String? catalogStripHtml(String? raw) {
  if (raw == null) return null;
  final String text = raw
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return text.isEmpty ? null : text;
}
