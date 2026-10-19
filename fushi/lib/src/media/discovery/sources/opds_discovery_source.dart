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
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_atom_parser.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_feed.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_json_parser.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/utils/net/redirect_headers.dart';

/// 源 id 的前缀。持久化的「停用源清单」按 id 存，改前缀即断档。
const String kOpdsSourceIdPrefix = 'opds-';

/// 由服务器配置 id 推出稳定源 id。
String opdsSourceIdFor(String configId) => '$kOpdsSourceIdPrefix$configId';

/// 回走分页时最多走多少页——防止服务端把 `next` 指成自环时无限请求。
const int _kMaxPageWalk = 50;

/// 单次 feed / OpenSearch 请求的**总**时限（连接 + 响应体读完）。
///
/// `createAppHttpIoClient()` 只给了**连接**超时，响应体读取是无限期的：一台
/// slow-loris 服务端（连上、每隔一会儿吐一个字节）能让发现页那一栏永久转圈，
/// 而 [_kMaxPageWalk] 的回走会把它放大成 50 次串行。
const Duration kOpdsRequestTimeout = Duration(seconds: 30);

/// 两个数据块之间的最长静默。连上之后一个字节都不发是最常见的挂死形态，
/// 单靠总时限要等满 [kOpdsRequestTimeout] 才收手。
const Duration kOpdsIdleTimeout = Duration(seconds: 15);

/// feed / OpenSearch 描述文档的响应体字节上限。
///
/// OPDS 目录是分页的，一页几百 KB 已经算大。没有上限的话一条 chunked 响应就能
/// 把内存吃光——响应体先整份进 `bodyBytes`，`utf8.decode` 再复制一份。
const int kOpdsMaxFeedBytes = 8 * 1024 * 1024;

class OpdsDiscoverySource extends MediaDiscoverySource {
  OpdsDiscoverySource({
    required this.config,
    this.priority = 30,
    http.Client? client,
    this.requestTimeout = kOpdsRequestTimeout,
    this.idleTimeout = kOpdsIdleTimeout,
    this.maxFeedBytes = kOpdsMaxFeedBytes,
    this.onCatalogUrlResolved,
  }) : _client = client ?? createAppHttpIoClient();

  /// 用户填的地址不是目录、而按已知端点探测打通了另一条时回调（BUG-3519），
  /// 由装配方把打通的地址写回配置——下次冷启动不必再探测一遍。
  final void Function(Uri resolved)? onCatalogUrlResolved;

  /// 单次请求总时限 / 块间静默上限 / 响应体字节上限。默认即同名常量；
  /// 参数化只为让「挂死的服务端」在测试里能在毫秒级复现，生产路径不传。
  final Duration requestTimeout;
  final Duration idleTimeout;
  final int maxFeedBytes;

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

  /// 本会话里确认能读出目录的根地址；null = 还没打通过。路径里带 key 的端点
  /// 存的是占位形态（[kOpdsApiKeyPlaceholder]），不含 key 明文。
  ///
  /// 与 [_searchProbe] 同一取舍：只缓存**成功**结论，失败下次重探——一次网络
  /// 抖动不该让本会话永远停在「不是 OPDS 地址」。
  Uri? _resolvedCatalogUrl;

