import 'dart:convert';
import 'dart:math' as math;

import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'package:hibiki/src/media/torrent/anime_release_descriptor.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';

const String _nyaaNamespace = 'https://nyaa.si/xmlns/nyaa';

/// 严格搜索契约的稳定错误码。调用方可以按 [code] 区分「空响应、编码、XML、
/// RSS 结构、字段」而不必解析第三方 parser 的易变错误文本。
enum NyaaFeedErrorCode {
  emptyBody,
  unsupportedEncoding,
  invalidUtf8,
  malformedXml,
  notRss,
  missingStructure,
  invalidNamespace,
  missingField,
  invalidField,
}

class NyaaFeedFormatException extends FormatException {
  NyaaFeedFormatException(this.code, String detail)
      : super('Nyaa RSS ${code.name}: $detail');

  final NyaaFeedErrorCode code;
}

/// Nyaa 磁链标准 tracker 列表（nyaa.si 站点磁链默认附带的公开 tracker）。
const List<String> kNyaaTrackers = <String>[
  'http://nyaa.tracker.wf:7777/announce',
  'udp://open.stunner.irish:80/announce',
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.tracker.cl:1337/announce',
  'udp://exodus.desync.com:6969/announce',
];

/// 成对括号块（字幕组 / 画质 / 年份 tag）：`[...]` `(...)`。
final RegExp _rangeBracketBlock = RegExp(r'\[[^\]]*\]|\([^)]*\)');

/// 集号区间：`01-12` / `01~13` / `01〜13`（两数间以 `-`/`~`/`〜` 连接）。
final RegExp _episodeRange = RegExp(r'(\d{1,4})\s*[-~〜]\s*(\d{1,4})');

/// Nyaa RSS 搜索结果里的一个种子条目。
class NyaaTorrent {
  const NyaaTorrent({
    required this.title,
    required this.torrentUrl,
    required this.pageUrl,
    required this.infoHash,
    required this.seeders,
    required this.leechers,
    required this.downloads,
    required this.sizeText,
    required this.sizeBytes,
    required this.categoryId,
    required this.trusted,
    required this.remake,
    required this.pubDate,
  });

  /// 发布标题（含字幕组 tag / 画质 / 集号）。
  final String title;

  /// `.torrent` 下载地址（`https://nyaa.si/download/<id>.torrent`）。
  final String torrentUrl;

  /// 详情页 URL（RSS `guid`）。
  final String pageUrl;

  /// BT infoHash（`nyaa:infoHash`）。
  final String infoHash;

  /// 做种数。
  final int seeders;

  /// 下载中数。
  final int leechers;

  /// 完成下载次数。
  final int downloads;

  /// 站点展示的体积文本（如 `1.4 GiB`）。
  final String sizeText;

  /// 由 [parseNyaaSize] 从 [sizeText] 换算的字节数；认不出为 null。
  final int? sizeBytes;

  /// Nyaa 分类 id（如 `1_2` = 动画英译）。
  final String categoryId;

  /// 是否 trusted 发布（`nyaa:trusted` = `Yes`）。
  final bool trusted;

  /// 是否 remake（`nyaa:remake` = `Yes`）。
  final bool remake;

  /// 发布时间（RFC822 `pubDate`，UTC）；解析失败为 null。
  final DateTime? pubDate;

  /// 由 infoHash 构造的磁力链接（附 nyaa 标准 tracker 列表）。
  String get magnet {
    final StringBuffer sb = StringBuffer(
      'magnet:?xt=urn:btih:$infoHash&dn=${Uri.encodeComponent(title)}',
    );
    for (final String tracker in kNyaaTrackers) {
      sb.write('&tr=${Uri.encodeComponent(tracker)}');
    }
    return sb.toString();
  }

  /// 从标题解析的单集号（复用 [parseVideoFilename]）；认不出为 null。
  int? get episode => parseVideoFilename(title).episode;

  /// 从标题解析的季号（`S1` / `Season 2` / `第二季` 等，复用 [parseVideoFilename]）；
  /// 认不出为 null。整季包（标季不标集号）靠它与 [episode] 一起判定，见
  /// `torrentEpisodeScope`。
  int? get season => parseVideoFilename(title).season;

  /// 从标题解析的系列名（复用 [parseVideoFilename]，剥字幕组 tag / 画质 / 集号）。
  String get parsedSeries => parseVideoFilename(title).series;

