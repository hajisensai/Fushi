import 'dart:convert';

import 'package:hibiki/src/sync/forwarded_mine_payload.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/tls/hibiki_pinning_http.dart';
import 'package:hibiki/src/sync/webdav_ops.dart';
import 'package:http/http.dart' as http;

/// 「制卡到服务端」发送器的窄接口（供 [RemoteMiningAnkiRepository] 依赖，便于单测注入假实现，
/// 不必拉起真实 HTTP + SyncRepository）。生产实现是 [HibikiRemoteMiningClient]。
abstract class RemoteMineSender {
  /// 转发一次制卡；返回服务端 `{result, message?, detail?}`，无可达候选/全失败返回 null，
  /// token 被拒抛 [SyncAuthError]。
  Future<Map<String, dynamic>?> mineForward(ForwardedMinePayload payload);

  /// 远端查重（fail-soft，异常/无候选回 false）。
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  });
}

/// 互联「制卡到服务端」的客户端发送器。传输契约与 [HibikiRemoteLookupClient] 完全同构
/// （enabled 候选按序 fallback / `Basic base64(hibiki:token)` / https 带指纹走钉扎 client /
/// 每候选独立回收），只是端点换成 `/api/mine/forward` 与 `/api/duplicate`，且默认超时更长
/// （制卡请求体带媒体字节，LAN 上可能几 MB）。
class HibikiRemoteMiningClient implements RemoteMineSender {
  HibikiRemoteMiningClient({
    required SyncRepository repo,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Duration mineTimeout = const Duration(seconds: 60),
    Duration duplicateTimeout = const Duration(seconds: 5),
  })  : _repo = repo,
        _httpClient = httpClient ?? http.Client(),
        _pinnedClientFactory = pinnedClientFactory ?? _defaultPinnedClient,
        _mineTimeout = mineTimeout,
        _duplicateTimeout = duplicateTimeout;

  final SyncRepository _repo;
  final http.Client _httpClient;
  final http.Client Function(String expectedFingerprint) _pinnedClientFactory;
  final Duration _mineTimeout;
  final Duration _duplicateTimeout;

  static http.Client _defaultPinnedClient(String expectedFingerprint) =>
      createPinnedHttpPackageClient(expectedFingerprint: expectedFingerprint);

  /// 是否已配置可达的已配对主机（enabled 候选 + token）。用于设置页/开关判断能否远端制卡。
  Future<bool> hasTarget() async {
    final List<HibikiClientUrl> candidates = (await _repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? token = await _repo.getHibikiClientToken();
    return candidates.isNotEmpty && token != null && token.isNotEmpty;
  }

  /// 转发一次制卡到已配对主机。返回服务端 `{result, message?, detail?}`；
  /// 无可达候选/全部失败返回 null；token 被拒抛 [SyncAuthError]。
  @override
  Future<Map<String, dynamic>?> mineForward(ForwardedMinePayload payload) {
    return _post(
      path: '/api/mine/forward',
      body: payload.toJson(),
      timeout: _mineTimeout,
    );
  }

  /// 查重（`+`→`✓`）：命中主机 Anki 后端。fail-soft，异常/无候选一律回 false。
  @override
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
  }) async {
    try {
      final Map<String, dynamic>? json = await _post(
        path: '/api/duplicate',
        body: <String, dynamic>{'expression': expression, 'reading': reading},
        timeout: _duplicateTimeout,
      );
      return json?['duplicate'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> _post({
    required String path,
    required Map<String, dynamic> body,
    required Duration timeout,
  }) async {
    final List<HibikiClientUrl> candidates = (await _repo.getHibikiClientUrls())
        .where((HibikiClientUrl u) => u.enabled)
        .toList(growable: false);
    final String? token = await _repo.getHibikiClientToken();
    if (candidates.isEmpty || token == null || token.isEmpty) return null;

    for (final HibikiClientUrl candidate in candidates) {
      final Uri? uri = _uri(candidate.url, path);
      if (uri == null) continue;
      final String? fp = candidate.fingerprintSha256;
      final bool usePinned =
          uri.isScheme('https') && fp != null && fp.isNotEmpty;
      final http.Client client =
          usePinned ? _pinnedClientFactory(fp) : _httpClient;
      try {
        final http.Response response = await client
            .post(
              uri,
              headers: <String, String>{
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(timeout);
        if (response.statusCode == 401) {
          throw SyncAuthError('Hibiki server rejected remote mining token');
        }
        // 404/405 = 该候选是旧版主机（无此端点）→ 换下一个候选。
        if (response.statusCode == 404 || response.statusCode == 405) {
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } on SyncAuthError {
        rethrow;
      } catch (_) {
        continue;
      } finally {
        if (usePinned) client.close();
      }
    }
    return null;
  }

  Uri? _uri(String baseUrl, String path) {
    try {
      final Uri base = Uri.parse(WebDavOps.normalizeUrl(baseUrl));
      return base
          .replace(path: path, queryParameters: const <String, String>{});
    } catch (_) {
      return null;
    }
  }
}
