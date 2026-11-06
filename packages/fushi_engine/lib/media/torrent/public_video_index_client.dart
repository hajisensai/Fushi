import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/torrent/anime_release_descriptor.dart';
import 'package:fushi_engine/media/torrent/download_timeouts.dart';
import 'package:fushi_engine/media/torrent/public_trackers.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

// 公共索引器（apibay / Knaben）磁链附带的 tracker 就是 [kPublicTrackers]：两家
// API 的返回形状不同——apibay 只给 `info_hash`（磁链要自己拼），Knaben 直接给
// `magnetUrl`——但落到下载引擎的必须是同一种东西。所以拼磁链的那一半在这里统
// 一，两家共用同一份 tracker，省得「同一个种子从 A 源加进来能连上、从 B 源加进
// 来连不上」。这两家没有站点专属 tracker，所以不另起名字，直接用共享常量。

/// 公共索引器返回的一条种子。
///
/// 两家 client 归一到同一个 DTO：provider 层因而只有一份 candidate 实现，
/// 「换一家源」不会连带长出第二套字段映射。
class PublicVideoIndexTorrent {
  const PublicVideoIndexTorrent({
    required this.title,
    required this.infoHash,
    required this.magnet,
    required this.seeders,
    required this.leechers,
    required this.sizeBytes,
    this.completed = 0,
    this.publishedAt,
    this.category,
    this.detailsUrl,
  });

  final String title;

  /// 小写十六进制 infoHash（v1 40 位 / v2 64 位）。
  final String infoHash;
  final String magnet;
  final int seeders;
  final int leechers;
  final int? sizeBytes;
  final int completed;
  final DateTime? publishedAt;
  final String? category;
  final String? detailsUrl;

  /// 标题里的分辨率 / 发布组：与 Nyaa 走同一个纯函数解析器，两家源的候选行
  /// 因而显示同一套规格标签（去重时也才比得起来）。
  AnimeReleaseDescriptor get releaseDescriptor =>
      parseAnimeReleaseDescriptor(title);

  String? get resolution => releaseDescriptor.resolution;

  String? get releaseGroup => releaseDescriptor.releaseGroup;
}

/// 由 infoHash + 展示名拼出磁链（apibay 只给 hash，不给磁链）。
String buildPublicVideoIndexMagnet({
  required String infoHash,
  required String displayName,
}) {
  final StringBuffer buffer = StringBuffer('magnet:?xt=urn:btih:$infoHash');
  final String name = displayName.trim();
  if (name.isNotEmpty) {
    buffer.write('&dn=${Uri.encodeQueryComponent(name)}');
  }
  for (final String tracker in kPublicTrackers) {
    buffer.write('&tr=${Uri.encodeQueryComponent(tracker)}');
  }
  return buffer.toString();
}

/// infoHash 规范化：非 40/64 位十六进制一律判无效（返回空串）。
///
/// 下游 `VideoResourceCandidate.identityKey` 正是按这两个长度做跨索引器去重的；
/// 放进一个歪的 hash 不会报错，只会让同一个种子在两家源里各算一条。
String normalizePublicVideoIndexInfoHash(String raw) {
  final String hash = raw.trim().toLowerCase();
  if (RegExp(r'^[0-9a-f]{40}$').hasMatch(hash) ||
      RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
    return hash;
  }
  return '';
}

/// apibay 式 JSON 搜索接口（`GET {base}/q.php?q=&cat=`，回 JSON 数组）客户端。
/// 无 API key；**不内置地址**，[baseUrl] 来自用户添加的 BT 站。
///
/// 分类由调用方给（`cat=201/207` 电影、`205/208` 剧集）：**分类是这条链路唯一的
/// 内容边界**——不传分类就是全站搜，成人分区（5xx）会直接混进电影结果里。
class ApibayClient {
  ApibayClient({
    required this.baseUrl,
    http.Client? client,
    this.requestTimeout = kDownloadDiscoveryTimeout,
  }) : _client = client ?? createAppHttpIoClient();

  final String baseUrl;
  final http.Client _client;

  /// 单次请求（建连 + 收完响应）的总时限，与 Nyaa 同一契约（BUG-2933）。
  ///
  /// `connectionTimeout` 只管建连：连上之后服务端不回包，`get` 永远不完成。
  /// 资源注册表把各家 provider `Future.wait` 在一起，一家挂住整轮搜索就跟着
  /// 挂住，「AI 下视频」停在「正在找资源」不动。调用链上没有外层超时，时限
  /// 只能落在 client 上。
  final Duration requestTimeout;

