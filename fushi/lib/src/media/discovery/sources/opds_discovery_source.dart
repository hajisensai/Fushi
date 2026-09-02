/// OPDS 目录的发现源 adapter：一个实例 = 一台用户自己配的 OPDS 服务器
/// （BookOrbit / Calibre-Web / Komga / Kavita / 任意 OPDS 服务端）。
///
/// 与内置源不同，OPDS 源**没有内置站点**——地址、账号、密码全部来自用户配置
/// （`OpdsServerConfig`），实例由 `AppModel` 在装配期按配置逐条构造。
///
/// ## 双协议
///
/// 1.2（Atom XML）与 2.0（JSON）都支持，靠**响应体嗅探**分流而不是
/// `Content-Type`：实测自建服务端把 OPDS feed 标成 `text/xml`、
/// `application/xml`、甚至 `text/html` 的都有，而首个非空白字符是 `<` 还是 `{`
/// 是无歧义的。Content-Type 只作为嗅探不出结论时的提示。
///
/// ## 分页
///
/// OPDS 的分页是**链接驱动**（服务端在 feed 里给 `rel="next"` 的绝对地址），
/// 不是页码驱动——自己拼 `?page=N` 在多数服务端上无效或语义不同。而
/// `DiscoveryRequest` 是页码语义，两者靠 [_pageUrls] 搭桥：取完第 N 页就把
/// 它的 next 记到第 N+1 页名下。发现页的翻页恒为顺序（page 1 →「加载更多」→
/// page 2，路径一变就重置回 1），所以正常路径上永远命中缓存；缓存不命中时
/// 从首页起有界回走，而不是拼一个假 URL 打过去。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_atom_parser.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_feed.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_json_parser.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/utils/net/app_http.dart';

/// 源 id 的前缀。持久化的「停用源清单」按 id 存，改前缀即断档。
const String kOpdsSourceIdPrefix = 'opds-';

/// 由服务器配置 id 推出稳定源 id。
String opdsSourceIdFor(String configId) => '$kOpdsSourceIdPrefix$configId';

/// 回走分页时最多走多少页——防止服务端把 `next` 指成自环时无限请求。
const int _kMaxPageWalk = 50;

class OpdsDiscoverySource extends MediaDiscoverySource {
  OpdsDiscoverySource({
    required this.config,
    this.priority = 30,
    http.Client? client,
  }) : _client = client ?? createAppHttpIoClient();

  final OpdsServerConfig config;

  @override
  String get id => opdsSourceIdFor(config.id);

  /// 走 [OpdsServerConfig.displayName]（空名回退主机名），**不是**裸 `config.name`：
  /// 显示名是选填的（`discovery_opds_name_hint` 明写「留空则使用主机名」），
  /// 而本 getter 的消费方是设置里的源开关列表与发现页来源下拉——裸取 name 会让
  /// 只填了 URL 的服务器在那两处渲染成一行**空标题**，而漫画卡片那边用的是
  /// `displayName`，同一台服务器在不同页面显示还不一致。
  @override
  String get displayName => config.displayName;

  @override
  final int priority;

  /// 地址/账号全部来自用户配置，开关是 `OpdsServerConfig.enabled`。
  @override
  bool get isUserConfigured => true;

  final http.Client _client;

  /// `'<feed 地址>#<页码>'` → 该页的真实请求 URL。见库文档注释的「分页」。
  final Map<String, String> _pageUrls = <String, String>{};

  /// 搜索模板探测结果。null = **还没探过**；非 null 但 [_SearchProbe.template]
  /// 为 null = 探过且该服务器确实不提供搜索。
  ///
  /// 刻意用一个可空的结果对象而不是「`String? template` + `bool probed`」两份
  /// 状态：那样两份一旦不同步就会出现「一次网络抖动导致本会话再也搜不了」，
  /// 而失败恰恰是最该重试的情形（同 AList 源 `_basePath` 的取舍）。
  _SearchProbe? _searchProbe;