  /// 合集集号区间（如 `01-12` → `(1, 12)`）；非合集为 null。见 [parseNyaaEpisodeRange]。
  (int, int)? get episodeRange => parseNyaaEpisodeRange(title);

  /// 是否合集（batch）：识别出集号区间，或标题含 `batch` 且无单集号。
  bool get isBatch =>
      episodeRange != null ||
      (title.toLowerCase().contains('batch') && episode == null);

  /// 标题的结构化资源规格；每次访问都由纯函数解析，不持有额外状态。
  AnimeReleaseDescriptor get releaseDescriptor =>
      parseAnimeReleaseDescriptor(title);

  /// 标题里的标准分辨率标记（`1080p`/`2160p` 等）；没有为 null。
  ///
  /// 兼容旧调用方，真实解析统一收口在 [releaseDescriptor]。
  String? get resolution => releaseDescriptor.resolution;

  /// 标题开头第一个 `[xxx]` 块的内容（发布组名）；没有为 null。
  ///
  /// 兼容旧调用方，真实解析统一收口在 [releaseDescriptor]。
  String? get releaseGroup => releaseDescriptor.releaseGroup;
}

/// 从标题识别合集集号区间。纯函数，便于单测。
///
/// 先剥掉 `[...]` / `(...)` 括号块（避免命中字幕组 tag / 画质 / 年份），再匹配
/// `01-12` / `01~13` / `01〜13`；要求第二个数大于第一个且差值 < 200（避免命中
/// `1920x1080` 或年份区间这类非集号数字对）。认不出返回 null。
(int, int)? parseNyaaEpisodeRange(String title) {
  final String stripped = title.replaceAll(_rangeBracketBlock, ' ');
  for (final RegExpMatch m in _episodeRange.allMatches(stripped)) {
    final int first = int.parse(m.group(1)!);
    final int second = int.parse(m.group(2)!);
    if (second > first && second - first < 200) return (first, second);
  }
  return null;
}

/// 把 nyaa 体积文本（`1.4 GiB` / `700.5 MiB` / `980 KiB` / `123 B`）换算成
/// 字节数。纯函数，认不出返回 null。
int? parseNyaaSize(String text) {
  final RegExpMatch? m = RegExp(
    r'^\s*(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB|TiB)\s*$',
    caseSensitive: false,
  ).firstMatch(text);
  if (m == null) return null;
  const Map<String, int> exponents = <String, int>{
    'b': 0,
    'kib': 1,
    'mib': 2,
    'gib': 3,
    'tib': 4,
  };
  final double value = double.parse(m.group(1)!);
  final int exponent = exponents[m.group(2)!.toLowerCase()]!;
  return (value * math.pow(1024, exponent)).round();
}

const Map<String, int> _rfc822Months = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// 解析 RSS `pubDate` 的 RFC822 时间（如 `Fri, 03 Nov 2023 12:30:00 -0000`），
/// 归一到 UTC。纯函数，解析失败返回 null。
DateTime? parseNyaaPubDate(String raw) {
  final RegExpMatch? m = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]{1,3})?',
  ).firstMatch(raw);
  if (m == null) return null;
  final int? month = _rfc822Months[m.group(2)!.toLowerCase()];
  if (month == null) return null;
  int offsetMinutes = 0;
  final String? zone = m.group(7);
  if (zone != null && RegExp(r'^[+-]\d{4}$').hasMatch(zone)) {
    final int sign = zone.startsWith('-') ? -1 : 1;
    offsetMinutes = sign *
        (int.parse(zone.substring(1, 3)) * 60 + int.parse(zone.substring(3)));
  }
  // 其它字母时区（GMT/UT 等）按 0 偏移处理；nyaa 实际恒发 `-0000`。
  final DateTime utc = DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6) ?? '0'),
  );
  return utc.subtract(Duration(minutes: offsetMinutes));
}

/// 解析 Nyaa RSS 响应为 [NyaaTorrent] 列表。纯函数，容错：坏 XML / 空 body /
/// 无 `<item>` 一律返回空列表，不抛。
///
/// `nyaa:` 命名空间字段按本地名匹配（`nyaa:seeders` → `seeders`），对命名空间
/// 前缀变化保持宽容；`<item>` 内本地名与 nyaa 扩展字段无冲突。
List<NyaaTorrent> parseNyaaRss(String body) {
  if (body.trim().isEmpty) return const <NyaaTorrent>[];
  try {
    return _parseNyaaDocument(XmlDocument.parse(body));
  } catch (_) {
    return const <NyaaTorrent>[];
  }
}

