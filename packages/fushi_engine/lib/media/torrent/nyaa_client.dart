import 'dart:convert';
import 'dart:math' as math;

import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/anime_release_descriptor.dart';
import 'package:fushi_engine/media/torrent/download_timeouts.dart';
import 'package:fushi_engine/media/torrent/public_trackers.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// nyaa 扩展字段命名空间的固定路径。上游 nyaa 软件把命名空间拼成
/// `<站点 origin>/xmlns/nyaa`（`url_for('main.home', _external=True)`），
/// 所以 nyaa.si / sukebei.nyaa.si / 各镜像的 host 各不相同，只有路径恒定；
/// 硬编码 `https://nyaa.si/xmlns/nyaa` 会把 sukebei 每条 item 判成
/// invalidNamespace（BUG-1946）。
const String _nyaaNamespacePath = '/xmlns/nyaa';

/// [uri] 是否 nyaa 扩展字段命名空间（http(s) 且路径为 [_nyaaNamespacePath]）。
bool isNyaaNamespace(String? uri) {
  final Uri? parsed = uri == null ? null : Uri.tryParse(uri);
  return parsed != null &&
      (parsed.scheme == 'https' || parsed.scheme == 'http') &&
      parsed.host.isNotEmpty &&
      parsed.path == _nyaaNamespacePath;
}

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

/// Nyaa 磁链 tracker 列表：站点专属 tracker 排最前，后面跟内置公开兜底集
/// [kPublicTrackers]。nyaa 自己的 tracker 只覆盖本站种子，公开的那批才是
/// 「站点 tracker 挂了/种子已从本站下架」时还能连上 peer 的那条路。
const List<String> kNyaaTrackers = <String>[
  'http://nyaa.tracker.wf:7777/announce',
  ...kPublicTrackers,
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
///
/// 生产搜索已改走 HTML 搜索页（见 [NyaaClient.search]：RSS 被 nyaa 后端强制按
/// id 倒序、忽略 `s/o` 与分页）；本函数与 [parseNyaaRssStrict] 只保留给测试与
/// 仍消费 RSS 的旧调用方。
List<NyaaTorrent> parseNyaaRss(String body) {
  if (body.trim().isEmpty) return const <NyaaTorrent>[];
  try {
    return _parseNyaaDocument(XmlDocument.parse(body));
  } catch (_) {
    return const <NyaaTorrent>[];
  }
}

/// 严格解析 Nyaa RSS：空 body / 非 UTF-8 XML 声明 / 坏 XML / 非 `<rss>` /
/// 缺 `<channel>` / 缺必需字段 / 命名空间不对一律抛 [NyaaFeedFormatException]
/// （错误码见 [NyaaFeedErrorCode]），只有结构有效、确实没有 `<item>` 才返回空。
///
/// 这是原 [NyaaClient.search] RSS 首屏的解析层；HTTP 层（charset 头、UTF-8
/// 解码）不在这里。见 [parseNyaaRss] 的说明。
List<NyaaTorrent> parseNyaaRssStrict(String body) {
  if (body.trim().isEmpty) {
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.emptyBody,
      'response body was empty',
    );
  }
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
      if (!isNyaaNamespace(element.name.namespaceUri)) {
        throw NyaaFeedFormatException(
          NyaaFeedErrorCode.invalidNamespace,
          '$name must use <site>$_nyaaNamespacePath',
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

    final String sizeText = _nyaaChildText(item, 'size');
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
        categoryId: _nyaaChildText(item, 'categoryId'),
        trusted: _nyaaChildText(item, 'trusted') == 'Yes',
        remake: _nyaaChildText(item, 'remake') == 'Yes',
        pubDate: parseNyaaPubDate(_childTextInNamespace(item, 'pubDate', null)),
      ),
    );
  }
  return out;
}

