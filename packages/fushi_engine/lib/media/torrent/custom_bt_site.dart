/// 按用户导入的解析规则（[BtSiteParserRule]）搜索 / 解析的 BT 站：HTTP 客户端 +
/// 视频资源 provider。站点配置见 `bt_site_config.dart`（[BtSiteFormat.custom]）。
///
/// 安全边界：
/// * 所有请求（搜索页、详情页、种子文件）都过 [isSafeExternalProviderEndpoint]，
///   页面里抓到的链接不能把请求带去明文 HTTP / 非 http(s) 地址；
/// * 登录 Cookie 只发给站点自己的主机及其子域（`dl.<站点>` 这类下载子域），页面
///   里指向别的域的链接拿不到用户的登录态；重定向逐跳手动跟，每跳重新过安全闸门
///   和 Cookie 判定，不依赖底层 HTTP 实现自动跟时剥不剥 Cookie；
/// * 种子文件走 [inspectTorrentMetainfo] 校验（bencode + info hash），登录失效时站点
///   回的 HTML 登录页不会被当成种子交给下载引擎。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/anime_release_descriptor.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_parser_rule.dart';
import 'package:fushi_engine/media/torrent/download_timeouts.dart';
import 'package:fushi_engine/media/torrent/public_video_index_client.dart'
    show buildPublicVideoIndexMagnet, normalizePublicVideoIndexInfoHash;
import 'package:fushi_engine/media/torrent/public_video_index_provider.dart'
    show publicVideoIndexResult;
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 自定义规则站点的 provider id 前缀（= [BtSiteFormat.custom] 的 wire 名）。
const String kCustomBtSiteResourceProviderId = 'custom';

/// 规则从页面里抓出的一行。
class CustomBtSiteTorrent {
  const CustomBtSiteTorrent({
    required this.title,
    this.detailsUrl,
    this.magnet,
    this.torrentUrl,
    this.infoHash,
    this.sizeBytes,
    this.seeders = 0,
    this.leechers = 0,
  });

  final String title;
  final Uri? detailsUrl;

  /// `magnet:` 链接（原样，不改 tracker）。
  final String? magnet;
  final Uri? torrentUrl;

  /// 小写十六进制 infoHash（40 / 64 位）；页面没给为 null。
  final String? infoHash;
  final int? sizeBytes;
  final int seeders;
  final int leechers;

  /// 行内是否已有能直接交给下载引擎的东西。
  bool get hasDirectRoute =>
      magnet != null || torrentUrl != null || infoHash != null;

  CustomBtSiteTorrent copyWith({
    String? magnet,
    Uri? torrentUrl,
    String? infoHash,
  }) => CustomBtSiteTorrent(
    title: title,
    detailsUrl: detailsUrl,
    magnet: magnet ?? this.magnet,
    torrentUrl: torrentUrl ?? this.torrentUrl,
    infoHash: infoHash ?? this.infoHash,
    sizeBytes: sizeBytes,
    seeders: seeders,
    leechers: leechers,
  );
}

