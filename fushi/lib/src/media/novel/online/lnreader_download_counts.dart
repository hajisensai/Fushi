import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

// LNReader 插件的公开下载量。
//
// **数据从哪来、为什么是它**：LNReader 插件仓库的索引（`plugins.min.json`）没有
// 下载量字段；插件本体是挂在 `raw.githubusercontent.com` 上的单个 `.js`，没有
// GitHub Release 资产，所以漫画 / 视频扩展那条「Release 资产 `download_count`」
// （`mihon_download_counts.dart`）走不通。GitHub 对 raw 文件不公开任何计数。
// 唯一公开、按文件计的数据是 jsDelivr 的 CDN 统计：jsDelivr 会镜像任意公开
// GitHub 仓库，`data.jsdelivr.com` 按文件公布经它下载的次数。
//
// **口径必须说清**：这是「经 jsDelivr 下载这份插件文件的次数」（近一个季度），
// 不是全部 LNReader 用户的安装量——上游 app 直接从 raw.githubusercontent 取文件，
// 那部分不经 jsDelivr、没有人公开计数。它衡量的是相对热度，同一仓库内横向比较
// 有意义；绝对值普遍偏小（2026-10 实测官方仓库季度内多数插件是两位数）。
//
// **统计里没出现的文件算 0，不算「没有数据」**：jsDelivr 只列出期间内有命中的
// 文件。只要某个仓库的统计**完整**拉到了（翻页到空页为止），缺席就是真实的
// 「这一季度没人经它下载」；拉不全（超时 / 限流 / 超预算）的仓库整组记 null，
// 不拿半份名单冒充 0。

/// 插件文件在 jsDelivr 上的身份：`gh/<owner>/<repo>@<ref>` + 仓库内路径。
@immutable
class LnReaderCdnFile {
  const LnReaderCdnFile({
    required this.owner,
    required this.repo,
    required this.ref,
    required this.path,
  });

  final String owner;
  final String repo;
  final String ref;

  /// 以 `/` 开头、已解码（`[madara]` 这类方括号是字面量）的仓库内路径——与
  /// jsDelivr 统计里的 `name` 同形。
  final String path;

  /// 同一个 jsDelivr 包（统计按包分页拉取）。GitHub 的 owner / repo 大小写不敏感
  /// （官方索引地址写 `LNReader`、插件地址写 `lnreader`），归一成小写。
  String get packageKey => '${owner.toLowerCase()}/${repo.toLowerCase()}@$ref';

  Uri statsUri({required int page}) => Uri.https(
    'data.jsdelivr.com',
    '/v1/stats/packages/gh/$owner/$repo@$ref/files',
    <String, String>{
      'period': 'quarter',
      'limit': '$kJsDelivrStatsPageSize',
      'page': '$page',
    },
  );
}

/// jsDelivr 统计接口单页上限。
const int kJsDelivrStatsPageSize = 100;

/// 从插件 JS 地址推出它在 jsDelivr 上的身份。认三种 GitHub 托管形态：
///
/// - `https://raw.githubusercontent.com/<o>/<r>/<ref>/<path>`（含
///   `refs/heads/<ref>` / `refs/tags/<ref>` 写法）——官方仓库就是这种；
/// - `https://github.com/<o>/<r>/raw/<ref>/<path>`；
/// - `https://cdn.jsdelivr.net/gh/<o>/<r>@<ref>/<path>`。
///
/// 其它托管（自建服务器）没有等价的公开计数，返回 null 表示「没有数据」，而不是
/// 编一个地址去撞 404。
LnReaderCdnFile? jsDelivrFileForPluginUrl(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  final List<String> segments = uri.pathSegments
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  LnReaderCdnFile? build(String owner, String repo, String ref, int from) {
    if (owner.isEmpty || repo.isEmpty || ref.isEmpty) return null;
    if (from >= segments.length) return null;
    return LnReaderCdnFile(
      owner: owner,
      repo: repo,
      ref: ref,
      path: '/${segments.sublist(from).join('/')}',
    );
  }

  switch (uri.host.toLowerCase()) {
    case 'raw.githubusercontent.com':
      if (segments.length < 4) return null;
      if (segments[2] == 'refs' &&
          segments.length >= 6 &&
          (segments[3] == 'heads' || segments[3] == 'tags')) {
        return build(segments[0], segments[1], segments[4], 5);
      }
      return build(segments[0], segments[1], segments[2], 3);
    case 'github.com':
      if (segments.length < 5 || segments[2] != 'raw') return null;
      return build(segments[0], segments[1], segments[3], 4);
    case 'cdn.jsdelivr.net':
      if (segments.length < 4 || segments[0] != 'gh') return null;
      final int at = segments[2].indexOf('@');
      if (at <= 0) return null;
      return build(
        segments[1],
        segments[2].substring(0, at),
        segments[2].substring(at + 1),
        3,
      );
  }
  return null;
}

/// 一页统计：解析出的 路径 → 次数，以及这页原始条目数（判断是否翻到底用原始
/// 条数，跳过的坏条目不能让「满页」看起来像「最后一页」）。
typedef JsDelivrStatsPage = ({Map<String, int> hits, int entries});