List<NyaaTorrent> _parseNyaaDocument(XmlDocument doc) {
  final List<NyaaTorrent> out = <NyaaTorrent>[];
  for (final XmlElement item in doc.findAllElements('item')) {
    final String title = _childText(item, 'title');
    if (title.isEmpty) continue;
    final String sizeText = _childText(item, 'size');
    out.add(
      NyaaTorrent(
        title: title,
        torrentUrl: _childText(item, 'link'),
        pageUrl: _childText(item, 'guid'),
        infoHash: _childText(item, 'infoHash'),
        seeders: int.tryParse(_childText(item, 'seeders')) ?? 0,
        leechers: int.tryParse(_childText(item, 'leechers')) ?? 0,
        downloads: int.tryParse(_childText(item, 'downloads')) ?? 0,
        sizeText: sizeText,
        sizeBytes: parseNyaaSize(sizeText),
        categoryId: _childText(item, 'categoryId'),
        trusted: _childText(item, 'trusted') == 'Yes',
        remake: _childText(item, 'remake') == 'Yes',
        pubDate: parseNyaaPubDate(_childText(item, 'pubDate')),
      ),
    );
  }
  return out;
}

List<NyaaTorrent> _parseNyaaDocumentStrict(XmlDocument doc) {
  final XmlElement root = doc.rootElement;
  if (root.name.local != 'rss') {
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.notRss,
      'root element must be <rss>',
    );
  }
  final List<XmlElement> channels = root.childElements
      .where((XmlElement element) => element.name.local == 'channel')
      .toList(growable: false);
  if (channels.length != 1) {
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.missingStructure,
      'feed must contain exactly one direct <channel>',
    );
  }

  final List<NyaaTorrent> out = <NyaaTorrent>[];
  for (final XmlElement item in channels.single.childElements.where(
    (XmlElement element) => element.name.local == 'item',
  )) {
    String requiredRssField(String name) {
      final String value = _childTextInNamespace(item, name, null);
      if (value.isEmpty) {
        throw NyaaFeedFormatException(
          NyaaFeedErrorCode.missingField,
          'item is missing <$name>',
        );
      }
      return value;
    }

    String requiredNyaaField(String name) {
      final XmlElement? element = _childElement(item, name);
      if (element == null || element.innerText.trim().isEmpty) {
        throw NyaaFeedFormatException(
          NyaaFeedErrorCode.missingField,
          'item is missing nyaa:$name',
        );
      }
      if (element.name.namespaceUri != _nyaaNamespace) {
        throw NyaaFeedFormatException(
          NyaaFeedErrorCode.invalidNamespace,
          '$name must use $_nyaaNamespace',
        );
      }
      return element.innerText.trim();
    }

    final String title = requiredRssField('title');
    final String torrentUrl = requiredRssField('link');
    final String pageUrl = requiredRssField('guid');
    final String infoHash = requiredNyaaField('infoHash');
    if (!RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(infoHash)) {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.invalidField,
        'nyaa:infoHash must be 40 hexadecimal characters',
      );
    }

    final String sizeText = _childTextInNamespace(item, 'size', _nyaaNamespace);
    out.add(
      NyaaTorrent(
        title: title,
        torrentUrl: torrentUrl,
        pageUrl: pageUrl,
        infoHash: infoHash,
        seeders: _optionalNyaaInt(item, 'seeders'),
        leechers: _optionalNyaaInt(item, 'leechers'),
        downloads: _optionalNyaaInt(item, 'downloads'),
        sizeText: sizeText,
        sizeBytes: parseNyaaSize(sizeText),
        categoryId: _childTextInNamespace(item, 'categoryId', _nyaaNamespace),
        trusted:
            _childTextInNamespace(item, 'trusted', _nyaaNamespace) == 'Yes',
        remake: _childTextInNamespace(item, 'remake', _nyaaNamespace) == 'Yes',
        pubDate: parseNyaaPubDate(_childTextInNamespace(item, 'pubDate', null)),
      ),
    );
  }
  return out;
}

int _optionalNyaaInt(XmlElement item, String name) {
  final XmlElement? element = _childElement(item, name);
  if (element == null) return 0;
  if (element.name.namespaceUri != _nyaaNamespace) {
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.invalidNamespace,
      '$name must use $_nyaaNamespace',
    );
  }
  final String value = element.innerText.trim();
  final int? parsed = int.tryParse(value);
  if (parsed == null || parsed < 0) {
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.invalidField,
      'nyaa:$name must be a non-negative integer',
    );
  }
  return parsed;
}