  /// 本会话确认可用的目录根地址（还没成功取过根目录时为 null）。
  Uri? get resolvedCatalogUrl => _resolvedCatalogUrl;

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
    final String? path = request.path;
    final String feedPath;
    final OpdsFeed feed;
    if (path == null && request.page <= 1) {
      // 根目录第一页：顺带完成地址探测（用户可能填的是服务端根 / 网页地址）。
      final (Uri root, OpdsFeed rootFeed) = await _loadRootFeed();
      feedPath = root.toString();
      feed = rootFeed;
    } else {
      // 根目录翻页只需要根**地址**做分页缓存的键与回走起点：已打通过就直接用，
      // 不再为拿一个 URL 把根 feed 整页再请求一遍（否则每翻一页多一次请求）。
      // 本会话还没打通过（跨会话恢复到第 N 页）才走一次探测。
      feedPath =
          path ??
          (_resolvedCatalogUrl ?? (await _loadRootFeed()).$1).toString();
      final String pageUrl = await _urlForPage(feedPath, request.page);
      feed = await _loadFeed(Uri.parse(pageUrl));
    }
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
                headers: _headersFor(link.href),
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
              // 私有目录的封面同样要凭据（Komga 无凭据回 401，BUG-3520）；
              // 与下载同一个同源判据，跨 origin 的封面（CDN）拿到的是空表。
              coverHeaders: entry.coverHref == null
                  ? null
                  : _headersFor(entry.coverHref!),
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
  ///
  /// [feedUri] 可能是带 API key 占位段的配置 / 候选地址（Kavita，见
  /// [kOpdsApiKeyPlaceholder]）：只在这里展开成真 key 发请求，展开后的地址
  /// 不外传——分页缓存键、`resolvedCatalogUrl`、写回回调拿到的都是占位形态。
  Future<OpdsFeed> _loadFeed(Uri feedUri) async {
    final Uri uri = expandOpdsApiKeyPlaceholder(feedUri, config.apiKey);
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
      // 解析不了且长得像网页：多半是填了服务端的网页地址（Komga 根地址回 200
      // text/html）。单独一种失败，让 UI 能说清「这是网页不是 OPDS 地址」。
      if (_looksLikeHtml(body, response.contentType)) {
        throw OpdsWebPageFailure(providerId: id, operation: 'browse');
      }
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

    final OpdsFeed root = (await _loadRootFeed()).$2;
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
    final _OpdsResponse response = await _get(
      descriptionUri,
      operation: 'search',
    );
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
    final DateTime deadline = DateTime.now().add(requestTimeout);
    // 重定向逐跳手动跟随，每跳按目标 origin 重算凭据头：`X-API-Key` 不在
    // dart:io 自动跟随会剥的那张清单里（见 redirect_headers.dart），交给自动
    // 跟随的话一个指向第三方的 302 就会把 API key 带出去。
    Uri current = uri;
    http.StreamedResponse response;
    for (int hop = 0; ; hop++) {
      final http.Request request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(<String, String>{
          'Accept':
              'application/atom+xml, $kOpdsJsonMediaType, '
              'application/xml;q=0.8, */*;q=0.5',
          ..._headersFor(current.toString()),
        });
      try {
        response = await _client.send(request).timeout(requestTimeout);
      } on TimeoutException {
        throw _timedOut(operation);
      }
      final String? location = response.headers['location'];
      if (!isFollowableRedirectStatus(response.statusCode) ||
          location == null ||
          location.trim().isEmpty) {
        break;
      }
      unawaited(response.stream.listen(null).cancel());
      if (hop >= kMaxManualRedirects) {
        throw ExternalProviderFailure(
          providerId: id,
          operation: operation,
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'too many redirects',
          statusCode: response.statusCode,
        );
      }
      current = current.resolve(location.trim());
    }
    final ExternalProviderFailure? rejected = _statusFailure(
      response.statusCode,
      operation,
    );
    if (rejected != null) {
      // 不读的响应体会把连接一直挂着——显式取消订阅才是「关掉它」。
      unawaited(response.stream.listen(null).cancel());
      throw rejected;
    }
    return _OpdsResponse(
      body: utf8.decode(
        await _readBounded(response.stream, operation, deadline),
        allowMalformed: true,
      ),
      contentType: (response.headers['content-type'] ?? '').toLowerCase(),
    );
  }

  /// 非 200 的状态码 → 稳定失败码；200 返回 null。
  ExternalProviderFailure? _statusFailure(int status, String operation) =>
      switch (status) {
        200 => null,
        401 => ExternalProviderFailure(
          providerId: id,
          operation: operation,
          kind: ExternalProviderFailureKind.unauthorized,
          message: 'server rejected the configured credentials',
          statusCode: status,
        ),
        403 => ExternalProviderFailure(
          providerId: id,
          operation: operation,
          kind: ExternalProviderFailureKind.forbidden,
          message: 'server rejected the configured credentials',
          statusCode: status,
        ),
        404 => ExternalProviderFailure(
          providerId: id,
          operation: operation,
          kind: ExternalProviderFailureKind.notFound,
          message: 'catalog endpoint not found',
          statusCode: status,
        ),
        _ => ExternalProviderFailure(
          providerId: id,
          operation: operation,
          kind: ExternalProviderFailureKind.unavailable,
          message: 'http status $status',
          statusCode: status,
        ),
      };