/// 解析一页 jsDelivr 文件统计：`[{name: "/path", hits: {total: n, …}}, …]` →
/// 路径 → 次数。形状不对的条目跳过；整页不是数组时抛 [FormatException]，让调用方
/// 把这个包记成「拉不全」。
///
/// 顶层纯函数：一页带着逐日明细有几百 KB，交给 [compute] 在别的 isolate 解。
JsDelivrStatsPage parseJsDelivrFileHits(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! List) {
    throw const FormatException('jsDelivr stats: not a list');
  }
  final Map<String, int> hits = <String, int>{};
  for (final Object? entry in decoded) {
    if (entry is! Map) continue;
    final Object? name = entry['name'];
    final Object? stats = entry['hits'];
    if (name is! String || name.isEmpty || stats is! Map) continue;
    final Object? total = stats['total'];
    if (total is num) hits[name] = total.toInt();
  }
  return (hits: hits, entries: decoded.length);
}

/// 拉 LNReader 插件的 jsDelivr 下载量。
///
/// **失败一律降级为「没有计数」，绝不往上抛**：下载量是锦上添花的展示字段，
/// 调用它的是目录刷新链路；`data.jsdelivr.com` 在部分网络下不可达，不能让它
/// 变成「扩展列表刷不出来」。
class LnReaderDownloadCountsClient {
  LnReaderDownloadCountsClient({
    required HttpClient Function() httpClientFactory,
    this.budget = const Duration(seconds: 30),
    this.maxBytesPerPage = 8 * 1024 * 1024,
    this.maxPackages = 4,
    this.maxPagesPerPackage = 10,
    @visibleForTesting
    Uri Function(LnReaderCdnFile package, int page)? statsUri,
  }) : _httpClientFactory = httpClientFactory,
       _statsUri =
           statsUri ??
           ((LnReaderCdnFile package, int page) =>
               package.statsUri(page: page));

  final HttpClient Function() _httpClientFactory;

  /// 统计页地址。生产恒为 [LnReaderCdnFile.statsUri]；单测指向本地服务器。
  final Uri Function(LnReaderCdnFile package, int page) _statsUri;

  /// 一次拉取里所有包合计的时间预算。
  final Duration budget;
  final int maxBytesPerPage;

  /// 一次最多查几个仓库（用户加了一堆第三方仓库时别把接口刷爆）。
  final int maxPackages;

  /// 每个包最多翻几页（官方仓库约 300 个插件 + 图标，实测 3–4 页）。
  final int maxPagesPerPackage;

  /// 为 [pluginUrls] 拉下载量，返回 插件地址 → 次数；拿不到数据的地址不在结果里。
  Future<Map<String, int>> fetch(Iterable<String> pluginUrls) async {
    final Map<String, LnReaderCdnFile> files = <String, LnReaderCdnFile>{};
    final Map<String, LnReaderCdnFile> packages = <String, LnReaderCdnFile>{};
    for (final String url in pluginUrls) {
      final LnReaderCdnFile? file = jsDelivrFileForPluginUrl(url);
      if (file == null) continue;
      if (!packages.containsKey(file.packageKey)) {
        if (packages.length >= maxPackages) continue;
        packages[file.packageKey] = file;
      }
      files[url] = file;
    }
    if (packages.isEmpty) return const <String, int>{};
    final Stopwatch elapsed = Stopwatch()..start();
    final Map<String, Map<String, int>> hitsByPackage =
        <String, Map<String, int>>{};
    for (final MapEntry<String, LnReaderCdnFile> package in packages.entries) {
      final Map<String, int>? hits = await _fetchPackage(
        package.value,
        elapsed,
      );
      if (hits != null) hitsByPackage[package.key] = hits;
    }
    return <String, int>{
      for (final MapEntry<String, LnReaderCdnFile> entry in files.entries)
        if (hitsByPackage[entry.value.packageKey]
            case final Map<String, int> hits)
          entry.key: hits[entry.value.path] ?? 0,
    };
  }

  /// 整包翻页拉完；任何一页失败或超预算返回 null（见文件头「缺席算 0」的前提）。
  Future<Map<String, int>?> _fetchPackage(
    LnReaderCdnFile package,
    Stopwatch elapsed,
  ) async {
    final Map<String, int> hits = <String, int>{};
    for (int page = 1; page <= maxPagesPerPackage; page++) {
      final Duration left = budget - elapsed.elapsed;
      if (left <= Duration.zero) return null;
      final JsDelivrStatsPage? chunk = await _fetchPage(
        _statsUri(package, page),
        left,
      );
      if (chunk == null) return null;
      hits.addAll(chunk.hits);
      if (chunk.entries < kJsDelivrStatsPageSize) return hits;
    }
    // 翻到上限还没见底：名单不完整，不能把缺席当 0。
    return null;
  }

  Future<JsDelivrStatsPage?> _fetchPage(Uri uri, Duration left) async {
    final HttpClient client = _httpClientFactory();
    try {
      final HttpClientRequest request = await client.getUrl(uri).timeout(left);
      request.headers.set(HttpHeaders.userAgentHeader, 'Fushi');
      final HttpClientResponse response = await request.close().timeout(left);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      if (response.contentLength > maxBytesPerPage) {
        await response.drain<void>();
        return null;
      }
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(left)) {
        bytes.add(chunk);
        if (bytes.length > maxBytesPerPage) return null;
      }
      final String body = utf8.decode(bytes.takeBytes(), allowMalformed: true);
      return await compute(parseJsDelivrFileHits, body);
    } on Object {
      // 超时 / DNS / TLS / 限流 / 坏 JSON —— 全都只是「这次没有热度数据」。
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