XmlElement? _childElement(XmlElement item, String local) {
  for (final XmlElement child in item.childElements) {
    if (child.name.local == local) return child;
  }
  return null;
}

String _childTextInNamespace(XmlElement item, String local, String? namespace) {
  for (final XmlElement child in item.childElements) {
    if (child.name.local == local && child.name.namespaceUri == namespace) {
      return child.innerText.trim();
    }
  }
  return '';
}

/// 取 [item] 下本地名为 [local] 的第一个子元素文本（去首尾空白）；没有返回空串。
String _childText(XmlElement item, String local) {
  for (final XmlElement child in item.childElements) {
    if (child.name.local == local) return child.innerText.trim();
  }
  return '';
}

/// Nyaa（nyaa.si）搜索客户端。无需鉴权。
///
/// 首屏端点：`GET {base}/?page=rss&q=<query>&c=<category>&f=<filter>`。
/// 后续页使用 Nyaa 的 HTML 搜索端点 `GET {base}/?p=<page>&...`。Nyaa
/// 上游虽然会解析 RSS 请求里的 `p`，但 RSS 查询分支只做 `limit`、不做
/// `offset`，会重复返回首屏；因此不能用 RSS 假装分页。
/// category 直接透传（常用：`1_0` 全部动画 / `1_2` 英译 / `1_3` 非英译 /
/// `1_4` 生肉 Raw）；filter：`0` 无过滤 / `2` 仅 trusted。
class NyaaClient {
  NyaaClient({this.baseUrl = 'https://nyaa.si', http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// 按关键词搜索种子。网络错误 / 非 200 **抛出**（`ClientException` /
  /// `SocketException` / `HandshakeException` 等），由调用方决定展示或记录：
  /// 以前这里吞错返回空列表，真实网络故障（如站点被墙、代理未配）会被
  /// 误报成「无结果」，用户无从判断。空响应 / 损坏 RSS 同样抛
  /// [FormatException]；只有结构有效、确实没有 `<item>` 才返回空列表。
  Future<List<NyaaTorrent>> search(
    String query, {
    String category = '1_0',
    String filter = '0',
    int page = 1,
  }) async {
    if (page <= 0) throw ArgumentError.value(page, 'page');
    final bool renderAsRss = page == 1;
    final Uri uri = Uri.parse(baseUrl).replace(
      path: '/',
      queryParameters: <String, String>{
        if (renderAsRss) 'page': 'rss' else 'p': page.toString(),
        'q': query,
        'c': category,
        'f': filter,
      },
    );
    final http.Response res = await _client.get(uri);
    if (!renderAsRss && res.statusCode == 404) {
      // Nyaa returns 404 when a valid HTML search asks past its final page.
      return const <NyaaTorrent>[];
    }
    if (res.statusCode != 200) {
      throw http.ClientException('HTTP ${res.statusCode}', uri);
    }
    final String? declaredCharset = RegExp(
      r'''charset\s*=\s*['"]?([^;'"\s]+)''',
      caseSensitive: false,
    ).firstMatch(res.headers['content-type'] ?? '')?.group(1)?.toLowerCase();
    if (declaredCharset != null &&
        declaredCharset != 'utf-8' &&
        declaredCharset != 'utf8') {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.unsupportedEncoding,
        'HTTP declared $declaredCharset; UTF-8 is required',
      );
    }

    // Nyaa RSS 是 UTF-8但常不声明 charset；必须严格解码，损坏字节不能被 U+FFFD
    // 替换后继续冒充有效结果。
    final String body;
    try {
      body = utf8.decode(res.bodyBytes);
    } on FormatException {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.invalidUtf8,
        'body contains invalid UTF-8 bytes',
      );
    }
    if (body.trim().isEmpty) {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.emptyBody,
        'response body was empty',
      );
    }
    if (!renderAsRss) return _parseNyaaHtmlSearch(body, uri);
    try {
      final XmlDocument doc = XmlDocument.parse(body);
      final String? xmlEncoding = doc.declaration?.encoding?.toLowerCase();
      if (xmlEncoding != null &&
          xmlEncoding != 'utf-8' &&
          xmlEncoding != 'utf8') {
        throw NyaaFeedFormatException(
          NyaaFeedErrorCode.unsupportedEncoding,
          'XML declared $xmlEncoding; UTF-8 is required',
        );
      }
      return _parseNyaaDocumentStrict(doc);
    } on NyaaFeedFormatException {
      rethrow;
    } on XmlException catch (error) {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.malformedXml,
        error.message,
      );
    }
  }

  void close() => _client.close();
}