  /// 读响应体，三条边界同时管着：块间静默 [kOpdsIdleTimeout]、总时限
  /// [deadline]、字节上限 [kOpdsMaxFeedBytes]。任何一条越界都从 `await for`
  /// 里抛出去——抛出即取消订阅，连接随之关掉，不会留一条挂死的 socket。
  Future<List<int>> _readBounded(
    Stream<List<int>> stream,
    String operation,
    DateTime deadline,
  ) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    try {
      await for (final List<int> chunk in stream.timeout(idleTimeout)) {
        if (DateTime.now().isAfter(deadline)) throw _timedOut(operation);
        builder.add(chunk);
        if (builder.length > maxFeedBytes) {
          throw ExternalProviderFailure(
            providerId: id,
            operation: operation,
            kind: ExternalProviderFailureKind.invalidResponse,
            message: 'catalog response exceeds $maxFeedBytes bytes',
          );
        }
      }
    } on TimeoutException {
      throw _timedOut(operation);
    }
    return builder.takeBytes();
  }

  ExternalProviderFailure _timedOut(String operation) =>
      ExternalProviderFailure(
        providerId: id,
        operation: operation,
        kind: ExternalProviderFailureKind.unavailable,
        message: 'catalog request timed out',
      );

  /// 只给**配置服务器自己的 origin** 附认证头（Basic 与 `X-API-Key`）。
  /// 判据唯一实现在 [OpdsServerConfig.credentialHeadersFor]；feed 请求、下载
  /// payload 与封面三条链路都走这里。
  Map<String, String> _headersFor(String target) {
    final Uri? uri = Uri.tryParse(target);
    if (uri == null) return const <String, String>{};
    return config.credentialHeadersFor(uri);
  }

  /// 取根目录，必要时按已知端点探测（BUG-3519）。返回打通的根地址与该页 feed。
  ///
  /// 只有「地址不对」类失败（404、网页、读不出 OPDS）才继续试下一个候选；
  /// 401/403/超时/连不上都是**这台服务器本身**的结论，原样抛出——在一台密码
  /// 错了的服务器上挨个试十几条路径只会把同一个 401 拖慢十几倍。全部候选都
  /// 不对时抛**用户原地址**的那个失败：它描述的是用户实际填的东西。
  Future<(Uri, OpdsFeed)> _loadRootFeed() async {
    final Uri? known = _resolvedCatalogUrl;
    if (known != null) return (known, await _loadFeed(known));
    ExternalProviderFailure? firstFailure;
    for (final Uri candidate in opdsCatalogUrlCandidates(
      config.catalogUrl,
      apiKey: config.apiKey,
    )) {
      try {
        final OpdsFeed feed = await _loadFeed(candidate);
        _resolvedCatalogUrl = candidate;
        if (candidate.toString() != config.catalogUrl.toString()) {
          onCatalogUrlResolved?.call(candidate);
        }
        return (candidate, feed);
      } on ExternalProviderFailure catch (failure) {
        firstFailure ??= failure;
        if (!_isWrongAddressFailure(failure)) rethrow;
      }
    }
    throw firstFailure!;
  }

  static bool _isWrongAddressFailure(ExternalProviderFailure failure) =>
      failure.kind == ExternalProviderFailureKind.notFound ||
      failure.kind == ExternalProviderFailureKind.invalidResponse;

  /// 响应像网页：Content-Type 标 HTML，或正文以 `<!doctype html` / `<html` 开头。
  static bool _looksLikeHtml(String body, String contentType) {
    if (contentType.contains('text/html') ||
        contentType.contains('application/xhtml')) {
      return true;
    }
    final String head = (body.length > 64 ? body.substring(0, 64) : body)
        .toLowerCase();
    return head.startsWith('<!doctype html') || head.startsWith('<html');
  }

  @override
  void close() => _client.close();
}

/// 同源判据：scheme + host + 端口（含默认端口归一）全等。
/// 实现收敛到引擎的 [isSameHttpOrigin]（重定向剥凭据用的是同一个）。
bool isSameOpdsOrigin(Uri a, Uri b) => isSameHttpOrigin(a, b);

/// 目录地址返回的是网页而不是 OPDS feed（BUG-3519）。
///
/// 单独成型是为了让设置页的连接测试给出**本地化**的明确结论（「这是网页，
/// 不是 OPDS 目录地址」），而不是一句英文的「not a readable OPDS catalog」。
class OpdsWebPageFailure extends ExternalProviderFailure {
  const OpdsWebPageFailure({
    required super.providerId,
    required super.operation,
  }) : super(
         kind: ExternalProviderFailureKind.invalidResponse,
         message: 'address serves a web page, not an OPDS catalog',
       );
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
