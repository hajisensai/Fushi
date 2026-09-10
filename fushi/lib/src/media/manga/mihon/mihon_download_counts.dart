import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:fushi_engine/utils/net/app_http.dart';

/// 扩展仓库索引本身**没有下载量字段**（keiyoushi 的 `index.pb` / `index.json`、
/// Aidoku 的 `index.min.json` 都没有）。唯一的公开热度真相源是 GitHub Release
/// 资产的 `download_count`。
///
/// **键为什么是 apkUrl 而不是 packageName**：索引里每条扩展的 `apkUrl` 就是那份
/// release 资产的真实地址（形如
/// `https://github.com/keiyoushi/extensions/releases/download/<tag>/tachiyomi-ja.rawxz-v1.4.5.apk`），
/// 与 API 返回的 `browser_download_url` 逐字相同——实测 keiyoushi 索引里 1402 条
/// 扩展 1402 条命中。反过来「从 packageName 剥掉 `eu.kanade.tachiyomi.extension.`
/// 前缀再拼文件名」要额外猜版本号，且对非 keiyoushi 仓库的命名约定完全不成立。
///
/// **口径必须说清**：上游只保留最近 10 个 release，旧版本的资产连同计数一起被删。
/// 所以这个数是「**当前这一版**的下载次数」，不是该扩展的历史累计——它衡量的是
/// 近期热度，跨扩展横向比较有意义，跨时间纵向比较没有。
@immutable
class MihonDownloadCounts {
  const MihonDownloadCounts(this.byApkUrl);

  /// apkUrl → 该资产的下载次数。
  final Map<String, int> byApkUrl;

  static const MihonDownloadCounts empty = MihonDownloadCounts(<String, int>{});

  bool get isEmpty => byApkUrl.isEmpty;

  int? lookup(String apkUrl) => byApkUrl[apkUrl];

  /// 合并两份计数，[other] 覆盖同键。用于「多仓库分别拉取」与「保留上一轮结果」。
  MihonDownloadCounts merge(MihonDownloadCounts other) {
    if (other.isEmpty) return this;
    if (isEmpty) return other;
    return MihonDownloadCounts(<String, int>{...byApkUrl, ...other.byApkUrl});
  }
}

/// 把下载量压成人眼一次扫得完的短形式：`999` / `1.2k` / `3.4M`。
///
/// 列表里每行都要显示这个数，精确到个位既没意义（它每小时都在变）又会让「哪个更
/// 热门」需要数位数。千以下保留原数——ja 这类小语种的源普遍只有两三位数，压成
/// `0.6k` 反而丢掉了唯一有效的区分度。
String formatMihonDownloadCount(int count) {
  if (count < 0) return '0';
  if (count < 1000) return '$count';
  if (count < 1000000) {
    final double thousands = count / 1000;
    return '${thousands.toStringAsFixed(thousands < 10 ? 1 : 0)}k';
  }
  final double millions = count / 1000000;
  return '${millions.toStringAsFixed(millions < 10 ? 1 : 0)}M';
}

/// 从一条 release 资产直链推出它所属仓库的 releases API 地址。
///
/// 只认 `github.com/<owner>/<repo>/releases/download/<tag>/<file>` 这一种形态：
/// 自建仓库（把 APK 挂在自己服务器上）没有等价 API，返回 null 表示「这条没有公开
/// 下载量」，而不是编一个地址去撞 404。
Uri? gitHubReleasesApiForApkUrl(String apkUrl) {
  final Uri? url = Uri.tryParse(apkUrl);
  if (url == null) return null;
  if (url.host.toLowerCase() != 'github.com') return null;
  final List<String> segments = url.pathSegments;
  if (segments.length < 5) return null;
  if (segments[2] != 'releases' || segments[3] != 'download') return null;
  final String owner = segments[0];
  final String repo = segments[1];
  if (owner.isEmpty || repo.isEmpty) return null;
  return Uri.https(
    'api.github.com',
    '/repos/$owner/$repo/releases',
    const <String, String>{'per_page': '100'},
  );
}