  @override
  DiscoveryCapabilities get capabilities => DiscoveryCapabilities(
        // 一台 OPDS 服务器可能同时供书和漫画；具体条目按 acquisition 链接的
        // MIME 定域（见 OpdsFileType），而不是靠源声明去猜。
        kinds: const <DiscoveryMediaKind>{
          DiscoveryMediaKind.novel,
          DiscoveryMediaKind.manga,
        },
        supportsSearch: true,
        supportsBrowse: true,
        supportsPaging: true,
      );

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    final String feedPath = request.path ?? config.catalogUrl.toString();
    final String pageUrl = await _urlForPage(feedPath, request.page);
    final OpdsFeed feed = await _loadFeed(Uri.parse(pageUrl));
    _rememberNext(feedPath, request.page, feed.nextHref);
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[_toPage(feed, request)],
    );
  }

  @override
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  ) async {
    final String? template = await _ensureSearchTemplate();
    if (template == null) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'search',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'server does not advertise an OPDS search endpoint',
      );
    }
    final String searchUrl = template.replaceAll(
      '{searchTerms}',
      Uri.encodeQueryComponent(request.query!.trim()),
    );
    final String pageUrl = await _urlForPage(searchUrl, request.page);
    final OpdsFeed feed = await _loadFeed(Uri.parse(pageUrl));
    _rememberNext(searchUrl, request.page, feed.nextHref);
    return ProviderBatchResult<DiscoveryResultPage>.success(
      <DiscoveryResultPage>[_toPage(feed, request)],
    );
  }

  /// OPDS 的 acquisition 链接是稳定地址（不像 AList 的 `raw_url` 带临期签名），
  /// 所以 payload 在列表阶段就物化好随条目带走，不需要延迟 resolve。
  /// 基类默认实现（直接返回 `item.payload`）正是要的行为，故不覆写。

  /// 把一页 feed 转成请求域下的结果页。
  ///
  /// 出版物按 acquisition 链接的 MIME **过滤到请求域**：在「小说」页里列出
  /// 只有 .cbz 的条目，点下载必然以导入失败收场。导航条目恒保留——一个目录
  /// 里装什么要点进去才知道，按当前域把目录藏掉会让整棵树看着是空的。
  DiscoveryResultPage _toPage(OpdsFeed feed, DiscoveryRequest request) {
    final List<DiscoveryEntry> entries = <DiscoveryEntry>[];
    for (final OpdsEntry entry in feed.entries) {
      switch (entry) {
        case OpdsNavigationEntry():
          entries.add(
            DiscoveryFolder(
              sourceId: id,
              title: entry.title,
              path: entry.href,
              note: entry.summary,
              itemCount: entry.itemCount,
            ),
          );
        case OpdsPublicationEntry():
          final OpdsAcquisitionLink? link = entry.bestLinkFor(request.kind);
          if (link == null) continue;
          entries.add(
            DiscoveryResourceItem(
              sourceId: id,
              id: entry.id,
              title: entry.title,
              kind: request.kind,
              payloadKind: DiscoveryPayloadKind.httpFile,
              payload: DiscoveryHttpPayload(
                url: link.href,
                headers: _headersFor(Uri.parse(link.href)),
                // 下载队列不读 Content-Disposition，而 OPDS 直链普遍无扩展名
                // （`/opds/download/1234`）。不在这里给出带扩展名的文件名，
                // 落盘就是个无后缀文件，分类器一律判 unknownFileType——
                // 表现为「下到 100% 然后导入失败」。
                fileName: _fileNameFor(entry.title, link),
                sizeBytes: link.sizeBytes,
              ),
              sizeBytes: link.sizeBytes,
              dateText: entry.updatedText,
              coverUrl: entry.coverHref,
              note: entry.author,
            ),
          );
      }
    }
    return DiscoveryResultPage(
      entries: entries,
      page: request.page,
      hasMore: feed.nextHref != null,
    );
  }

  /// 由标题 + 链接类型拼出带正确扩展名的落盘文件名。
  ///
  /// 认不出类型时**不编造扩展名**：给个错的（比如一律 `.epub`）会让 zip 壳的
  /// cbz 被当 EPUB 解析并以一个看不懂的报错收场，不如让它按未知类型失败。
  static String _fileNameFor(String title, OpdsAcquisitionLink link) {
    final String base = title.trim().isEmpty ? 'download' : title.trim();
    final OpdsFileType? type = link.fileType;
    if (type == null) return base;
    if (base.toLowerCase().endsWith(type.extension)) return base;
    return '$base${type.extension}';
  }

  /// 取第 [page] 页的真实请求 URL。第 1 页恒为 [feedPath] 本身。
  Future<String> _urlForPage(String feedPath, int page) async {
    if (page <= 1) return feedPath;
    final String? cached = _pageUrls['$feedPath#$page'];
    if (cached != null) return cached;
    // 缓存不命中（跨会话恢复、用户直接跳页）：从首页起顺着 next 有界回走。
    String current = feedPath;
    for (int walked = 1; walked < page; walked++) {
      if (walked > _kMaxPageWalk) {
        // 走到上限**必须抛**，不能 break 后把手上这一页当成 [page] 返回——
        // 那样用户拿到的是第 51 页的内容、标签却写着第 [page] 页，而且
        // `_toPage` 会把这个错页码原样填进 `DiscoveryResultPage.page`。
        // 语义与下面「next 为 null」那条一致：走不到就说走不到。
        throw ExternalProviderFailure(
          providerId: id,
          operation: 'browse',
          kind: ExternalProviderFailureKind.notFound,
          message: 'page is too deep to reach by walking next links',
        );
      }
      final OpdsFeed feed = await _loadFeed(Uri.parse(current));
      final String? next = feed.nextHref;
      _rememberNext(feedPath, walked, next);
      if (next == null) {
        throw ExternalProviderFailure(
          providerId: id,
          operation: 'browse',
          kind: ExternalProviderFailureKind.notFound,
          message: 'requested page is past the end of the catalog',
        );
      }
      current = next;
    }
    return current;
  }

  void _rememberNext(String feedPath, int page, String? nextHref) {
    if (nextHref == null) return;
    _pageUrls['$feedPath#${page + 1}'] = nextHref;
  }

  /// 抓一页 feed 并按响应体嗅探分流到 1.2 / 2.0 解析器。
  Future<OpdsFeed> _loadFeed(Uri uri) async {
    final _OpdsResponse response = await _get(uri, operation: 'browse');
    final String body = response.body.trimLeft();
    if (body.isEmpty) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'browse',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'server returned an empty catalog response',
      );
    }
    try {
      // 嗅探优先于 Content-Type：自建服务端把 OPDS feed 标成 text/xml、
      // application/xml、text/html 的都实测存在，而首字符是无歧义的。
      if (body.startsWith('{') || body.startsWith('[')) {
        return parseOpdsJsonFeed(body, baseUri: uri);
      }
      if (body.startsWith('<')) {
        return parseOpdsAtomFeed(body, baseUri: uri);
      }
      // 首字符没结论时才退回 Content-Type。
      if (response.contentType.contains('json')) {
        return parseOpdsJsonFeed(body, baseUri: uri);
      }
      return parseOpdsAtomFeed(body, baseUri: uri);
    } on ExternalProviderFailure {
      rethrow;
    } catch (_) {
      // 解析异常一律收敛成脱敏失败：原始异常里可能带 feed 片段。
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'browse',
        kind: ExternalProviderFailureKind.invalidResponse,
        message: 'response is not a readable OPDS catalog',
      );
    }
  }

  /// 探测搜索模板：先看根 feed 的 `rel="search"`，是 OpenSearch 描述文档
  /// 就再抓一次把模板取出来。
  Future<String?> _ensureSearchTemplate() async {
    final _SearchProbe? probed = _searchProbe;
    if (probed != null) return probed.template;

    final OpdsFeed root = await _loadFeed(config.catalogUrl);
    if (root.searchTemplate != null) {
      _searchProbe = _SearchProbe(root.searchTemplate);
      return root.searchTemplate;
    }
    final String? descriptionHref = root.searchDescriptionHref;
    if (descriptionHref == null) {
      _searchProbe = const _SearchProbe(null); // 有结论：该服务器不提供搜索
      return null;
    }
    final Uri descriptionUri = Uri.parse(descriptionHref);
    final _OpdsResponse response =
        await _get(descriptionUri, operation: 'search');
    try {
      final String? template = parseOpenSearchTemplate(
        response.body,
        baseUri: descriptionUri,
      );
      _searchProbe = _SearchProbe(template);
      return template;
    } catch (_) {
      // 描述文档取回来了但读不懂：**不**记结论，下次重探。
      // 记成「不支持搜索」会让一次畸形响应永久关掉这台服务器的搜索。
      return null;
    }
  }

  Future<_OpdsResponse> _get(Uri uri, {required String operation}) async {
    final http.Response response = await _client.get(
      uri,
      headers: <String, String>{
        'Accept': 'application/atom+xml, $kOpdsJsonMediaType, '
            'application/xml;q=0.8, */*;q=0.5',
        ..._headersFor(uri),
      },
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: operation,
        kind: response.statusCode == 401
            ? ExternalProviderFailureKind.unauthorized
            : ExternalProviderFailureKind.forbidden,
        message: 'server rejected the configured credentials',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode == 404) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: operation,
        kind: ExternalProviderFailureKind.notFound,
        message: 'catalog endpoint not found',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: operation,
        kind: ExternalProviderFailureKind.unavailable,
        message: 'http status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return _OpdsResponse(
      body: utf8.decode(response.bodyBytes, allowMalformed: true),
      contentType: (response.headers['content-type'] ?? '').toLowerCase(),
    );
  }

  /// 只给**配置服务器自己的 origin** 附认证头。
  ///
  /// feed 里的链接可以指向任意主机（封面挂 CDN、下载重定向到对象存储都常见）。
  /// 无差别附上 `Authorization` 会把用户的 OPDS 密码送给第三方主机——这与
  /// 浏览器和 curl 的既定行为一致：凭据绑定 origin，不跟着链接走。
  Map<String, String> _headersFor(Uri target) {
    final String? header = config.authorizationHeader;
    if (header == null) return const <String, String>{};
    if (!isSameOpdsOrigin(config.catalogUrl, target)) {
      return const <String, String>{};
    }
    return <String, String>{'Authorization': header};
  }

  @override
  void close() => _client.close();
}

/// 同源判据：scheme + host + 端口（含默认端口归一）全等。
bool isSameOpdsOrigin(Uri a, Uri b) =>
    a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    _port(a) == _port(b);

int _port(Uri uri) {
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme.toLowerCase()) {
    'https' => 443,
    'http' => 80,
    _ => 0,
  };
}

class _OpdsResponse {
  const _OpdsResponse({required this.body, required this.contentType});

  final String body;
  final String contentType;
}

/// 搜索能力探测的**结论**。存在即代表探过了；[template] 为 null 代表
/// 探过且确实没有搜索端点。
class _SearchProbe {
  const _SearchProbe(this.template);

  final String? template;
}