  /// 按关键词搜索。网络错误 / 非 200 / 响应不是 JSON 数组一律**抛出**，由
  /// provider 归入 `failures`——与 Nyaa 同款契约，绝不把故障伪装成「没搜到」。
  Future<List<PublicVideoIndexTorrent>> search(
    String query, {
    required List<int> categories,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(query, 'query');
    final List<PublicVideoIndexTorrent> results = <PublicVideoIndexTorrent>[];
    final Set<String> seen = <String>{};
    // apibay 的 `cat` 只接受单个分类，所以「电影 = 201 + 207」必须逐个打。
    for (final int category in categories) {
      final Uri uri = Uri.parse(baseUrl).replace(
        path: '/q.php',
        queryParameters: <String, String>{
          'q': trimmed,
          'cat': category.toString(),
        },
      );
      final http.Response res = await _client.get(uri).timeout(requestTimeout);
      if (res.statusCode != 200) {
        throw http.ClientException('apibay HTTP ${res.statusCode}', uri);
      }
      final dynamic decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) {
        throw const FormatException('apibay: expected a JSON array');
      }
      for (final dynamic entry in decoded) {
        if (entry is! Map) continue;
        final PublicVideoIndexTorrent? torrent = _parse(entry, category);
        if (torrent == null) continue;
        if (!seen.add(torrent.infoHash)) continue;
        results.add(torrent);
      }
    }
    return results;
  }

  /// 添加 BT 站时的格式探测（`bt_site_probe.dart`）：用 [query] 全站搜一次
  /// （`cat=0`），响应必须是 apibay 形状的 JSON 数组——非空、首项带 `info_hash`
  /// 与 `name`（无结果时 apibay 也回一条 `id=0` 的哨兵行，形状相同）。不符合
  /// 一律抛 [FormatException]；网络错误 / 非 200 原样抛。
  Future<void> verifyEndpoint(String query) async {
    final Uri uri = Uri.parse(baseUrl).replace(
      path: '/q.php',
      queryParameters: <String, String>{'q': query, 'cat': '0'},
    );
    final http.Response res = await _client.get(uri).timeout(requestTimeout);
    if (res.statusCode != 200) {
      throw http.ClientException('HTTP ${res.statusCode}', uri);
    }
    final dynamic decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! List ||
        decoded.isEmpty ||
        decoded.first is! Map ||
        !(decoded.first as Map).containsKey('info_hash') ||
        !(decoded.first as Map).containsKey('name')) {
      throw const FormatException('not an apibay-style search response');
    }
  }

  PublicVideoIndexTorrent? _parse(Map<dynamic, dynamic> entry, int category) {
    // 「没有结果」不是空数组：apibay 返回一条 id=0 / name="No results returned"
    // 的哨兵行。不认它就会把哨兵当成一个种子推给用户。
    final String id = '${entry['id'] ?? ''}'.trim();
    if (id.isEmpty || id == '0') return null;
    final String infoHash = normalizePublicVideoIndexInfoHash(
      '${entry['info_hash'] ?? ''}',
    );
    if (infoHash.isEmpty) return null;
    final String title = '${entry['name'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    final int added = int.tryParse('${entry['added'] ?? ''}') ?? 0;
    return PublicVideoIndexTorrent(
      title: title,
      infoHash: infoHash,
      magnet: buildPublicVideoIndexMagnet(
        infoHash: infoHash,
        displayName: title,
      ),
      seeders: int.tryParse('${entry['seeders'] ?? ''}') ?? 0,
      leechers: int.tryParse('${entry['leechers'] ?? ''}') ?? 0,
      sizeBytes: int.tryParse('${entry['size'] ?? ''}'),
      publishedAt: added > 0
          ? DateTime.fromMillisecondsSinceEpoch(added * 1000, isUtc: true)
          : null,
      category: '${entry['category'] ?? category}',
      detailsUrl: '$baseUrl/description.php?id=$id',
    );
  }

  void close() => _client.close();
}