/// 解析 `GET /repos/<owner>/<repo>/releases` 的响应体，取出每条资产的下载量。
///
/// 顶层纯函数：响应体是 5 MB 量级（keiyoushi 10 个 release 共 1400+ 资产），在
/// UI isolate 上 `jsonDecode` 会掉帧，所以调用方用 [compute] 把它扔到别的 isolate。
///
/// 形状不对（非数组、缺字段、类型不符）一律跳过那一条而不是抛：这份数据只用来做
/// 展示与排序，一条坏记录不该让整份计数消失。
Map<String, int> parseGitHubReleaseAssetCounts(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! List) return const <String, int>{};
  final Map<String, int> counts = <String, int>{};
  for (final Object? release in decoded) {
    if (release is! Map<String, Object?>) continue;
    final Object? assets = release['assets'];
    if (assets is! List) continue;
    for (final Object? asset in assets) {
      if (asset is! Map<String, Object?>) continue;
      final Object? url = asset['browser_download_url'];
      final Object? count = asset['download_count'];
      if (url is! String || url.isEmpty) continue;
      if (count is num) {
        counts[url] = count.toInt();
      } else if (count is String) {
        final int? parsed = int.tryParse(count);
        if (parsed != null) counts[url] = parsed;
      }
    }
  }
  return counts;
}

/// 拉 GitHub Release 资产下载量。
///
/// **失败一律降级为「没有计数」，绝不往上抛**：下载量是锦上添花的展示字段，而调用
/// 它的是扩展目录刷新这条主链路。GFW 机器上 `api.github.com` 是必然超时的
/// （公共 gh 镜像只代理 raw / release 直链，对 API 一律 403 —— 见
/// `github_mirrors.dart` 的文件头），要是让它抛，等于「拿不到热度 = 整个扩展列表
/// 刷不出来」。
class MihonDownloadCountsClient {
  MihonDownloadCountsClient({
    http.Client? client,
    this.budget = const Duration(seconds: 45),
    this.maxBytes = 32 * 1024 * 1024,
    this.maxRepositories = 4,
  }) : _client = client ?? createAppHttpIoClient();

  final http.Client _client;

  /// 一次刷新里**所有**仓库合计的时间预算。
  final Duration budget;

  /// 响应体上限。keiyoushi 实测 5.6 MB；给到 32 MB 是留给「上游把 release 保留
  /// 数量调大」的余量，同时挡住把整个进程内存吃光的病态响应。
  final int maxBytes;

  /// 一次刷新最多查几个仓库。GitHub 未认证 API 是 60 次/小时/IP，用户加了十几个
  /// GitHub 仓库时挨个查会把配额烧光，之后连默认仓库的计数都拿不到。
  final int maxRepositories;

  /// 为 [apkUrls] 里能推出仓库的那些地址拉下载量。
  Future<MihonDownloadCounts> fetch(Iterable<String> apkUrls) async {
    final Set<Uri> endpoints = <Uri>{};
    for (final String apkUrl in apkUrls) {
      final Uri? endpoint = gitHubReleasesApiForApkUrl(apkUrl);
      if (endpoint != null) endpoints.add(endpoint);
      if (endpoints.length >= maxRepositories) break;
    }
    if (endpoints.isEmpty) return MihonDownloadCounts.empty;
    final Stopwatch elapsed = Stopwatch()..start();
    final Map<String, int> counts = <String, int>{};
    for (final Uri endpoint in endpoints) {
      final Duration left = budget - elapsed.elapsed;
      if (left <= Duration.zero) break;
      final Map<String, int>? page = await _fetchOne(endpoint, left);
      if (page != null) counts.addAll(page);
    }
    return counts.isEmpty
        ? MihonDownloadCounts.empty
        : MihonDownloadCounts(counts);
  }

  Future<Map<String, int>?> _fetchOne(Uri endpoint, Duration left) async {
    try {
      final http.Request request = http.Request('GET', endpoint);
      // GitHub API 要求带 UA，不带会 403；Accept 钉住 v3 免得将来默认版本换掉。
      request.headers[HttpHeaders.userAgentHeader] = 'Fushi';
      request.headers[HttpHeaders.acceptHeader] = 'application/vnd.github+json';
      final http.StreamedResponse response =
          await _client.send(request).timeout(left);
      if (response.statusCode != HttpStatus.ok) {
        await response.stream.drain<void>();
        return null;
      }
      final int? declared = response.contentLength;
      if (declared != null && declared > maxBytes) {
        await response.stream.drain<void>();
        return null;
      }
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) return null;
      }
      final String body = utf8.decode(bytes, allowMalformed: true);
      return await compute(parseGitHubReleaseAssetCounts, body);
    } on Object {
      // 超时 / DNS 失败 / TLS / 限流 / 坏 JSON —— 全都只是「这次没有热度数据」。
      return null;
    }
  }
}