int _optionalNyaaInt(XmlElement item, String name) {
  final XmlElement? element = _childElement(item, name);
  if (element == null) return 0;
  if (!isNyaaNamespace(element.name.namespaceUri)) {
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.invalidNamespace,
      '$name must use <site>$_nyaaNamespacePath',
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

/// 取 [item] 下 nyaa 扩展命名空间里本地名为 [local] 的第一个子元素文本；
/// 没有返回空串。
String _nyaaChildText(XmlElement item, String local) {
  for (final XmlElement child in item.childElements) {
    if (child.name.local == local && isNyaaNamespace(child.name.namespaceUri)) {
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

/// Nyaa HTML 搜索页的排序字段（查询参数 `s`）。
///
/// 只有 HTML 搜索页尊重它：nyaa 后端 `search.py` 对 RSS 两处写死按 id 倒序
/// （ES 路径 "Only allow ID, desc if RSS"，DB 路径 "Force sort by id desc if
/// rss"），所以排序必须走 HTML。
enum NyaaSort {
  /// 做种数（发现页默认：死种沉底）。
  seeders('seeders'),

  /// 发布时间（站内 id 单调递增，nyaa 用 `s=id` 表示按时间；订阅轮询用它
  /// 保住「最新集在前 75 条里」的旧语义）。
  date('id'),

  size('size'),
  leechers('leechers'),
  downloads('downloads');

  const NyaaSort(this.queryValue);

  /// 透传给 nyaa 的 `s=` 值。
  final String queryValue;
}

/// Nyaa 搜索排序方向（查询参数 `o`）。
enum NyaaSortOrder {
  desc,
  asc;

  /// 透传给 nyaa 的 `o=` 值。
  String get queryValue => name;
}

/// Nyaa 过滤三态（查询参数 `f`）。`f=3`（仅完结批次）后端有但 UI 不露出、
/// 无文档，刻意不暴露。
enum NyaaQualityFilter {
  /// 全部（与 Nyaa UI / Prowlarr / Flexget 默认一致）。
  all('0'),

  /// 排除 remake。
  noRemakes('1'),

  /// 仅 trusted 发布者。
  trustedOnly('2');

  const NyaaQualityFilter(this.queryValue);

  /// 透传给 nyaa 的 `f=` 值。
  final String queryValue;

  /// 从持久化的 int（0/1/2）还原；越界值回落 [all]，不抛。
  static NyaaQualityFilter fromIndex(int index) =>
      index >= 0 && index < values.length ? values[index] : all;
}

/// 关键词搜索走 Elasticsearch，后端最多回 1000 条 = 14 页（每页 75）。
const int kNyaaMaxSearchPages = 14;

/// 无关键词浏览走 DB，后端最多 100 页。
const int kNyaaMaxBrowsePages = 100;

/// 同一 host 两次请求的最小间隔（对齐 Jackett/Prowlarr 的 nyaasi 定义）。
const Duration kNyaaMinRequestInterval = Duration(seconds: 2);

/// Nyaa 式站点（HTML 搜索页 + `table.torrent-list`）的搜索客户端。无需鉴权。
///
/// **不内置任何站点地址**：[baseUrl] 由调用方给（用户在设置里添加的 BT 站，见
/// `bt_site_config.dart`）。
///
/// 端点：HTML 搜索页
/// `GET {base}/?q=<query>&c=<category>&f=<filter>&s=<sort>&o=<order>[&p=<page>]`。
/// **不用 RSS 作首屏**：nyaa 后端对 RSS 强制按 id 倒序、忽略 `s/o`、只回 75
/// 条且不做 `offset` 分页；同参数实测 RSS 首条做种 34、HTML 首条 288。HTML
/// 行 class 给出 trusted（`success`）/ remake（`danger`）；remake 行只显示红，
/// trusted 用户发的 remake 在 HTML 里 trusted 信息被吞，与 RSS 不同。
/// category 直接透传（常用：`1_0` 全部动画 / `1_2` 英译 / `1_3` 非英译 /
/// `1_4` 生肉 Raw / `3_0` 全部 Literature）；filter 见 [NyaaQualityFilter]。
///
/// 打同一站点 host 的请求按 [minRequestInterval] 节流（跨实例共用节奏，实例内串行）。
class NyaaClient {
  NyaaClient({
    required this.baseUrl,
    http.Client? client,
    this.requestTimeout = kDownloadDiscoveryTimeout,
    this.minRequestInterval = kNyaaMinRequestInterval,
    Duration Function()? monotonicNow,
  })  : _client = client ?? createAppHttpIoClient(),
        _monotonicNow = monotonicNow ?? _processMonotonicNow;

  final String baseUrl;
  final http.Client _client;

  /// 同 host 两次请求**开始**之间的最小间隔；测试可注入 [Duration.zero]。
  final Duration minRequestInterval;

  /// 各站点 host 最近一次请求的放行时刻（单调时钟读数）：调用进入时先同步记下
  /// 预约的那一格，醒来后若实际放行更晚再改记成实际时刻（见 [_waitForRequestSlot]）。多个实例
  /// （发现源 / 视频资源 provider / 订阅轮询）打同一站点时共用节奏，这才是
  /// 「同 host」而不只是「同实例」。
  ///
  /// 只存时刻、不存 Future：完成态 Future 记住创建时的 zone，测试在 setUp 里建
  /// client、在 fake-async 测试体里 await 时，`then` 回调会被派到拿不到 pump 的
  /// zone 里，整条搜索无声挂死（pumpAndSettle 超时、请求根本没发出）。
  static final Map<String, Duration> _lastRequestStartByHost =
      <String, Duration>{};

  /// 进程级单调时钟。节流间隔不能用墙钟 `DateTime.now()` 量：系统校时把墙钟
  /// 往回拨时，「距上次多久」会算成负数，下一次请求要睡掉回拨的整段时长。
  static final Stopwatch _processMonotonicClock = Stopwatch()..start();

  static Duration _processMonotonicNow() => _processMonotonicClock.elapsed;

  /// 读单调时钟。默认是进程级 [Stopwatch]；测试注入 fake-async 的
  /// `elapsed`，让节流完全由虚拟时间驱动、不受调度负载影响。注入的时间基与
  /// 默认时钟不同，所以注入方必须用独占的 [baseUrl] host，别和其它 client 共用
  /// [_lastRequestStartByHost] 的同一格。
  final Duration Function() _monotonicNow;

  /// 本实例排队的尾巴；null = 没人在排。惰性创建，理由同上。
  Future<void>? _requestQueueTail;

  /// 排队等到下一个允许发请求的时刻；并发调用按到达顺序串行放行。
  Future<void> _reserveRequestSlot() {
    final Future<void> slot = _waitForRequestSlot(_requestQueueTail);
    _requestQueueTail = slot;
    return slot;
  }

  Future<void> _waitForRequestSlot(Future<void>? previous) async {
    if (previous != null) await previous;
    final String host = Uri.parse(baseUrl).host;
    // **进入时先同步占坑、再睡**，不能「读 last → 睡 → 写 last」：后者中间隔着
    // 一个 await，发现源 / 资源 provider / 订阅轮询各自 new 的 client 并发打同一
    // 站点时，会同时读到同一个 last、同时睡到同一时刻、然后一起发请求 —— 契约说的
    // 「同 host 至少间隔 minRequestInterval」退化成「一阵爆发再等一轮」。这里的读改写
    // 在同一个同步段里完成（Dart 单线程，无 await 即不可被打断），所以下一个并发调用
    // （无论哪个实例）看到的已经是这一格预约，自己再顺延一格。
    //
    // 醒来后再把这一格改记成**实际放行**时刻：定时器在负载下晚醒（计划 +120ms、
    // 实际 +300ms 才醒）时，后面的调用要从实际放行时刻起算，否则会拿计划时刻算出
    // 「早就过了」而贴着这一次一起打出去。只往后改、不往回改：期间别的调用可能已经
    // 在后面占了更晚的一格，那一格不能被覆盖掉。（同实例的调用经 [_requestQueueTail]
    // 串行，下一个总在这里改记之后才占坑；别的实例已经按预约排好的定时器则挪不动，
    // 晚醒的余量只能由它们醒来时各自的改记吸收。）
    //
    // 只睡一次、醒来不再按时钟复查：时钟（真实单调时钟）和定时器（当前 zone 的
    // `Future.delayed`）不是同一个时间源。widget 测试的 fake-async 里定时器走虚拟
    // 时间、单调时钟走真实时间，「睡醒再查」会一直查出「还差一点」再睡，请求被
    // 无限推迟（resource_search_page_scroll_test 实测因此变红）。
    //
    // 存的仍然只是时刻、不是 Future —— 静态存完成态 Future 正是上面注释里那个
    // 跨 zone 挂死的坑，别为了排队把它请回来。
    final Duration now = _monotonicNow();
    final Duration? last = _lastRequestStartByHost[host];
    final Duration reserved =
        (last == null || now - last >= minRequestInterval)
            ? now
            : last + minRequestInterval;
    _lastRequestStartByHost[host] = reserved;
    final Duration wait = reserved - now;
    if (wait <= Duration.zero) return;
    await Future<void>.delayed(wait);
    final Duration released = _monotonicNow();
    final Duration latest = _lastRequestStartByHost[host] ?? released;
    if (released > latest) _lastRequestStartByHost[host] = released;
  }

  /// 单次请求的整体超时上限。默认取发现链路的唯一真相源
  /// [kDownloadDiscoveryTimeout]；可注入只为测试能用短值跑。
  ///
  /// 没有这层，`search` 就完全不设时限：`http` 的 IO client 依赖
  /// `HttpClient.connectionTimeout`，而它默认是 null（不超时），站点被墙或
  /// 代理半开的连接能挂到操作系统重传耗尽为止（BUG-2079）。订阅检查
  /// (`anime_download_subscription.dart`) 与搜索对话框在调用点各自包了
  /// `.timeout(kDownloadDiscoveryTimeout)`，但 discovery source
  /// (`nyaa_discovery_source.dart`) 与 resource provider
  /// (`nyaa_resource_provider.dart`) 这两条注册表路径没有——超时必须落在
  /// client 自己身上，否则每加一个消费方就要重记一次这笔账。
  ///
  /// **值必须是 [kDownloadDiscoveryTimeout] 而不是 torznab 那个 20s**：
  /// 20s 正是 BUG-1141 从这条链路上拆掉的直连口径魔法数字（代理下握手 +
  /// TLS 常年超它），而且它比上述调用点的外层 60s 更紧，等于替那两条路径
  /// 偷偷回退 BUG-1141。torznab 的索引器多是自建/本机，20s 在那边另有依据，
  /// 两边不合并。
  final Duration requestTimeout;

  /// 按关键词搜索种子。网络错误 / 非 200 **抛出**（`ClientException` /
  /// `SocketException` / `HandshakeException` 等），由调用方决定展示或记录：
  /// 以前这里吞错返回空列表，真实网络故障（如站点被墙、代理未配）会被
  /// 误报成「无结果」，用户无从判断。空响应 / 不是搜索页的 HTML 同样抛
  /// [NyaaFeedFormatException]；只有结构有效、确实没有结果行才返回空列表。
  ///
  /// [sort] / [order] 默认按做种数降序。[page] 越过后端上限
  /// （[kNyaaMaxSearchPages] / [kNyaaMaxBrowsePages]）直接返回空、不发请求
  /// 也不抛——那是「翻到底了」，不是错误。
  Future<List<NyaaTorrent>> search(
    String query, {
    String category = '1_0',
    String filter = '0',
    int page = 1,
    NyaaSort sort = NyaaSort.seeders,
    NyaaSortOrder order = NyaaSortOrder.desc,
  }) async {
    if (page <= 0) throw ArgumentError.value(page, 'page');
    final int maxPages =
        query.trim().isEmpty ? kNyaaMaxBrowsePages : kNyaaMaxSearchPages;
    if (page > maxPages) return const <NyaaTorrent>[];
    final Uri uri = Uri.parse(baseUrl).replace(
      path: '/',
      queryParameters: <String, String>{
        'q': query,
        'c': category,
        'f': filter,
        's': sort.queryValue,
        'o': order.queryValue,
        if (page > 1) 'p': page.toString(),
      },
    );
    final String? body = await _fetchSearchPage(uri, pastEndIsEmpty: page > 1);
    if (body == null) return const <NyaaTorrent>[];
    return _parseNyaaHtmlSearch(body, uri);
  }

  /// 探测这个地址是不是 Nyaa 式站点（添加 BT 站时的自动识别，见
  /// `bt_site_probe.dart`）：用 [query] 搜一次全站（`c=0_0`），页面必须是能解析
  /// 的搜索结果页（有结果表，或「No results found」）；顺带从页面的分类下拉
  /// （`<select name="c">`）读出该站可用的分类。不是搜索页一律抛，与 [search]
  /// 同一套错误契约。
  Future<NyaaSiteProbe> probeSite(String query) async {
    final Uri uri = Uri.parse(baseUrl).replace(
      path: '/',
      queryParameters: <String, String>{'q': query, 'c': '0_0', 'f': '0'},
    );
    final String body = (await _fetchSearchPage(uri, pastEndIsEmpty: false))!;
    final List<NyaaTorrent> torrents = _parseNyaaHtmlSearch(body, uri);
    final List<NyaaCategoryOption> categories = parseNyaaCategoryOptions(body);
    // 0 条结果时页面上只剩一个「No results found」标题——任何网站都可能有这
    // 句话，单凭它不足以认定是 Nyaa 式站点；还得有它的分类下拉。
    if (torrents.isEmpty && categories.isEmpty) {
      throw NyaaFeedFormatException(
        NyaaFeedErrorCode.missingStructure,
        'search page has neither results nor a category selector',
      );
    }
    return NyaaSiteProbe(resultCount: torrents.length, categories: categories);
  }

  /// 取一页搜索 HTML。[pastEndIsEmpty] 时 404 视作「翻过末页」返回 null。
  Future<String?> _fetchSearchPage(
    Uri uri, {
    required bool pastEndIsEmpty,
  }) async {
    await _reserveRequestSlot();
    final http.Response res = await _client.get(uri).timeout(requestTimeout);
    if (pastEndIsEmpty && res.statusCode == 404) {
      // Nyaa returns 404 when a valid HTML search asks past its final page.
      return null;
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

    // Nyaa 响应是 UTF-8 但常不声明 charset；必须严格解码，损坏字节不能被 U+FFFD
    // 替换后继续冒充有效结果。gzip 由 dart:io HttpClient 默认 autoUncompress
    // 解掉（createAppHttpClient 没有关它），这里拿到的已是明文字节。
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
    return body;
  }

  void close() => _client.close();
}

/// [NyaaClient.probeSite] 的结果。
class NyaaSiteProbe {
  const NyaaSiteProbe({required this.resultCount, required this.categories});

  /// 测试关键词搜到的条数（0 也算识别成功——页面结构对就行）。
  final int resultCount;

  /// 站点分类下拉里的全部选项（含「All categories」`0_0`）。
  final List<NyaaCategoryOption> categories;
}

/// Nyaa 式站点分类下拉的一个选项。
class NyaaCategoryOption {
  const NyaaCategoryOption({required this.value, required this.label});

  /// 分类号，形如 `1_0`（大类）/ `1_2`（子类）。
  final String value;

  /// 完整分类名，子类带父类前缀：`Anime`、`Software - Games`、`Art - Games`。
  final String label;

  /// 大类（`X_0`）。
  bool get isTopLevel => value.endsWith('_0');

  @override
  bool operator ==(Object other) =>
      other is NyaaCategoryOption &&
      other.value == value &&
      other.label == label;

  @override
  int get hashCode => Object.hash(value, label);

  @override
  String toString() => 'NyaaCategoryOption($value, $label)';
}

/// 从 Nyaa 式搜索页 HTML 里解析分类下拉（`<select name="c">`）。
///
/// 子类选项的**文本**只有缩进后的短名（`- Games`），完整名在 `title` 属性里
/// （`Software - Games`）；没有 `title` 时按分类号找父类拼出完整名。`0_0`
/// （All categories）与形状不对的值丢弃。页面没有下拉 → 空表。
List<NyaaCategoryOption> parseNyaaCategoryOptions(String html) {
  final html_dom.Document document = html_parser.parse(html);
  final html_dom.Element? select = document.querySelector('select[name="c"]');
  if (select == null) return const <NyaaCategoryOption>[];
  final RegExp valueShape = RegExp(r'^\d+_\d+$');
  final Map<String, String> topLevelLabels = <String, String>{};
  final List<NyaaCategoryOption> options = <NyaaCategoryOption>[];
  for (final html_dom.Element option in select.querySelectorAll('option')) {
    final String value = (option.attributes['value'] ?? '').trim();
    if (!valueShape.hasMatch(value) || value == '0_0') continue;
    final String text = _collapseSpaces(option.text);
    final String title = _collapseSpaces(option.attributes['title'] ?? '');
    final bool topLevel = value.endsWith('_0');
    String label;
    if (topLevel) {
      label = title.isNotEmpty ? title : text;
      topLevelLabels[value.split('_').first] = label;
    } else {
      final String parent = topLevelLabels[value.split('_').first] ?? '';
      final String shortName = text.replaceFirst(RegExp(r'^-\s*'), '');
      label = title.contains(' - ')
          ? title
          : parent.isNotEmpty && shortName.isNotEmpty
              ? '$parent - $shortName'
              : (title.isNotEmpty ? title : shortName);
    }
    if (label.isEmpty) continue;
    options.add(NyaaCategoryOption(value: value, label: label));
  }
  return List<NyaaCategoryOption>.unmodifiable(options);
}

String _collapseSpaces(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

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
  final List<html_dom.Element> rows =
      table.querySelectorAll('tbody tr').toList(growable: false);
  NyaaFeedFormatException? firstRowError;
  int skipped = 0;
  for (final html_dom.Element row in rows) {
    try {
      torrents.add(_parseNyaaHtmlRow(row, requestUri));
    } on NyaaFeedFormatException catch (error) {
      // 一行坏（缺 infohash / 链接）不该让整页失败（BUG-2794）：跳过它、记诊断，
      // 其余合法行照常交出去。只有**每一行都坏**才说明页面结构变了，那时仍抛，
      // 否则站点改版会被伪装成「0 条」。
      skipped += 1;
      firstRowError ??= error;
    }
  }
  if (firstRowError != null) {
    if (torrents.isEmpty) throw firstRowError;
    engineLog.logDiagnostic(
      'NyaaClient.search',
      'skipped $skipped of ${rows.length} malformed rows: '
          '${firstRowError.message}',
    );
  }
  return List<NyaaTorrent>.unmodifiable(torrents);
}

/// 解析一行搜索结果；缺必需字段抛 [NyaaFeedFormatException]。
NyaaTorrent _parseNyaaHtmlRow(html_dom.Element row, Uri requestUri) {
  final List<html_dom.Element> cells = row.children
      .where((html_dom.Element element) => element.localName == 'td')
      .toList(growable: false);
  if (cells.length < 5) {
    throw NyaaFeedFormatException(
      NyaaFeedErrorCode.missingStructure,
      'HTML torrent row has fewer than five cells',
    );
  }

  // 标题单元格里可能有两个 `/view/<id>` 链接：有评论的行，nyaa 模板会先
  // 写一个 `<a class="comments" href="/view/<id>#comments" title="N comments">`
  // 再写标题链接（CSS 右浮，DOM 顺序在前）。只认路径的话带评论的行标题
  // 会被抓成 `1 comment`，随后被系列名匹配整行丢掉（BUG-2523）。详情链接
  // 永远不带 fragment，按这个结构差异区分。
  final html_dom.Element? detailLink = cells[1]
      .querySelectorAll('a[href]')
      .cast<html_dom.Element?>()
      .firstWhere(
    (html_dom.Element? link) {
      final Uri? href = Uri.tryParse(link?.attributes['href'] ?? '');
      return href != null &&
          href.path.startsWith('/view/') &&
          href.fragment.isEmpty;
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
  return NyaaTorrent(
    title: title,
    torrentUrl: torrentUrl,
    pageUrl: requestUri.resolve(detailLink.attributes['href']!).toString(),
    infoHash: infoHash,
    seeders: cells.length > 5 ? int.tryParse(cells[5].text.trim()) ?? 0 : 0,
    leechers: cells.length > 6 ? int.tryParse(cells[6].text.trim()) ?? 0 : 0,
    downloads: cells.length > 7 ? int.tryParse(cells[7].text.trim()) ?? 0 : 0,
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
  );
}