List<NyaaTorrent> _parseNyaaHtmlSearch(String body, Uri requestUri) {
  final html_dom.Document document = html_parser.parse(body);
  final html_dom.Element? table = document.querySelector('table.torrent-list');
  if (table == null) {
    final bool noResults = document.querySelectorAll('h3').any(
          (html_dom.Element heading) =>
              heading.text.trim().toLowerCase() == 'no results found',
        );
    if (noResults) return const <NyaaTorrent>[];
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.missingStructure,
      'HTML search page is missing table.torrent-list',
    );
  }

  final List<NyaaTorrent> torrents = <NyaaTorrent>[];
  for (final html_dom.Element row in table.querySelectorAll('tbody tr')) {
    final List<html_dom.Element> cells = row.children
        .where((html_dom.Element element) => element.localName == 'td')
        .toList(growable: false);
    if (cells.length < 5) {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.missingStructure,
        'HTML torrent row has fewer than five cells',
      );
    }

    final html_dom.Element? detailLink = cells[1]
        .querySelectorAll('a[href]')
        .cast<html_dom.Element?>()
        .firstWhere(
      (html_dom.Element? link) {
        final String href = link?.attributes['href'] ?? '';
        return Uri.tryParse(href)?.path.startsWith('/view/') == true;
      },
      orElse: () => null,
    );
    final html_dom.Element? magnetLink = cells[2]
        .querySelectorAll('a[href]')
        .cast<html_dom.Element?>()
        .firstWhere(
          (html_dom.Element? link) =>
              (link?.attributes['href'] ?? '').startsWith('magnet:'),
          orElse: () => null,
        );
    final String title =
        (detailLink?.attributes['title'] ?? detailLink?.text ?? '').trim();
    final String magnet = magnetLink?.attributes['href'] ?? '';
    final String? exactTopic = Uri.tryParse(magnet)?.queryParameters['xt'];
    final String infoHash =
        exactTopic?.toLowerCase().startsWith('urn:btih:') == true
            ? exactTopic!.substring('urn:btih:'.length).toLowerCase()
            : '';
    if (title.isEmpty ||
        detailLink == null ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(infoHash)) {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.missingField,
        'HTML torrent row is missing title, detail URL, or info hash',
      );
    }

    String torrentUrl = '';
    for (final html_dom.Element link in cells[2].querySelectorAll('a[href]')) {
      final String href = link.attributes['href'] ?? '';
      if (Uri.tryParse(href)?.path.endsWith('.torrent') == true) {
        torrentUrl = requestUri.resolve(href).toString();
        break;
      }
    }
    String categoryId = '';
    for (final html_dom.Element link in cells[0].querySelectorAll('a[href]')) {
      final String? candidate =
          Uri.tryParse(link.attributes['href'] ?? '')?.queryParameters['c'];
      if (candidate?.isNotEmpty == true) {
        categoryId = candidate!;
        break;
      }
    }
    final int? timestampSeconds =
        int.tryParse(cells[4].attributes['data-timestamp'] ?? '');
    torrents.add(
      NyaaTorrent(
        title: title,
        torrentUrl: torrentUrl,
        pageUrl: requestUri.resolve(detailLink.attributes['href']!).toString(),
        infoHash: infoHash,
        seeders: cells.length > 5 ? int.tryParse(cells[5].text.trim()) ?? 0 : 0,
        leechers:
            cells.length > 6 ? int.tryParse(cells[6].text.trim()) ?? 0 : 0,
        downloads:
            cells.length > 7 ? int.tryParse(cells[7].text.trim()) ?? 0 : 0,
        sizeText: cells[3].text.trim(),
        sizeBytes: parseNyaaSize(cells[3].text.trim()),
        categoryId: categoryId,
        trusted: row.classes.contains('success'),
        remake: row.classes.contains('danger'),
        pubDate: timestampSeconds == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                timestampSeconds * 1000,
                isUtc: true,
              ),
      ),
    );
  }
  return List<NyaaTorrent>.unmodifiable(torrents);
}
