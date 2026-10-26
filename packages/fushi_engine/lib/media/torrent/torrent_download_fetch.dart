/// 索引器 `.torrent` 下载地址 → 校验过的 [TorrentAddPayload]（Torznab 与 RSS 搜索站
/// 共用的唯一一份实现）。
///
/// 规则（两边以前各自持有时就是这一套，抽出来只为不复制）：
/// - 地址与每一跳重定向都要过 [isSafeExternalProviderEndpoint]（HTTPS，或回环 /
///   用户显式放行的明文 HTTP），且不得携带 user info；至多 5 跳；
/// - 响应体上限 [kMaximumTorrentMetainfoBytes]，`Content-Length` 超限直接拒、流式
///   读取超限中断；
/// - 响应体其实是一条磁链（部分站点的「下载」会 302 到 / 直接回磁链文本）就按
///   磁链处理；否则按 metainfo 解析并与搜索结果的 info hash 复核；
/// - 所有失败映射成带 `providerId` 的 [ExternalProviderFailure]，临时 URL 与凭据
///   不会跟着异常出去。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/magnet_utils.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart'
    show isSafeExternalProviderEndpoint;

/// 非 2xx 的 HTTP 状态 → [ExternalProviderFailure]（401/403/404/429 分类，其余按
/// unavailable；429 与 5xx 可重试，带 `Retry-After` 秒数）。
ExternalProviderFailure providerHttpStatusFailure({
  required String providerId,
  required String operation,
  required int status,
  Map<String, String> headers = const <String, String>{},
}) => ExternalProviderFailure(
  providerId: providerId,
  operation: operation,
  kind: switch (status) {
    401 => ExternalProviderFailureKind.unauthorized,
    403 => ExternalProviderFailureKind.forbidden,
    404 => ExternalProviderFailureKind.notFound,
    429 => ExternalProviderFailureKind.rateLimited,
    _ => ExternalProviderFailureKind.unavailable,
  },
  message: 'provider returned HTTP $status',
  statusCode: status,
  retryAfter: _retryAfter(headers['retry-after']),
  retryable: status == 429 || status >= 500,
);

/// 磁链做 payload：两边都有 hash 时必须一致（不一致按 integrity 失败）。
TorrentMagnetPayload magnetPayloadForCandidate({
  required String providerId,
  required String magnetUri,
  required String? expectedInfoHash,
}) {
  final String? parsedHash = parseMagnetInfoHash(magnetUri);
  if (parsedHash != null &&
      expectedInfoHash != null &&
      parsedHash != expectedInfoHash) {
    throw ExternalProviderFailure(
      providerId: providerId,
      operation: 'resolve',
      kind: ExternalProviderFailureKind.integrity,
      message: 'magnet info hash does not match search result',
    );
  }
  return TorrentMagnetPayload(
    magnetUri: magnetUri,
    torrentId: parsedHash ?? torrentBackendIdForHash(expectedInfoHash),
  );
}

/// 搜索结果里的磁链能不能随任务落库：`magnet:` 前缀且（两边都有 hash 时）与
/// 结果 info hash 一致——与 [magnetPayloadForCandidate] 同判据，提前到候选构造期，
/// 持久化路径就不会绕过它。
String? persistableCandidateMagnet(String? magnetUri, String? infoHash) {
  if (magnetUri == null || !magnetUri.toLowerCase().startsWith('magnet:')) {
    return null;
  }
  final String? parsedHash = parseMagnetInfoHash(magnetUri);
  if (parsedHash != null && infoHash != null && parsedHash != infoHash) {
    return null;
  }
  return magnetUri;
}

/// 下载 [downloadUri] 指向的种子并解析成 payload（见文件头规则）。
Future<TorrentAddPayload> downloadTorrentPayload({
  required http.Client client,
  required Uri? downloadUri,
  required String providerId,
  required String? expectedInfoHash,
  required bool allowInsecureHttp,
  required Duration requestTimeout,
}) async {
  if (downloadUri == null ||
      downloadUri.userInfo.isNotEmpty ||
      !isSafeExternalProviderEndpoint(
        downloadUri,
        allowInsecureHttp: allowInsecureHttp,
      )) {
    throw ExternalProviderFailure(
      providerId: providerId,
      operation: 'resolve',
      kind: ExternalProviderFailureKind.invalidResponse,
      message: 'search result has no supported download locator',
    );
  }
  try {
    final Uint8List responseBytes = await _fetchTorrentBytes(
      client: client,
      initialUri: downloadUri,
      providerId: providerId,
      allowInsecureHttp: allowInsecureHttp,
      requestTimeout: requestTimeout,
    );
    final String body = utf8.decode(responseBytes, allowMalformed: true).trim();
    if (body.toLowerCase().startsWith('magnet:')) {
      final String? hash = parseMagnetInfoHash(body);
      if (hash != null &&
          expectedInfoHash != null &&
          hash != expectedInfoHash) {
        throw TorrentMetainfoException(
          TorrentMetainfoErrorCode.hashMismatch,
          'downloaded magnet hash mismatch',
        );
      }
      return TorrentMagnetPayload(
        magnetUri: body,
        torrentId: hash ?? torrentBackendIdForHash(expectedInfoHash),
      );
    }
    final InspectedTorrentMetainfo inspected = inspectTorrentMetainfo(
      responseBytes,
      expectedInfoHash: expectedInfoHash,
    );
    return inspected.toPayload(fileName: '${inspected.torrentId}.torrent');
  } on TorrentMetainfoException catch (error) {
    throw ExternalProviderFailure(
      providerId: providerId,
      operation: 'resolve',
      kind: error.code == TorrentMetainfoErrorCode.hashMismatch
          ? ExternalProviderFailureKind.integrity
          : ExternalProviderFailureKind.invalidResponse,
      message: error.code == TorrentMetainfoErrorCode.hashMismatch
          ? 'downloaded metainfo hash does not match search result'
          : 'downloaded file is not valid torrent metainfo',
    );
  } on Object catch (error) {
    throw ExternalProviderFailure.fromException(
      providerId: providerId,
      operation: 'resolve',
      error: error,
    );
  }
}