/// Knaben 式聚合索引 API（`POST {base}` JSON 查询，回 `{hits: [...]}`）客户端。
/// 无 API key；**不内置地址**，[baseUrl] 来自用户添加的 BT 站。
///
/// 与 apibay 互补：它把 1337x / EZTV / TPB 等站的索引聚在一起，同一个片子换个发布
/// 组也能命中。分类走 Knaben 自己的层级 id（`3000000` 电影 / `2000000` 剧集）。
class KnabenClient {
  KnabenClient({
    required this.baseUrl,
    http.Client? client,
    this.requestTimeout = kDownloadDiscoveryTimeout,
  }) : _client = client ?? createAppHttpIoClient();

  final String baseUrl;
  final http.Client _client;

  /// 单次请求总时限，契约同 [ApibayClient.requestTimeout]。
  final Duration requestTimeout;

  Future<List<PublicVideoIndexTorrent>> search(
    String query, {
    required List<int> categories,
    int limit = 100,
  }) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(query, 'query');
    final Uri uri = Uri.parse(baseUrl);
    final http.Response res = await _client
        .post(
          uri,
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, Object?>{
            'query': trimmed,
            // `search_type: score` 会把 query 当权重提示而不是过滤条件——实测搜
            // "inception" 返回的全是当季无关热门。`100%` 才是「标题必须含关键词」。
            'search_type': '100%',
            'search_field': 'title',
            'categories': categories,
            'hide_xxx': true,
            'order_by': 'seeders',
            'order_direction': 'desc',
            'size': limit,
          }),
        )
        .timeout(requestTimeout);
    if (res.statusCode != 200) {
      throw http.ClientException('knaben HTTP ${res.statusCode}', uri);
    }
    final dynamic decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map) {
      throw const FormatException('knaben: expected a JSON object');
    }
    final dynamic hits = decoded['hits'];
    if (hits is! List) {
      throw const FormatException('knaben: expected a hits array');
    }
    final List<PublicVideoIndexTorrent> results = <PublicVideoIndexTorrent>[];
    final Set<String> seen = <String>{};
    for (final dynamic entry in hits) {
      if (entry is! Map) continue;
      final PublicVideoIndexTorrent? torrent = _parse(entry);
      if (torrent == null) continue;
      if (!seen.add(torrent.infoHash)) continue;
      results.add(torrent);
    }
    return results;
  }

  /// 添加 BT 站时的格式探测：POST 一条最小查询，响应必须是带 `hits` 数组的
  /// JSON 对象（空数组也算——接口形状对就行）。不符合抛 [FormatException]。
  Future<void> verifyEndpoint(String query) async {
    final Uri uri = Uri.parse(baseUrl);
    final http.Response res = await _client
        .post(
          uri,
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, Object?>{
            'query': query,
            'search_type': '100%',
            'search_field': 'title',
            'hide_xxx': true,
            'size': 1,
          }),
        )
        .timeout(requestTimeout);
    if (res.statusCode != 200) {
      throw http.ClientException('HTTP ${res.statusCode}', uri);
    }
    final dynamic decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map || decoded['hits'] is! List) {
      throw const FormatException('not a knaben-style search response');
    }
  }

  PublicVideoIndexTorrent? _parse(Map<dynamic, dynamic> entry) {
    final String infoHash = normalizePublicVideoIndexInfoHash(
      '${entry['hash'] ?? ''}',
    );
    if (infoHash.isEmpty) return null;
    final String title = '${entry['title'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    final Object? magnetRaw = entry['magnetUrl'];
    final String magnet = magnetRaw is String && magnetRaw.startsWith('magnet:')
        ? magnetRaw
        : buildPublicVideoIndexMagnet(infoHash: infoHash, displayName: title);
    final Object? detailsRaw = entry['details'];
    final Object? dateRaw = entry['date'];
    return PublicVideoIndexTorrent(
      title: title,
      infoHash: infoHash,
      magnet: magnet,
      seeders: int.tryParse('${entry['seeders'] ?? ''}') ?? 0,
      leechers: int.tryParse('${entry['peers'] ?? ''}') ?? 0,
      sizeBytes: int.tryParse('${entry['bytes'] ?? ''}'),
      completed: int.tryParse('${entry['grabs'] ?? ''}') ?? 0,
      publishedAt: dateRaw is String ? DateTime.tryParse(dateRaw) : null,
      category: entry['category'] is String
          ? entry['category'] as String
          : null,
      detailsUrl: detailsRaw is String && detailsRaw.isNotEmpty
          ? detailsRaw
          : null,
    );
  }

  void close() => _client.close();
}