const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// infoHash 规范化：40 / 64 位十六进制，或 32 位 base32（磁链里的另一种写法）
/// 转十六进制；其余返回 null。
String? normalizeCustomBtSiteInfoHash(String? raw) {
  final String value = (raw ?? '').trim();
  if (value.isEmpty) return null;
  final String hex = normalizePublicVideoIndexInfoHash(value);
  if (hex.isNotEmpty) return hex;
  final String upper = value.toUpperCase();
  if (upper.length != 32) return null;
  int buffer = 0;
  int bits = 0;
  final StringBuffer out = StringBuffer();
  for (final int unit in upper.codeUnits) {
    final int index = _base32Alphabet.indexOf(String.fromCharCode(unit));
    if (index < 0) return null;
    buffer = (buffer << 5) | index;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.write(((buffer >> bits) & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    buffer &= (1 << bits) - 1;
  }
  return out.toString();
}

/// 磁链里的 `xt=urn:btih:<hash>`。
String? infoHashFromMagnet(String magnet) {
  final RegExpMatch? match = RegExp(
    r'xt=urn:btih:([0-9A-Za-z]+)',
    caseSensitive: false,
  ).firstMatch(magnet);
  return normalizeCustomBtSiteInfoHash(match?.group(1));
}

/// 按规则抓取一个站点的客户端。[baseUrl] 是站点 origin。
class CustomBtSiteClient {
  CustomBtSiteClient({
    required this.baseUrl,
    required this.rule,
    this.cookie = '',
    this.allowInsecureHttp = false,
    http.Client? client,
    this.requestTimeout = kDownloadDiscoveryTimeout,
  }) : _client = client ?? createAppHttpIoClient();

  final Uri baseUrl;
  final BtSiteParserRule rule;

  /// 用户贴的登录 Cookie（`name=value; name2=value2`）；空 = 匿名。
  final String cookie;
  final bool allowInsecureHttp;
  final Duration requestTimeout;
  final http.Client _client;

  /// Cookie 能不能发给 [url]：同主机或站点子域（去掉开头 `www.` 比）。
  bool cookieAllowedFor(Uri url) {
    String root(String host) =>
        host.toLowerCase().startsWith('www.') ? host.substring(4) : host;
    final String site = root(baseUrl.host.toLowerCase());
    final String host = url.host.toLowerCase();
    return root(host) == site || host.endsWith('.$site');
  }

  /// 一次抓取最多跟几跳重定向。
  static const int maxRedirects = 5;

  /// GET [url]，重定向由这里逐跳手动跟：每一跳都重新过安全闸门、重新判 Cookie
  /// 能不能带。不交给 HTTP 实现自动跟，是因为自动跟时 Cookie 头会不会被带到别的
  /// 域只取决于底层实现（`dart:io` 跨源时剥掉，别的实现未必），登录态不能押在这上面。
  Future<http.Response> _get(Uri url) async {
    Uri current = url;
    for (int hop = 0; ; hop++) {
      final http.Response res = await _getOnce(current);
      final String? location = res.headers['location'];
      if (!_isRedirect(res.statusCode) || location == null) {
        if (res.statusCode != 200) {
          throw http.ClientException('HTTP ${res.statusCode}', current);
        }
        return res;
      }
      if (hop >= maxRedirects) {
        throw http.ClientException('too many redirects', url);
      }
      current = current.resolve(location);
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// 单跳请求：不自动跟重定向，3xx 原样返回给 [_get]。
  Future<http.Response> _getOnce(Uri url) async {
    if ((url.scheme != 'http' && url.scheme != 'https') ||
        !isSafeExternalProviderEndpoint(
          url,
          allowInsecureHttp: allowInsecureHttp,
        )) {
      throw ExternalProviderFailure(
        providerId: kCustomBtSiteResourceProviderId,
        operation: 'fetch',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'refusing to fetch an unsafe URL',
      );
    }
    final http.Request request = http.Request('GET', url)
      ..followRedirects = false;
    if (cookie.trim().isNotEmpty && cookieAllowedFor(url)) {
      request.headers['Cookie'] = cookie.trim();
    }
    final http.StreamedResponse streamed = await _client
        .send(request)
        .timeout(requestTimeout);
    return http.Response.fromStream(streamed).timeout(requestTimeout);
  }

  /// 搜索页地址（[domain] 只在模板含 `{category}` 时需要）。
  Uri searchUrl(String query, {BtSiteDomain? domain}) =>
      baseUrl.resolve(rule.searchPathFor(query, domain: domain));

  /// 按关键词搜一页。网络错误 / 非 200 原样抛（provider 归入 failures）。
  Future<List<CustomBtSiteTorrent>> search(
    String query, {
    BtSiteDomain? domain,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(query, 'query');
    final Uri url = searchUrl(trimmed, domain: domain);
    final http.Response res = await _get(url);
    return parseSearchPage(rule.encoding.decode(res.bodyBytes), pageUrl: url);
  }

  /// 搜索页 HTML → 行。没有标题、或既没有行内下载路线也走不了详情页的行丢弃。
  List<CustomBtSiteTorrent> parseSearchPage(
    String body, {
    required Uri pageUrl,
  }) {
    final html_dom.Document document = html_parser.parse(body);
    final List<CustomBtSiteTorrent> results = <CustomBtSiteTorrent>[];
    for (final html_dom.Element row in document.querySelectorAll(rule.rows)) {
      final String? title = rule.title.extract(row);
      if (title == null) continue;
      final Uri? details = _link(rule.details?.extract(row), pageUrl);
      final String? magnet = _magnet(rule.magnet?.extract(row));
      final Uri? torrentUrl = _link(rule.torrent?.extract(row), pageUrl);
      final String? hash =
          normalizeCustomBtSiteInfoHash(rule.infoHash?.extract(row)) ??
          (magnet == null ? null : infoHashFromMagnet(magnet));
      final CustomBtSiteTorrent torrent = CustomBtSiteTorrent(
        title: title,
        detailsUrl: details,
        magnet: magnet,
        torrentUrl: torrentUrl,
        infoHash: hash,
        sizeBytes: parseBtSiteHumanSize(rule.size?.extract(row)),
        seeders: parseBtSiteCount(rule.seeders?.extract(row)),
        leechers: parseBtSiteCount(rule.leechers?.extract(row)),
      );
      if (!torrent.hasDirectRoute &&
          !(rule.hasDetailRoute && details != null)) {
        continue;
      }
      results.add(torrent);
    }
    return results;
  }

  /// 进详情页补磁链 / 种子地址 / infoHash（行内已有的不覆盖）。
  Future<CustomBtSiteTorrent> resolveDetails(
    CustomBtSiteTorrent torrent,
  ) async {
    final Uri? details = torrent.detailsUrl;
    if (details == null || !rule.hasDetailRoute) return torrent;
    final http.Response res = await _get(details);
    final html_dom.Document document = html_parser.parse(
      rule.encoding.decode(res.bodyBytes),
    );
    final html_dom.Element? root = document.documentElement;
    if (root == null) return torrent;
    final String? magnet = _magnet(rule.detailMagnet?.extract(root));
    final Uri? torrentUrl = _link(rule.detailTorrent?.extract(root), details);
    final String? hash =
        normalizeCustomBtSiteInfoHash(rule.detailInfoHash?.extract(root)) ??
        (magnet == null ? null : infoHashFromMagnet(magnet));
    return torrent.copyWith(
      magnet: torrent.magnet ?? magnet,
      torrentUrl: torrent.torrentUrl ?? torrentUrl,
      infoHash: torrent.infoHash ?? hash,
    );
  }

  /// 下载种子文件并校验（登录失效时站点回 HTML，这里抛 [TorrentMetainfoException]）。
  Future<InspectedTorrentMetainfo> downloadTorrent(
    Uri url, {
    String? expectedInfoHash,
  }) async {
    final http.Response res = await _get(url);
    return inspectTorrentMetainfo(
      Uint8List.fromList(res.bodyBytes),
      expectedInfoHash: expectedInfoHash,
    );
  }

  /// 添加站点时验证规则：用 [BtSiteParserRule.testQuery] 搜一次，返回行数。
  /// 规则含 `{category}` 时用第一个有映射的视频域。
  Future<int> verifyRule() async {
    final BtSiteDomain? domain = rule.usesCategory
        ? kBtSiteParserDomains.firstWhere(rule.categories.containsKey)
        : null;
    final List<CustomBtSiteTorrent> rows = await search(
      rule.testQuery,
      domain: domain,
    );
    return rows.length;
  }

  Uri? _link(String? raw, Uri pageUrl) {
    if (raw == null) return null;
    final Uri? parsed = Uri.tryParse(raw);
    if (parsed == null) return null;
    final Uri resolved = pageUrl.resolveUri(parsed);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    return resolved;
  }

  String? _magnet(String? raw) {
    if (raw == null) return null;
    final String value = raw.trim();
    return value.toLowerCase().startsWith('magnet:?') ? value : null;
  }

  void close() => _client.close();
}

/// 自定义规则站点的候选行。
class CustomBtSiteCandidate extends VideoResourceCandidate {
  CustomBtSiteCandidate({
    required this.torrent,
    required String siteId,
    required int providerPriority,
  }) : super(
         providerId: kCustomBtSiteResourceProviderId,
         providerInstanceId: siteId,
         remoteId:
             torrent.infoHash ??
             torrent.detailsUrl?.toString() ??
             torrent.torrentUrl?.toString() ??
             torrent.title,
         title: torrent.title,
         providerPriority: providerPriority,
         infoHash: torrent.infoHash,
         sizeBytes: torrent.sizeBytes,
         seeders: torrent.seeders,
         leechers: torrent.leechers,
         resolution: parseAnimeReleaseDescriptor(torrent.title).resolution,
         releaseGroup: parseAnimeReleaseDescriptor(torrent.title).releaseGroup,
         detailsUrl: torrent.detailsUrl?.toString(),
         magnetUri: torrent.magnet,
       );

  final CustomBtSiteTorrent torrent;
}

/// 用户按解析规则添加的 BT 站的资源 provider（只服务规则覆盖的视频域）。
class CustomBtSiteVideoResourceProvider
    implements LabeledVideoResourceProvider {
  CustomBtSiteVideoResourceProvider({
    required CustomBtSiteClient client,
    required this.siteId,
    required Set<VideoDiscoveryCategory> categories,
    String? displayName,
    this.priority = 400,
    bool closesClient = false,
  }) : _client = client,
       _closesClient = closesClient,
       categories = Set<VideoDiscoveryCategory>.unmodifiable(categories),
       displayName = displayName ?? client.baseUrl.host;

  final CustomBtSiteClient _client;
  final String siteId;
  final bool _closesClient;

  @override
  final String displayName;

  @override
  final Set<VideoDiscoveryCategory> categories;

  @override
  final int priority;

  @override
  String get id => '$kCustomBtSiteResourceProviderId:$siteId';

  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async {
    final String query = request.effectiveQuery.trim();
    if (query.isEmpty) {
      return ProviderBatchResult<VideoResourceCandidate>(
        items: const <VideoResourceCandidate>[],
      );
    }
    final VideoDiscoveryCategory category =
        request.media?.discoveryCategory ?? categories.first;
    try {
      final List<CustomBtSiteTorrent> rows = await _client.search(
        query,
        domain: _client.rule.usesCategory
            ? BtSiteDomain.fromVideoCategory(category)
            : null,
      );
      return publicVideoIndexResult(
        providerId: id,
        query: query,
        items: deduplicateVideoResources(
          rows.map(
            (CustomBtSiteTorrent torrent) => CustomBtSiteCandidate(
              torrent: torrent,
              siteId: siteId,
              providerPriority: priority,
            ),
          ),
        ).take(request.limit).toList(),
      );
    } on Object catch (error) {
      return publicVideoIndexResult(
        providerId: id,
        query: query,
        failure: ExternalProviderFailure.fromException(
          providerId: id,
          operation: 'search',
          error: error,
        ),
      );
    }
  }

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async {
    if (candidate is! CustomBtSiteCandidate ||
        candidate.providerInstanceId != siteId) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'resolve',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    CustomBtSiteTorrent torrent = candidate.torrent;
    if (torrent.magnet == null && torrent.torrentUrl == null) {
      torrent = await _client.resolveDetails(torrent);
    }
    if (torrent.magnet case final String magnet) {
      return TorrentMagnetPayload(
        magnetUri: magnet,
        torrentId: torrent.infoHash ?? infoHashFromMagnet(magnet),
      );
    }
    if (torrent.torrentUrl case final Uri url) {
      final InspectedTorrentMetainfo meta = await _client.downloadTorrent(
        url,
        expectedInfoHash: torrent.infoHash,
      );
      return meta.toPayload(fileName: '${meta.torrentId}.torrent');
    }
    if (torrent.infoHash case final String hash) {
      return TorrentMagnetPayload(
        magnetUri: buildPublicVideoIndexMagnet(
          infoHash: hash,
          displayName: torrent.title,
        ),
        torrentId: hash,
      );
    }
    throw ExternalProviderFailure(
      providerId: id,
      operation: 'resolve',
      kind: ExternalProviderFailureKind.notFound,
      message: 'the parser rule found no magnet, torrent or info hash',
    );
  }

  @override
  void close() {
    if (_closesClient) _client.close();
  }
}