/// 详情页地址能否公开展示 / 落库：只收 http(s)，查询串里带凭据类参数（apikey、
/// passkey、token…，私有站 RSS 常见）的一律丢弃。
String? safePublicDetailsUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  const Set<String> secretKeys = <String>{
    'apikey',
    'api_key',
    'jackett_apikey',
    'token',
    'key',
    'passkey',
    'auth',
    'authkey',
    'rsskey',
    'signature',
    'sig',
  };
  if (uri.queryParameters.keys.any(
    (String key) => secretKeys.contains(key.toLowerCase()),
  )) {
    return null;
  }
  return uri.toString();
}

/// BT v2 的 64 位 hash 取前 40 位作后端 id（与 libtorrent / qB 的截断 id 一致）。
String? torrentBackendIdForHash(String? hash) {
  if (hash == null) return null;
  return hash.length == 64 ? hash.substring(0, 40) : hash;
}

Future<Uint8List> _fetchTorrentBytes({
  required http.Client client,
  required Uri initialUri,
  required String providerId,
  required bool allowInsecureHttp,
  required Duration requestTimeout,
}) async {
  Uri current = initialUri;
  for (int redirectCount = 0; redirectCount <= 5; redirectCount++) {
    final http.Request request = http.Request('GET', current)
      ..followRedirects = false
      ..maxRedirects = 0;
    final http.StreamedResponse response = await client
        .send(request)
        .timeout(requestTimeout);
    if (_isRedirectStatus(response.statusCode)) {
      final String? rawLocation = response.headers['location'];
      await _cancelStream(response.stream);
      if (redirectCount == 5 || rawLocation == null) {
        throw ExternalProviderFailure(
          providerId: providerId,
          operation: 'resolve',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'torrent download redirect was invalid',
        );
      }
      final Uri? location = Uri.tryParse(rawLocation);
      final Uri? next = location == null ? null : current.resolveUri(location);
      if (next != null && next.scheme == 'magnet') {
        // 「下载」302 到磁链：把磁链当响应体交回，由调用方按磁链处理。
        return Uint8List.fromList(utf8.encode(next.toString()));
      }
      if (next == null ||
          next.host.isEmpty ||
          next.userInfo.isNotEmpty ||
          !isSafeExternalProviderEndpoint(
            next,
            allowInsecureHttp: allowInsecureHttp,
          )) {
        throw ExternalProviderFailure(
          providerId: providerId,
          operation: 'resolve',
          kind: ExternalProviderFailureKind.invalidResponse,
          message: 'torrent download redirect was unsafe',
        );
      }
      current = next.replace(fragment: '');
      continue;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _cancelStream(response.stream);
      throw providerHttpStatusFailure(
        providerId: providerId,
        operation: 'resolve',
        status: response.statusCode,
        headers: response.headers,
      );
    }
    if ((response.contentLength ?? 0) > kMaximumTorrentMetainfoBytes) {
      await _cancelStream(response.stream);
      throw TorrentMetainfoException(
        TorrentMetainfoErrorCode.tooLarge,
        'download exceeded size limit',
      );
    }
    return _readLimitedTorrentBody(response.stream.timeout(requestTimeout));
  }
  throw StateError('unreachable torrent download redirect loop');
}

Future<Uint8List> _readLimitedTorrentBody(Stream<List<int>> stream) async {
  final BytesBuilder body = BytesBuilder(copy: false);
  int length = 0;
  await for (final List<int> chunk in stream) {
    length += chunk.length;
    if (length > kMaximumTorrentMetainfoBytes) {
      throw TorrentMetainfoException(
        TorrentMetainfoErrorCode.tooLarge,
        'download exceeded size limit',
      );
    }
    body.add(chunk);
  }
  return body.takeBytes();
}

Future<void> _cancelStream(Stream<List<int>> stream) async {
  final StreamSubscription<List<int>> subscription = stream.listen(
    (_) {},
    onError: (_) {},
  );
  await subscription.cancel();
}

bool _isRedirectStatus(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;

Duration? _retryAfter(String? raw) {
  final int? seconds = int.tryParse(raw?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}
